/// Fork of std.Thread.Pool with a persisted state for each thread.
const std = @import("std");
const builtin = @import("builtin");

pub fn ThreadPool(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        run_queue: RunQueue = .{},
        is_running: bool = true,
        allocator: std.mem.Allocator,
        threads: []std.Thread,
        states: std.ArrayList(T),

        const RunQueue = std.SinglyLinkedList(Runnable);
        const Runnable = struct {
            runFn: RunProto,
        };

        const RunProto = *const fn (*Runnable, *T) void;

        pub const Options = struct {
            allocator: std.mem.Allocator,
            n_jobs: ?u32 = null,
        };

        pub fn init(pool: *Self, options: Options, comptime create_state: *const fn (std.mem.Allocator) std.mem.Allocator.Error!T) !void {
            const allocator = options.allocator;

            const thread_count = options.n_jobs orelse @max(1, std.Thread.getCpuCount() catch 1);

            pool.* = .{
                .allocator = allocator,
                .threads = &[_]std.Thread{},
                .states = try std.ArrayList(T).initCapacity(allocator, thread_count),
            };

            if (builtin.single_threaded) {
                return;
            }

            pool.threads = try allocator.alloc(std.Thread, thread_count);
            errdefer allocator.free(pool.threads);

            // kill and join any threads we spawned previously on error.
            var spawned: usize = 0;
            errdefer {
                pool.join(spawned);
                for (pool.states.items) |*e| e.deinit();
                pool.states.deinit();
            }

            for (pool.threads) |*thread| {
                try pool.states.append(try create_state(allocator));
                thread.* = try std.Thread.spawn(.{}, worker, .{
                    pool,
                    // pointer shall not move after `append` above; we allocated needed capacity at the start
                    &pool.states.items[pool.states.items.len - 1],
                });
                spawned += 1;
            }
        }

        pub fn deinit(pool: *Self) std.ArrayList(T) {
            pool.join(pool.threads.len); // kill and join all threads.
            const states = pool.states;
            pool.* = undefined;
            return states;
        }

        fn join(pool: *Self, spawned: usize) void {
            if (builtin.single_threaded) {
                return;
            }

            {
                pool.mutex.lock();
                defer pool.mutex.unlock();

                // ensure future worker threads exit the dequeue loop
                pool.is_running = false;
            }

            // wake up any sleeping threads (this can be done outside the mutex)
            // then wait for all the threads we know are spawned to complete.
            pool.cond.broadcast();
            for (pool.threads[0..spawned]) |*thread| {
                thread.join();
            }

            pool.allocator.free(pool.threads);
        }

        pub fn spawn(pool: *Self, comptime func: anytype, args: anytype) !void {
            if (builtin.single_threaded) {
                @call(.auto, func, args);
                return;
            }

            const Args = @TypeOf(args);
            const Closure = struct {
                arguments: Args,
                pool: *Self,
                run_node: RunQueue.Node = .{ .data = .{ .runFn = runFn } },

                fn runFn(runnable: *Runnable, state: *T) void {
                    const run_node = @fieldParentPtr(RunQueue.Node, "data", runnable);
                    const closure = @fieldParentPtr(@This(), "run_node", run_node);
                    @call(.auto, func, closure.arguments ++ .{state});

                    // The thread pool's allocator is protected by the mutex.
                    const mutex = &closure.pool.mutex;
                    mutex.lock();
                    defer mutex.unlock();

                    closure.pool.allocator.destroy(closure);
                }
            };

            {
                pool.mutex.lock();
                defer pool.mutex.unlock();

                const closure = try pool.allocator.create(Closure);
                closure.* = .{
                    .arguments = args,
                    .pool = pool,
                };

                pool.run_queue.prepend(&closure.run_node);
            }

            // Notify waiting threads outside the lock to try and keep the critical section small.
            pool.cond.signal();
        }

        fn worker(pool: *Self, state: *T) void {
            pool.mutex.lock();
            defer pool.mutex.unlock();

            while (true) {
                while (pool.run_queue.popFirst()) |run_node| {
                    // Temporarily unlock the mutex in order to execute the run_node
                    pool.mutex.unlock();
                    defer pool.mutex.lock();

                    const runFn = run_node.data.runFn;
                    runFn(&run_node.data, state);
                }

                // Stop executing instead of waiting if the thread pool is no longer running.
                if (pool.is_running) {
                    pool.cond.wait(&pool.mutex);
                } else {
                    break;
                }
            }
        }
    };
}

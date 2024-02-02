const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// A heap allocator optimized for each platform/compilation mode.
pub const HeapAllocator = struct {
    const is_windows = builtin.target.os.tag == .windows;

    backing_allocator: if (builtin.mode == .Debug)
        std.heap.GeneralPurposeAllocator(.{})
    else if (is_windows)
        std.heap.HeapAllocator
    else if (builtin.link_libc)
        void
    else
        @compileError("When not running in debug mode, you must use windows or link to libc as zig does not provide a fast, libc-less, general purpose allocator (yet)"),

    pub fn init() @This() {
        return .{ .backing_allocator = if (builtin.mode == .Debug)
            std.heap.GeneralPurposeAllocator(.{}){}
        else if (is_windows)
            std.heap.HeapAllocator.init()
        else if (builtin.link_libc) {} };
    }

    pub fn allocator(self: *@This()) std.mem.Allocator {
        if (builtin.mode == .Debug) {
            return self.backing_allocator.allocator();
        } else if (is_windows) {
            return self.backing_allocator.allocator();
        } else if (builtin.link_libc) {
            return std.heap.c_allocator;
        }
    }

    pub fn deinit(self: *@This()) void {
        if (builtin.mode == .Debug) {
            assert(self.backing_allocator.deinit() == .ok);
        } else if (is_windows) {
            self.backing_allocator.deinit();
        }
    }
};

/// Concatenates two slices into a newly allocated buffer. Returns an owned reference slice into the contents.
pub fn concatOwned(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, a.len + b.len);
    @memcpy(result[0..a.len], a);
    @memcpy(result[a.len..], b);
    return result;
}

/// Reads a file into a newly allocated buffer. Returns an owned reference slice into the contents.
pub fn readFileOwned(allocator: std.mem.Allocator, file: std.fs.File) ![]const u8 {
    const stat = try file.stat();
    const buffer = try allocator.alloc(u8, @as(usize, stat.size));

    assert(try file.readAll(buffer) == stat.size);

    return buffer;
}

/// Reads a file into a provided buffer. Returns a reference slice into the contents. Buffer will be reallocated if more space is needed.
pub fn readFileRealloc(allocator: std.mem.Allocator, file: std.fs.File, buffer: *[]u8) ![]const u8 {
    var index: usize = 0;
    assert(buffer.len > 0);

    while (true) {
        // we need more space for the buffer, double it
        if (index == buffer.len) {
            buffer.* = try allocator.realloc(buffer.*, buffer.len * 2);
        }
        const amt = try file.read(buffer.*[index..]);
        if (amt == 0) break;
        index += amt;
    }

    return buffer.*[0..index];
}

/// Returns the basename of a path with and without the extension.
pub fn basename(path: []const u8) struct { withExt: []const u8, withoutExt: []const u8 } {
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    return .{ .withExt = base, .withoutExt = base[0..(base.len - ext.len)] };
}

/// An owned pointer allocated using an allocator. ptr address will not move.
/// Similar to Rust's Box<T>.
pub fn Box(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: *T,
        allocator: std.mem.Allocator,

        /// Allocates a new Box<T> using the provided allocator.
        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            const ptr = try allocator.create(T);
            ptr.* = value;
            return .{ .ptr = ptr, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self.ptr);
        }
    };
}

pub const DebugLogger = struct {
    writer: ?std.fs.File.Writer,

    pub fn init(enabled: bool) @This() {
        return .{ .writer = if (enabled) std.io.getStdErr().writer() else null };
    }

    pub inline fn log(self: @This(), comptime format: []const u8, args: anytype) !void {
        if (self.writer) |out| try out.print(format, args);
    }
};

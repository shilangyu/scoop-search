const std = @import("std");
const poshHook = @import("args.zig").poshHook;
const ParsedArgs = @import("args.zig").ParsedArgs;
const env = @import("env.zig");
const utils = @import("utils.zig");
const search = @import("search.zig");
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const mvzr = @import("mvzr");

/// Stores results of a search in a single bucket.
const SearchResult = struct {
    bucketName: []const u8,
    result: search.SearchResult,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, bucketName: []const u8, result: search.SearchResult) !@This() {
        return .{
            .bucketName = try allocator.dupe(u8, bucketName),
            .result = result,
            .allocator = allocator,
        };
    }

    fn deinit(self: *@This()) void {
        self.allocator.free(self.bucketName);
        self.result.deinit();
    }
};

pub fn main() !void {
    var heap = utils.HeapAllocator.init();
    defer heap.deinit();
    const allocator = heap.allocator();

    var args = try ParsedArgs.parse(allocator);
    defer args.deinit();

    // print posh hook and exit if requested
    if (args.hook) {
        try std.io.getStdOut().writer().print("{s}\n", .{poshHook});
        std.process.exit(0);
    }

    const debug = utils.DebugLogger.init(env.isVerbose());
    try debug.log("Commandline arguments: {}\n", .{args});

    const query = try std.ascii.allocLowerString(allocator, args.query orelse "");
    defer allocator.free(query);

    const regexQuery = mvzr.compile(query) orelse
        return std.io.getStdErr().writer().print("Invalid regular expression: parsing \"{s}\".", .{query});

    const scoopHome = env.scoopHomeOwned(allocator, debug) catch |err| switch (err) {
        error.MissingHomeDir => {
            return std.io.getStdErr().writer().print("Could not establish scoop home directory. USERPROFILE environment variable is not defined.\n", .{});
        },
        else => |e| return e,
    };
    defer allocator.free(scoopHome);
    try debug.log("Scoop home: {s}\n", .{scoopHome});

    // get buckets path
    const bucketsPath = try utils.concatOwned(allocator, scoopHome, "/buckets");
    defer allocator.free(bucketsPath);

    var bucketsDir = std.fs.openDirAbsolute(bucketsPath, .{ .iterate = true }) catch
        return std.io.getStdErr().writer().print("Could not open the buckets directory: {s}.\n", .{bucketsPath});
    defer bucketsDir.close();

    // search each bucket one by one
    var results = std.ArrayList(SearchResult).init(allocator);
    defer {
        for (results.items) |*e| e.deinit();
        results.deinit();
    }
    var iter = bucketsDir.iterate();
    while (try iter.next()) |f| {
        if (f.kind != .directory) {
            continue;
        }

        const bucketBase = try std.mem.concat(allocator, u8, &[_][]const u8{ bucketsPath, "/", f.name });
        defer allocator.free(bucketBase);
        try debug.log("Found bucket: {s}\n", .{bucketBase});

        const result = search.searchBucket(allocator, regexQuery, bucketBase, debug) catch {
            try std.io.getStdErr().writer().print("Failed to search through the bucket: {s}.\n", .{f.name});
            continue;
        };
        try debug.log("Found {} matches\n", .{result.matches.items.len});

        try results.append(try SearchResult.init(
            allocator,
            f.name,
            result,
        ));
    }

    try debug.log("Done searching\n", .{});

    const hasMatches = try printResults(&results);
    if (!hasMatches)
        std.process.exit(1);
}

/// Returns whether there were any matches.
fn printResults(results: *std.ArrayList(SearchResult)) !bool {
    const SearchResultBucketSort = struct {
        fn lessThan(context: void, lhs: SearchResult, rhs: SearchResult) bool {
            _ = context;
            return std.mem.order(u8, lhs.bucketName, rhs.bucketName).compare(.lt);
        }
    };
    // sort results by bucket name
    std.mem.sort(SearchResult, results.items, {}, SearchResultBucketSort.lessThan);

    var hasMatches = false;

    // get a buffered writer for stdout
    const stdout = std.io.getStdOut();
    var bw = std.io.BufferedWriter(8 * 1024, std.fs.File.Writer){ .unbuffered_writer = stdout.writer() };
    defer stdout.close();

    for (results.items) |*result| {
        if (result.result.matches.items.len == 0) {
            continue;
        }
        hasMatches = true;

        _ = try bw.write("'");
        _ = try bw.write(result.bucketName);
        _ = try bw.write("' bucket:\n");

        for (result.result.matches.items) |match| {
            _ = try bw.write("    ");
            _ = try bw.write(match.name);
            _ = try bw.write(" (");
            _ = try bw.write(match.version);
            _ = try bw.write(")");
            if (match.bins.items.len != 0) {
                _ = try bw.write(" --> includes '");
                _ = try bw.write(match.bins.items[0]);
                _ = try bw.write("'");
            }
            _ = try bw.write("\n");
        }
        _ = try bw.write("\n");
    }

    if (!hasMatches) {
        const colorConfig = std.io.tty.detectConfig(stdout);

        try colorConfig.setColor(bw.writer(), std.io.tty.Color.yellow);
        _ = try bw.write("WARN  No matches found.\n");
        try colorConfig.setColor(bw.writer(), std.io.tty.Color.reset);
    }

    try bw.flush();
    return hasMatches;
}

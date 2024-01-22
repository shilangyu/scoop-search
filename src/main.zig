const std = @import("std");
const poshHook = @import("args.zig").poshHook;
const ParsedArgs = @import("args.zig").ParsedArgs;
const env = @import("env.zig");
const utils = @import("utils.zig");
const search = @import("search.zig");

pub fn main() !void {
    // TODO: error messages
    // TODO: replace allocator, maybe https://github.com/kprotty/zap/blob/54cd494257915e6c126a0b70f95789b669b49b96/benchmarks/zig/async.zig#L60
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var tp: std.Thread.Pool = undefined;
    try tp.init(.{ .allocator = allocator });

    var args = try ParsedArgs.parse(allocator);
    defer args.deinit();

    // print posh hook and exit if requested
    if (args.hook) {
        try std.io.getStdOut().writer().print("{s}\n", .{poshHook});
        std.process.exit(0);
    }

    const query = try std.ascii.allocLowerString(allocator, args.query orelse "");
    defer allocator.free(query);

    const scoopHome = env.scoopHomeOwned(allocator) catch |err| switch (err) {
        error.MissingHomeDir => {
            return std.io.getStdErr().writer().print("Could not establish scoop home directory. USERPROFILE environment variable is not defined.\n", .{});
        },
        else => |e| return e,
    };
    defer allocator.free(scoopHome);

    // get buckets path
    const bucketsPath = try utils.concatOwned(allocator, scoopHome, "/buckets");
    defer allocator.free(bucketsPath);

    var bucketPaths = try getBucketPaths(allocator, bucketsPath);
    defer {
        for (bucketPaths.items) |name| allocator.free(name);
        bucketPaths.deinit();
    }

    var results = std.ArrayList(search.SearchResult).init(allocator);
    defer results.deinit();
    var resultsMutex = std.Thread.Mutex{};

    for (bucketPaths.items) |path| {
        try tp.spawn(search.searchBucket, .{search.SearchState{
            .results = &results,
            .resultsMutex = &resultsMutex,
            .bucketBase = path,
            .query = query,
        }});
    }

    // wait for jobs to finish
    tp.deinit();

    if (!try printResults(allocator, results)) {
        std.os.exit(1);
    }
}

fn getBucketPaths(allocator: std.mem.Allocator, bucketsPath: []const u8) !std.ArrayList([]const u8) {
    var bucketsDir = try std.fs.openIterableDirAbsolute(bucketsPath, .{});
    defer bucketsDir.close();

    var bucketPaths = std.ArrayList([]const u8).init(allocator);

    var iter = bucketsDir.iterate();
    while (try iter.next()) |f| {
        if (f.kind != .directory) {
            continue;
        }

        try bucketPaths.append(try std.mem.concat(allocator, u8, &[_][]const u8{ bucketsPath, "/", f.name }));
    }

    return bucketPaths;
}

fn lessThanSearchResult(context: void, lhs: search.SearchResult, rhs: search.SearchResult) bool {
    _ = context;
    return std.mem.order(u8, lhs.bucketName, rhs.bucketName).compare(.lt);
}

/// Returns whether there were any matches.
fn printResults(allocator: std.mem.Allocator, results: std.ArrayList(search.SearchResult)) !bool {
    std.mem.sort(search.SearchResult, results.items, {}, lessThanSearchResult);

    var hasMatches = false;

    // reserve some conservative amount of memory to avoid initial allocs
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 8 * 1024);

    for (results.items) |*result| {
        defer result.deinit();
        if (result.matches.items.len == 0) {
            continue;
        }
        hasMatches = true;

        try buffer.append('\'');
        try buffer.appendSlice(result.bucketName);
        try buffer.appendSlice("' bucket:\n");

        for (result.matches.items) |match| {
            try buffer.appendSlice("    ");
            try buffer.appendSlice(match.name);
            try buffer.appendSlice(" (");
            try buffer.appendSlice(match.version);
            try buffer.append(')');
            if (match.bin) |bin| {
                try buffer.appendSlice(" --> includes '");
                try buffer.appendSlice(bin);
                try buffer.append('\'');
            }
            try buffer.append('\n');
        }
        try buffer.append('\n');
    }

    if (!hasMatches) {
        try buffer.appendSlice("No matches found.");
    }

    try std.io.getStdOut().writeAll(buffer.items);
    return hasMatches;
}

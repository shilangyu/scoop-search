const std = @import("std");
const utils = @import("utils.zig");
const Box = utils.Box;
const DebugLogger = utils.DebugLogger;
const mvzr = @import("mvzr");

/// State associated with a worker thread. Stores thread local cache and matches. Has its own allocator.
const ThreadPoolState = struct {
    matches: std.ArrayList(SearchMatch),
    read_buffer: []u8,
    allocator: Box(utils.HeapAllocator),

    fn create(allocator: std.mem.Allocator) !@This() {
        var allocat = try Box(utils.HeapAllocator).init(allocator, utils.HeapAllocator.init());

        return .{
            .matches = std.ArrayList(SearchMatch).init(allocat.ptr.allocator()),
            .read_buffer = try allocat.ptr.allocator().alloc(u8, 8 * 1024),
            .allocator = allocat,
        };
    }

    /// Merges many states into one. Takes ownership of states and frees appropriate resources.
    pub fn mergeStates(allocator: std.mem.Allocator, states: std.ArrayList(@This())) !SearchResult {
        var totalMatches: usize = 0;
        for (states.items) |*e| totalMatches += e.matches.items.len;

        var matches = try std.ArrayList(SearchMatch).initCapacity(allocator, totalMatches);
        var allocators = try std.ArrayList(Box(utils.HeapAllocator)).initCapacity(allocator, states.items.len);
        for (states.items) |*e| {
            e.allocator.ptr.allocator().free(e.read_buffer);

            try allocators.append(e.allocator);

            try matches.appendSlice(e.matches.items);
            e.matches.deinit();
        }

        states.deinit();

        return .{
            .matches = matches,
            .allocators = allocators,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.matches.items) |*e| e.deinit();
        self.matches.deinit();

        self.allocator.ptr.allocator().free(self.read_buffer);

        self.allocator.ptr.deinit();
        self.allocator.deinit();
    }
};

/// A merged result of a single bucket search.
pub const SearchResult = struct {
    matches: std.ArrayList(SearchMatch),
    allocators: std.ArrayList(Box(utils.HeapAllocator)),

    fn sortMatches(self: *@This()) void {
        const Sort = struct {
            fn lessThan(context: void, lhs: SearchMatch, rhs: SearchMatch) bool {
                _ = context;
                return std.mem.order(u8, lhs.name, rhs.name).compare(.lt);
            }
        };
        // sort results by package name
        std.mem.sort(SearchMatch, self.matches.items, {}, Sort.lessThan);
    }

    pub fn deinit(self: *@This()) void {
        for (self.matches.items) |*e| e.deinit();
        self.matches.deinit();

        for (self.allocators.items) |*e| {
            e.ptr.deinit();
            e.deinit();
        }
        self.allocators.deinit();
    }
};
const ThreadPool = @import("thread_pool.zig").ThreadPool(ThreadPoolState);

/// A single match of a package inside of the current bucket.
pub const SearchMatch = struct {
    name: []const u8,
    version: []const u8,
    bins: ?std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, name: []const u8, version: []const u8, bins: ?std.ArrayList([]const u8)) !@This() {
        return .{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
            .bins = blk: {
                if (bins) |b| {
                    var dupedBins = std.ArrayList([]const u8).init(allocator);
                    for (b.items) |bin| {
                        try dupedBins.append(try allocator.dupe(u8, bin));
                    }
                    break :blk dupedBins;
                }
                break :blk null;
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        if (self.bins) |bins| {
            for (bins.items) |bin| {
                self.allocator.free(bin);
            }
            bins.deinit();
        }
    }
};

/// Returns the directory where manifests are stored for the given bucket.
fn getPackagesDir(allocator: std.mem.Allocator, bucketBase: []const u8) !std.fs.Dir {
    // check if $bucketName/bucket exists, if not use $bucketName
    const packagesPath = try utils.concatOwned(allocator, bucketBase, "/bucket");
    defer allocator.free(packagesPath);

    const packages = std.fs.openDirAbsolute(packagesPath, .{ .iterate = true }) catch
    // fallback to $bucketName
        try std.fs.openDirAbsolute(bucketBase, .{ .iterate = true });

    return packages;
}

pub fn searchBucket(allocator: std.mem.Allocator, query: mvzr.Regex, bucketBase: []const u8, debug: DebugLogger) !SearchResult {
    var tp: ThreadPool = undefined;
    try tp.init(.{ .allocator = allocator }, ThreadPoolState.create);
    try debug.log("Worker count: {}\n", .{tp.threads.len});

    var packages = try getPackagesDir(allocator, bucketBase);
    defer packages.close();

    var names = std.ArrayList([]const u8).init(allocator);
    defer {
        for (names.items) |e| allocator.free(e);
        names.deinit();
    }

    var iter = packages.iterate();
    while (try iter.next()) |f| {
        if (f.kind != .file) {
            continue;
        }

        try names.append(try allocator.dupe(u8, f.name));

        try tp.spawn(matchPackage, .{ iter.dir, query, names.getLast() });
    }

    const states = tp.deinit();

    var result = try ThreadPoolState.mergeStates(allocator, states);
    result.sortMatches();

    return result;
}

/// If the given binary name matches the query, return it.
fn checkBin(allocator: std.mem.Allocator, bin: []const u8, query: mvzr.Regex) !?[]const u8 {
    const against = utils.basename(bin);
    const lowerBinStem = try std.ascii.allocLowerString(allocator, against.withoutExt);
    defer allocator.free(lowerBinStem);

    return if (query.isMatch(lowerBinStem)) against.withExt else null;
}

fn matchPackage(packagesDir: std.fs.Dir, query: mvzr.Regex, manifestName: []const u8, state: *ThreadPoolState) void {
    // ignore failed match
    matchPackageAux(packagesDir, query, manifestName, state) catch return;
}

/// A worker function for checking if a given manifest matches the query.
fn matchPackageAux(packagesDir: std.fs.Dir, query: mvzr.Regex, manifestName: []const u8, state: *ThreadPoolState) !void {
    const allocator = state.allocator.ptr.allocator();

    const extension = comptime ".json";
    if (!std.mem.endsWith(u8, manifestName, extension)) {
        return;
    }
    const stem = manifestName[0..(manifestName.len - extension.len)];

    const manifest = try packagesDir.openFile(manifestName, .{});
    defer manifest.close();
    const content = try utils.readFileRealloc(allocator, manifest, &state.read_buffer);

    const Manifest = struct {
        version: ?[]const u8 = null,
        bin: ?std.json.Value = null, // can be: null, string, [](string | []string)
    };

    // skip invalid manifests
    const parsed = std.json.parseFromSlice(Manifest, allocator, content, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const version = parsed.value.version orelse "";

    const lowerStem = try std.ascii.allocLowerString(allocator, stem);
    defer allocator.free(lowerStem);

    // does the package name match?
    if (query.isMatch(lowerStem)) {
        try state.matches.append(try SearchMatch.init(allocator, stem, version, null));
    } else {
        var matchedBins = std.ArrayList([]const u8).init(allocator);
        defer matchedBins.deinit();

        // the name did not match, lets see if any binary files do
        switch (parsed.value.bin orelse .null) {
            .string => |bin| {
                if (try checkBin(allocator, bin, query)) |matchedBin| {
                    try matchedBins.append(matchedBin);
                }
            },
            .array => |bins| for (bins.items) |e|
                switch (e) {
                    .string => |bin| if (try checkBin(allocator, bin, query)) |matchedBin| {
                        try matchedBins.append(matchedBin);
                    },
                    .array => |args| {
                        // check only first two (exe, alias), the rest are command flags
                        if (args.items.len > 0) {
                            switch (args.items[0]) {
                                .string => |bin| if (try checkBin(allocator, bin, query)) |matchedBin| {
                                    try matchedBins.append(matchedBin);
                                },
                                else => {},
                            }
                        }
                        if (args.items.len > 1) {
                            switch (args.items[1]) {
                                .string => |bin| if (try checkBin(allocator, bin, query)) |matchedBin| {
                                    try matchedBins.append(matchedBin);
                                },
                                else => {},
                            }
                        }
                    },
                    else => continue,
                },
            else => return,
        }

        if (matchedBins.items.len != 0) {
            try state.matches.append(try SearchMatch.init(allocator, stem, version, matchedBins));
        }
    }
}

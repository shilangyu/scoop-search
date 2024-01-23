const std = @import("std");
const utils = @import("utils.zig");
const Box = utils.Box;

/// State associated with a worker thread. Stores thread local cache and matches. Has its own allocator.
const ThreadPoolState = struct {
    matches: std.ArrayList(SearchMatch),
    read_buffer: []u8,
    allocator: Box(std.heap.GeneralPurposeAllocator(.{})),

    fn create(allocator: std.mem.Allocator) !@This() {
        var allocat = try Box(std.heap.GeneralPurposeAllocator(.{})).init(allocator, std.heap.GeneralPurposeAllocator(.{}){});

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
        var allocators = try std.ArrayList(Box(std.heap.GeneralPurposeAllocator(.{}))).initCapacity(allocator, states.items.len);
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

        std.debug.assert(self.allocator.ptr.deinit() == .ok);
        self.allocator.deinit();
    }
};

/// A merged result of a single bucket search.
pub const SearchResult = struct {
    matches: std.ArrayList(SearchMatch),
    allocators: std.ArrayList(Box(std.heap.GeneralPurposeAllocator(.{}))),

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
            std.debug.assert(e.ptr.deinit() == .ok);
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
    bin: ?[]const u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, name: []const u8, version: []const u8, bin: ?[]const u8) !@This() {
        return .{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
            .bin = if (bin) |b| try allocator.dupe(u8, b) else null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        if (self.bin) |bin| self.allocator.free(bin);
    }
};

/// Returns the directory where manifests are stored for the given bucket.
fn getPackagesDir(allocator: std.mem.Allocator, bucketBase: []const u8) !std.fs.IterableDir {
    // check if $bucketName/bucket exists, if not use $bucketName
    const packagesPath = try utils.concatOwned(allocator, bucketBase, "/bucket");
    defer allocator.free(packagesPath);

    var packages = std.fs.openIterableDirAbsolute(packagesPath, .{}) catch
    // fallback to $bucketName
        try std.fs.openIterableDirAbsolute(bucketBase, .{});

    return packages;
}

pub fn searchBucket(allocator: std.mem.Allocator, query: []const u8, bucketBase: []const u8) !SearchResult {
    var tp: ThreadPool = undefined;
    try tp.init(.{ .allocator = allocator }, ThreadPoolState.create);

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

/// If the given binary name matches the query, add it to the matches.
fn checkBin(allocator: std.mem.Allocator, bin: []const u8, query: []const u8, stem: []const u8, version: []const u8, matches: *std.ArrayList(SearchMatch)) !bool {
    const against = utils.basename(bin);
    const lowerBinStem = try std.ascii.allocLowerString(allocator, against.withoutExt);
    defer allocator.free(lowerBinStem);

    if (std.mem.containsAtLeast(u8, lowerBinStem, 1, query)) {
        try matches.append(try SearchMatch.init(allocator, stem, version, against.withExt));
        return true;
    }
    return false;
}

fn matchPackage(packagesDir: std.fs.Dir, query: []const u8, manifestName: []const u8, state: *ThreadPoolState) void {
    // ignore failed match
    matchPackageAux(packagesDir, query, manifestName, state) catch return;
}

/// A worker function for checking if a given manifest matches the query.
fn matchPackageAux(packagesDir: std.fs.Dir, query: []const u8, manifestName: []const u8, state: *ThreadPoolState) !void {
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
    if (std.mem.containsAtLeast(u8, lowerStem, 1, query)) {
        try state.matches.append(try SearchMatch.init(allocator, stem, version, null));
    } else {
        // the name did not match, lets see if any binary files do
        switch (parsed.value.bin orelse .null) {
            .string => |bin| {
                _ = try checkBin(allocator, bin, query, stem, version, &state.matches);
            },
            .array => |bins| for (bins.items) |e|
                switch (e) {
                    .string => |bin| if (try checkBin(allocator, bin, query, stem, version, &state.matches)) {
                        break;
                    },
                    .array => |args| {
                        // check only first two (exe, alias), the rest are command flags
                        if (args.items.len > 0) {
                            switch (args.items[0]) {
                                .string => |bin| if (try checkBin(allocator, bin, query, stem, version, &state.matches)) {
                                    break;
                                },
                                else => {},
                            }
                        }
                        if (args.items.len > 1) {
                            switch (args.items[1]) {
                                .string => |bin| if (try checkBin(allocator, bin, query, stem, version, &state.matches)) {
                                    break;
                                },
                                else => {},
                            }
                        }
                    },
                    else => continue,
                },
            else => return,
        }
    }
}

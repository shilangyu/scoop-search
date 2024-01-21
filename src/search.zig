const std = @import("std");
const utils = @import("utils.zig");

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

    fn deinit(self: *@This()) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        if (self.bin) |bin| self.allocator.free(bin);
    }
};

pub const SearchResult = struct {
    allocator: std.heap.GeneralPurposeAllocator(.{}),
    matches: std.ArrayList(SearchMatch),
    bucketName: []const u8,

    pub fn init(
        allocator: std.heap.GeneralPurposeAllocator(.{}),
        matches: std.ArrayList(SearchMatch),
        bucketBase: []const u8,
    ) !@This() {
        return .{
            .allocator = allocator,
            .matches = matches,
            .bucketName = try matches.allocator.dupe(u8, std.fs.path.basename(bucketBase)),
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.matches.items) |*value| value.deinit();

        self.matches.deinit();
        self.allocator.allocator().free(self.bucketName);
        _ = self.allocator.deinit();
    }
};

pub const SearchState = struct {
    results: *std.ArrayList(SearchResult),
    resultsMutex: *std.Thread.Mutex,

    bucketBase: []const u8,
    query: []const u8,

    fn addResult(self: *const @This(), result: SearchResult) !void {
        self.resultsMutex.lock();
        try self.results.append(result);
        self.resultsMutex.unlock();
    }
};

fn packagesDir(allocator: std.mem.Allocator, bucketBase: []const u8) !std.fs.IterableDir {
    // check if $bucketName/bucket exists, if not use $bucketName
    const packagesPath = try utils.concatOwned(allocator, bucketBase, "\\bucket");
    defer allocator.free(packagesPath);

    var packages = std.fs.openIterableDirAbsolute(packagesPath, .{}) catch
    // fallback to $bucketName
        try std.fs.openIterableDirAbsolute(bucketBase, .{});

    return packages;
}

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

// TODO: thread should not return errors
pub fn searchBucket(state: SearchState) !void {
    // TODO: replace allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var packages = try packagesDir(allocator, state.bucketBase);
    defer packages.close();

    var iter = packages.iterate();

    var matches = std.ArrayList(SearchMatch).init(allocator);

    var buffer = try allocator.alloc(u8, 8 * 1024);

    while (try iter.next()) |f| {
        const extension = comptime ".json";
        if (f.kind != .file or !std.mem.endsWith(u8, f.name, extension)) {
            continue;
        }
        const stem = f.name[0..(f.name.len - extension.len)];

        const manifest = try packages.dir.openFile(f.name, .{});
        defer manifest.close();
        const content = try utils.readFileRealloc(allocator, manifest, &buffer);

        const Manifest = struct {
            version: []const u8 = "",
            bin: std.json.Value, // can be: null, string, [](string | []string)
        };

        const parsed = try std.json.parseFromSlice(Manifest, allocator, content, .{});
        defer parsed.deinit();
        const version = parsed.value.version;

        const lowerStem = try std.ascii.allocLowerString(allocator, stem);
        defer allocator.free(lowerStem);

        if (std.mem.containsAtLeast(u8, lowerStem, 1, state.query)) {
            try matches.append(try SearchMatch.init(allocator, stem, version, null));
        } else {
            // the name did not match, lets see if any binary files do
            switch (parsed.value.bin) {
                .string => |bin| {
                    _ = try checkBin(allocator, bin, state.query, stem, version, &matches);
                },
                .array => |bins| for (bins.items) |e|
                    switch (e) {
                        .string => |bin| if (try checkBin(allocator, bin, state.query, stem, version, &matches)) {
                            break;
                        },
                        .array => |args| {
                            // check only first two (exe, alias), the rest are command flags
                            if (args.items.len > 0) {
                                switch (args.items[0]) {
                                    .string => |bin| if (try checkBin(allocator, bin, state.query, stem, version, &matches)) {
                                        break;
                                    },
                                    else => {},
                                }
                            }
                            if (args.items.len > 1) {
                                switch (args.items[1]) {
                                    .string => |bin| if (try checkBin(allocator, bin, state.query, stem, version, &matches)) {
                                        break;
                                    },
                                    else => {},
                                }
                            }
                        },
                        else => continue,
                    },
                else => continue,
            }
        }
    }

    // std.mem.sort(, items: []T, context: anytype, comptime lessThanFn: fn(@TypeOf(context), lhs:T, rhs:T)bool)

    // 		sort.SliceStable(res, func(i, j int) bool {
    // 	// case insensitive comparison where hyphens are ignored
    // 	return strings.ToLower(strings.ReplaceAll(res[i].name, "-", "")) <= strings.ToLower(strings.ReplaceAll(res[j].name, "-", ""))
    // })

    allocator.free(buffer);

    try state.addResult(try SearchResult.init(gpa, matches, state.bucketBase));
}

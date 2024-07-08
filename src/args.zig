const std = @import("std");

pub const poshHook =
    \\function scoop { if ($args[0] -eq "search") { scoop-search.exe @($args | Select-Object -Skip 1) } else { scoop.ps1 @args } }
;

pub const ParsedArgs = struct {
    query: ?[]const u8,
    hook: bool,
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator) !@This() {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        var hook = false;
        var query: ?[]const u8 = null;

        if (args.len == 1) {
            // pass
        } else if (std.mem.eql(u8, args[1], "--hook")) {
            hook = true;
        } else {
            query = try allocator.dupe(u8, args[1]);
        }

        return .{ .query = query, .hook = hook, .allocator = allocator };
    }

    pub fn deinit(self: *@This()) void {
        if (self.query) |q| self.allocator.free(q);
    }
};

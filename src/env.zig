const std = @import("std");
const utils = @import("utils.zig");
const testing = std.testing;
const DebugLogger = utils.DebugLogger;

/// Checks if scoop-search should run in verbose mode.
pub fn isVerbose() bool {
    return std.process.hasEnvVarConstant("SCOOP_SEARCH_VERBOSE");
}

/// Gets the home directory of the current user.
fn homeDirOwned(allocator: std.mem.Allocator, debug: DebugLogger) !?[]const u8 {
    const userProfile = std.process.getEnvVarOwned(allocator, "USERPROFILE");
    try debug.log("env:USERPROFILE={s}\n", .{userProfile catch ""});

    const dir = userProfile catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => |e| return e,
    };

    if (dir.len == 0) {
        allocator.free(dir);
        return null;
    } else {
        return dir;
    }
}

/// Path to the scoop config file.
fn scoopConfigFileOwned(allocator: std.mem.Allocator, homeDir: ?[]const u8, debug: DebugLogger) ![]const u8 {
    const xdgConfigHome = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME");
    try debug.log("env:XDG_CONFIG_HOME={s}\n", .{xdgConfigHome catch ""});

    const systemConfig = xdgConfigHome catch |err| switch (err) {
        error.EnvironmentVariableNotFound => if (homeDir) |dir|
            try utils.concatOwned(allocator, dir, "/.config")
        else
            return error.MissingHomeDir,
        else => |e| return e,
    };
    defer allocator.free(systemConfig);

    return try utils.concatOwned(allocator, systemConfig, "/scoop/config.json");
}

/// Returns the path to the root of scoop. Logic follows Scoop's logic for resolving the home directory.
pub fn scoopHomeOwned(allocator: std.mem.Allocator, debug: DebugLogger) ![]const u8 {
    const scoop = std.process.getEnvVarOwned(allocator, "SCOOP");
    try debug.log("env:SCOOP={s}\n", .{scoop catch ""});

    return scoop catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const homeDir = try homeDirOwned(allocator, debug);
            defer {
                if (homeDir) |d| allocator.free(d);
            }
            const scoopConfigPath = try scoopConfigFileOwned(allocator, homeDir, debug);
            defer allocator.free(scoopConfigPath);
            try debug.log("Scoop config file path: {s}\n", .{scoopConfigPath});

            if (std.fs.openFileAbsolute(scoopConfigPath, .{}) catch null) |configFile| {
                defer configFile.close();

                if (utils.readFileOwned(allocator, configFile) catch null) |config| {
                    defer allocator.free(config);
                    try debug.log("Scoop config file contents: {s}\n", .{config});

                    const parsed = try std.json.parseFromSlice(struct { root_path: ?[]const u8 = null }, allocator, config, .{ .ignore_unknown_fields = true });
                    defer parsed.deinit();
                    const rootPath = parsed.value.root_path orelse "";

                    if (rootPath.len != 0) {
                        return allocator.dupe(u8, rootPath);
                    }
                }
            } else {
                try debug.log("Scoop config file does not exist\n", .{});
            }

            // installing with default directory doesn't have `SCOOP`
            // and `root_path` either
            return if (homeDir) |dir|
                try utils.concatOwned(allocator, dir, "/scoop")
            else
                return error.MissingHomeDir;
        },
        else => |e| return e,
    };
}

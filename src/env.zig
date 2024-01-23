const std = @import("std");
const utils = @import("utils.zig");
const testing = std.testing;

/// Gets the home directory of the current user.
fn homeDirOwned(allocator: std.mem.Allocator) !?[]const u8 {
    const dir = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| switch (err) {
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
fn scoopConfigFileOwned(allocator: std.mem.Allocator, homeDir: ?[]const u8) ![]const u8 {
    const systemConfig = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
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
pub fn scoopHomeOwned(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "SCOOP") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const homeDir = try homeDirOwned(allocator);
            defer {
                if (homeDir) |d| allocator.free(d);
            }
            const scoopConfigPath = try scoopConfigFileOwned(allocator, homeDir);
            defer allocator.free(scoopConfigPath);

            if (std.fs.openFileAbsolute(scoopConfigPath, .{}) catch null) |configFile| {
                defer configFile.close();

                if (utils.readFileOwned(allocator, configFile) catch null) |config| {
                    defer allocator.free(config);

                    const parsed = try std.json.parseFromSlice(struct { root_path: ?[]const u8 = null }, allocator, config, .{ .ignore_unknown_fields = true });
                    defer parsed.deinit();
                    const rootPath = parsed.value.root_path orelse "";

                    if (rootPath.len != 0) {
                        return allocator.dupe(u8, rootPath);
                    }
                }
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

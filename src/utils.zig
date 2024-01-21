const std = @import("std");
const assert = std.debug.assert;

pub fn concatOwned(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, a.len + b.len);
    @memcpy(result[0..a.len], a);
    @memcpy(result[a.len..], b);
    return result;
}

pub fn readFileOwned(allocator: std.mem.Allocator, file: std.fs.File) ![]const u8 {
    const stat = try file.stat();
    var buffer = try allocator.alloc(u8, @as(usize, stat.size));

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

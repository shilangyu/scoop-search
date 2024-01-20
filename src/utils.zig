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

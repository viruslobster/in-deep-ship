const std = @import("std");

const Kind = enum(u32) {
    // Start at 1 b/c kitty image id=0 is invalid
    explosion = 1,
    ship,
};

const Frame = struct { x: u32, y: u32, w: u32, h: u32 };

const Self = @This();
kind: Kind,
path: []const u8,
frames: []const Frame,

pub fn id(self: *const Self) comptime_int {
    return @intFromEnum(self.kind);
}

pub fn load(self: *const Self, gpa: std.mem.Allocator) ![]u8 {
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.posix.getcwd(&dir_buffer);

    var full_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&full_path_buffer);
    const full_path = try std.fs.path.join(
        fixed.allocator(),
        &.{ dir, self.path },
    );
    const file = try std.fs.openFileAbsolute(full_path, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    return try file.readToEndAlloc(gpa, stat.size);
}

pub const explosion = Self{
    .kind = .explosion,
    .path = "assets/explosions.png",
    .frames = &[2]Frame{
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    },
};

pub const ship = Self{
    .kind = .ship,
    .path = "assets/ship.png",
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    },
};

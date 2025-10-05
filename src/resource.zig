const std = @import("std");

const Graphics = @import("graphics.zig");

const Frame = struct { x: u32, y: u32, w: u32, h: u32 };
const Self = @This();
image_file: ImageFile,
frames: []const Frame,
rows: u8,
cols: u8,

pub fn imageOptions(self: *const Self) Graphics.ImageOptions {
    return .{
        .action = .put,
        .image_id = self.image_file.id(),
        .rows = self.rows,
        .cols = self.cols,
        .source_rect = .{
            .x = self.frames[0].x,
            .y = self.frames[0].y,
            .w = self.frames[0].w,
            .h = self.frames[0].h,
        },
    };
}

pub const explosion = Self{
    .image_file = .explosion,
    .frames = &[2]Frame{
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    },
    .rows = 5,
    .cols = 5,
};

pub const carrier_vertical = Self{
    .image_file = .ship,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 600, .h = 543 },
    },
    .cols = 5,
    .rows = 17,
};

pub const carrier_horizontal = Self{
    .image_file = .ship,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 600, .h = 543 },
    },
    .cols = 29,
    .rows = 2,
};

pub const battleship_vertical = Self{
    .image_file = .ship,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 600, .h = 543 },
    },
    .cols = 5,
    .rows = 14,
};

pub const battleship_horizontal = Self{
    .image_file = .ship,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 600, .h = 543 },
    },
    .cols = 23,
    .rows = 2,
};

pub const cruiser_vertical = Self{
    .image_file = .ship,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 600, .h = 543 },
    },
    .cols = 5,
    .rows = 11,
};

pub const cruiser_horizontal = Self{
    .image_file = .ship,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 600, .h = 543 },
    },
    .cols = 17,
    .rows = 2,
};

pub const submarine_vertical = Self{
    .image_file = .ship,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 600, .h = 543 },
    },
    .cols = 5,
    .rows = 11,
};

pub const submarine_horizontal = Self{
    .image_file = .ship,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 600, .h = 543 },
    },
    .cols = 17,
    .rows = 2,
};

pub const destroyer_vertical = Self{
    .image_file = .ship,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 600, .h = 543 },
    },
    .cols = 5,
    .rows = 9,
};

pub const destroyer_horizontal = Self{
    .image_file = .ship,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 600, .h = 543 },
    },
    .cols = 11,
    .rows = 2,
};

pub const ralph = Self{
    .image_file = .ralf,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 300, .h = 300 },
    },
    .cols = 9 * 2,
    .rows = 9,
};

pub const ImageFile = enum(u32) {
    explosion = 1,
    ship,
    ralf,

    pub fn id(self: ImageFile) u32 {
        return @intFromEnum(self);
    }

    fn path(self: ImageFile) []const u8 {
        return switch (self) {
            .explosion => "assets/explosions.png",
            .ship => "assets/ship.png",
            .ralf => "assets/ralph.png",
        };
    }
};

pub fn load(gpa: std.mem.Allocator, image: ImageFile) ![]u8 {
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.posix.getcwd(&dir_buffer);

    var full_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&full_path_buffer);
    const full_path = try std.fs.path.join(
        fixed.allocator(),
        &.{ dir, image.path() },
    );
    const file = try std.fs.openFileAbsolute(full_path, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    return try file.readToEndAlloc(gpa, stat.size);
}

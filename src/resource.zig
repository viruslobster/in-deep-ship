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

pub fn imageOptions2(self: *const Self, frame_idx: usize) Graphics.ImageOptions {
    return .{
        .action = .put,
        .image_id = self.image_file.id(),
        .rows = self.rows,
        .cols = self.cols,
        .source_rect = .{
            .x = self.frames[frame_idx].x,
            .y = self.frames[frame_idx].y,
            .w = self.frames[frame_idx].w,
            .h = self.frames[frame_idx].h,
        },
    };
}

pub const carrier_vertical = shipSprite("carrier-vertical", .{ .cols = 5, .rows = 14 });
pub const carrier_horizontal = shipSprite("carrier-horizontal", .{ .cols = 29, .rows = 2 });
pub const battleship_vertical = shipSprite("battleship-vertical", .{ .cols = 5, .rows = 11 });
pub const battleship_horizontal = shipSprite("battleship-horizontal", .{ .cols = 23, .rows = 2 });
pub const cruiser_vertical = shipSprite("cruiser-vertical", .{ .cols = 5, .rows = 8 });
pub const cruiser_horizontal = shipSprite("cruiser-horizontal", .{ .cols = 17, .rows = 2 });
pub const submarine_vertical = shipSprite("submarine-vertical", .{ .cols = 5, .rows = 8 });
pub const submarine_horizontal = shipSprite("submarine-horizontal", .{ .cols = 17, .rows = 2 });
pub const destroyer_vertical = shipSprite("destroyer-vertical", .{ .cols = 5, .rows = 5 });
pub const destroyer_horizontal = shipSprite("destroyer-horizontal", .{ .cols = 11, .rows = 2 });

pub const ralph = Self{
    .image_file = .ralf,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 300, .h = 300 },
    },
    .cols = 9 * 2,
    .rows = 9,
};

pub const water = Self{
    .image_file = .water,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 959, .h = 879 },
    },
    .cols = 66,
    .rows = 27,
};

pub const hit = Self{
    .image_file = .hit,
    .frames = &gifFrames(55),
    .cols = 5,
    .rows = 2,
};

pub const miss = Self{
    .image_file = .miss,
    .frames = &gifFrames(51),
    .cols = 5,
    .rows = 2,
};

fn gifFrames(comptime n: usize) [n]Frame {
    var frames: [n]Frame = undefined;
    for (0..n) |i| frames[i] = .{ .x = 84 * i, .y = 0, .w = 84, .h = 84 };
    return frames;
}

pub const ImageFile = enum(u32) {
    spritesheet = 1,
    water,
    ralf,
    hit,
    miss,

    pub fn id(self: ImageFile) u32 {
        return @intFromEnum(self);
    }

    fn path(self: ImageFile) []const u8 {
        return switch (self) {
            .spritesheet => "assets/spritesheet.png",
            .water => "assets/water.png",
            .ralf => "assets/ralph.png",
            .hit => "assets/hit.png",
            .miss => "assets/miss.png",
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

pub const SpriteMeta = packed struct {
    const Rect = packed struct {
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    };

    frame: Rect,
    spriteSourceSize: Rect,
    sourceSize: packed struct { w: u32, h: u32 },
};

const SpriteEntry = struct {
    hash: u64,
    value: SpriteMeta,
};

const sprites_len = countSprites();
const sprites: [sprites_len]SpriteEntry = initSprites();

fn countSprites() usize {
    const sprite_bytes = @embedFile("assets/spritesheet.bin");
    var reader = std.Io.Reader.fixed(sprite_bytes);
    return reader.takeInt(u32, .big) catch
        @compileError("failed to read sprite count");
}

fn initSprites() [sprites_len]SpriteEntry {
    var result: [sprites_len]SpriteEntry = undefined;
    const sprite_bytes = @embedFile("assets/spritesheet.bin");
    var reader = std.Io.Reader.fixed(sprite_bytes);

    // toss the number of sprites, read this in countSprites()
    reader.toss(4);

    for (0..sprites_len) |i| {
        const hash = reader.takeInt(u32, .big) catch |err| switch (err) {
            error.EndOfStream => break,
            else => @compileError("failed to read hash"),
        };
        const meta = reader.takeStruct(SpriteMeta, .big) catch
            @compileError("failed to read sprite meta");

        result[i] = .{ .hash = hash, .value = meta };
    }
    return result;
}

/// Returns a `Resource` for a ship sprite with `name` in assets/spritesheet.json
/// The first frame is the regular ship, the second is the sunk ship.
fn shipSprite(name: []const u8, opts: struct { rows: u8, cols: u8 }) Self {
    const frame = shipSpriteFrame(name);
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{s}-sunk", .{name});
    const name_sunk = writer.buffered();
    const frame_sunk = shipSpriteFrame(name_sunk);

    return Self{
        .image_file = .spritesheet,
        .frames = &[2]Frame{
            .{ .x = frame.x, .y = frame.y, .w = frame.w, .h = frame.h },
            .{ .x = frame_sunk.x, .y = frame_sunk.y, .w = frame_sunk.w, .h = frame_sunk.h },
        },
        .cols = opts.cols,
        .rows = opts.rows,
    };
}

fn shipSpriteFrame(name: []const u8) SpriteMeta.Rect {
    const hash = std.hash.Crc32.hash(name);
    for (&sprites) |sprite| {
        if (sprite.hash != hash) continue;
        return sprite.value.frame;
    }
    @compileError("Failed to load sprite");
}

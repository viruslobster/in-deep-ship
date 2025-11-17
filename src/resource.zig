const std = @import("std");

const Graphics = @import("graphics.zig");

const Frame = struct { x: u32, y: u32, w: u32, h: u32 };
const Self = @This();
image: Image,
frames: []const Frame,
rows: u8,
cols: u8,

pub fn imageOptions(self: *const Self) Graphics.ImageOptions {
    return .{
        .action = .put,
        .image_id = self.image.id,
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
        .image_id = self.image.id,
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
pub const water = Self{
    .image = .water,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 959, .h = 879 },
    },
    .cols = 66,
    .rows = 27,
};
pub const hit = Self{
    .image = .hit,
    .frames = &gifFrames(55),
    .cols = 5,
    .rows = 2,
};
pub const miss = Self{
    .image = .miss,
    .frames = &gifFrames(51),
    .cols = 5,
    .rows = 2,
};
pub const winner = Self{
    .image = .winner,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 351, .h = 1024 },
    },
    .cols = 6,
    .rows = 9,
};
pub const loser = Self{
    .image = .loser,
    .frames = &[1]Frame{
        .{ .x = 0, .y = 0, .w = 351, .h = 1024 },
    },
    .cols = 6,
    .rows = 9,
};

fn gifFrames(comptime n: usize) [n]Frame {
    var frames: [n]Frame = undefined;
    for (0..n) |i| frames[i] = .{ .x = 84 * i, .y = 0, .w = 84, .h = 84 };
    return frames;
}

pub const Image = struct {
    var next_id: u32 = static.len + 1;
    id: u32,
    bytes: []const u8,

    pub fn init(bytes: []const u8) Image {
        const id: u32 = next_id;
        next_id += 1;
        return .{
            .id = id,
            .bytes = bytes,
        };
    }

    pub fn initId(id: u32, bytes: []const u8) Image {
        return .{
            .id = id,
            .bytes = bytes,
        };
    }

    // Dynamic images are loaded at runtime
    var dynamic_by_name: std.StringArrayHashMapUnmanaged(Image) = .empty;
    pub fn dynamic(gpa: std.mem.Allocator, path: []const u8) !Image {
        if (dynamic_by_name.get(path)) |image| return image;

        const bytes = try load(gpa, path);
        const image = init(bytes);
        try dynamic_by_name.put(gpa, path, image);
        return image;
    }

    pub fn dynamicNoAlloc(path: []const u8) !Image {
        if (dynamic_by_name.get(path)) |image| return image;
        return error.ImageNotLoaded;
    }

    pub fn markTransmitted(path: []const u8) void {
        _ = path;
        // TODO
    }

    fn load(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
            std.log.err("open: {s}", .{path});
            return err;
        };
        defer file.close();
        const stat = try file.stat();
        return try file.readToEndAlloc(gpa, stat.size);
    }

    // Static images are compiled in
    // Starting from 1 is important because these are used as Kitty image ids and 0 is invalid
    pub const spritesheet = initId(1, @embedFile("assets/spritesheet.png"));
    pub const water = initId(2, @embedFile("assets/water.png"));
    pub const hit = initId(3, @embedFile("assets/hit.png"));
    pub const miss = initId(4, @embedFile("assets/miss.png"));
    pub const winner = initId(5, @embedFile("assets/winner.png"));
    pub const loser = initId(6, @embedFile("assets/loser.png"));
    pub const static = [_]*const Image{
        &Image.spritesheet,
        &Image.water,
        &Image.hit,
        &Image.miss,
        &Image.winner,
        &Image.loser,
    };
};

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
        .image = .spritesheet,
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

pub fn portraitNoAlloc(path: []const u8) !Self {
    return .{
        .image = try Image.dynamicNoAlloc(path),
        .frames = &[1]Frame{
            .{ .x = 0, .y = 0, .w = 300, .h = 300 },
        },
        .cols = 19,
        .rows = 9,
    };
}

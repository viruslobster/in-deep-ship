const std = @import("std");
const R = @import("resource.zig");

pub const Spritesheet = struct {
    frames: std.json.ArrayHashMap(R.SpriteMeta),
};

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    // This is the path to the output file we will write
    const out_path = args.next() orelse return error.NoOutFilePassed;

    var buffer: [8192]u8 = undefined;
    var buffer_alloc = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = buffer_alloc.allocator();
    const json_bytes = @embedFile("assets/spritesheet.json");
    const parsed = try std.json.parseFromSlice(Spritesheet, alloc, json_bytes, .{ .ignore_unknown_fields = true });
    const sprite_count: u32 = @intCast(parsed.value.frames.map.count());

    var file = try std.fs.createFileAbsolute(out_path, .{});
    defer file.close();
    var file_buffer: [256]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const writer = &file_writer.interface;

    // Output file has this structure:
    // -- header --
    // First 32 bits: how many sprites are there
    // -- data --
    // First 32 bits: hash of the name of the sprite, e.g. carrier-vertical
    // Next @sizeOf(R.SpriteMeta) bits: sprite metadata
    // [repeat]
    try writer.writeInt(u32, sprite_count, .big);
    var iter = parsed.value.frames.map.iterator();
    while (iter.next()) |entry| {
        const hash = std.hash.Crc32.hash(entry.key_ptr.*);
        try writer.writeInt(u32, hash, .big);
        try writer.writeStruct(entry.value_ptr.*, .big);
    }
    try writer.flush();
}

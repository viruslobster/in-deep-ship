const std = @import("std");

/// This is parsed from "entry.zon"
const ParsedEntry = struct {
    name: []const u8,
    runnable: []const u8,
    img: []const u8,
    emote: []const u8,
};

pub const Entry = struct {
    // The display name for this contestant
    name: []const u8,

    // Just the name of the directory containing the entry
    dirname: []const u8,

    // These are all fully qualified paths to resources
    runnable: []const u8,
    img: []const u8,
    emote: []const u8,

    /// Copies all the memory passed in so its owned by gpa
    fn init(
        gpa: std.mem.Allocator,
        base_dir: []const u8,
        dirname: []const u8,
        parsed: ParsedEntry,
    ) !Entry {
        const owned_dirname = try gpa.alloc(u8, dirname.len);
        @memcpy(owned_dirname, dirname);

        const owned_name = try gpa.alloc(u8, parsed.name.len);
        @memcpy(owned_name, parsed.name);

        const full_runnable = try std.fs.path.join(gpa, &.{
            base_dir, dirname, parsed.runnable,
        });
        const full_img = try std.fs.path.join(gpa, &.{
            base_dir, dirname, parsed.img,
        });
        const full_emote = try std.fs.path.join(gpa, &.{
            base_dir, dirname, parsed.emote,
        });
        return .{
            .dirname = owned_dirname,
            .name = owned_name,
            .runnable = full_runnable,
            .img = full_img,
            .emote = full_emote,
        };
    }

    pub fn defaultForTest(name: []const u8) Entry {
        return .{
            .dirname = "/dir/name",
            .name = name,
            .runnable = "runnable",
            .img = "foo.png",
            .emote = "foo.mp3",
        };
    }

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(self.dirname);
        gpa.free(self.name);
        gpa.free(self.runnable);
        gpa.free(self.img);
        gpa.free(self.emote);
    }

    pub fn format(self: *const Entry, sink: *std.Io.Writer) !void {
        try sink.print(
            "['{s}', '{s}', '{s}', '{s}', '{s}']",
            .{ self.dirname, self.name, self.runnable, self.img, self.emote },
        );
    }
};

/// Parse all the entries in an absolute path. Invalid entries are ignored
pub fn parse(gpa: std.mem.Allocator, path: []u8) ![]Entry {
    var result = try std.ArrayList(Entry).initCapacity(gpa, 50);
    defer result.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("Entries not found at '{s}'. Make sure you're running in the right dir.", .{path});
            return &.{};
        },
        else => return err,
    };
    defer dir.close();
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        defer _ = arena.reset(.retain_capacity);

        if (entry.kind != .directory) continue;
        const path_parts = .{ path, entry.name, "entry.zon" };
        const meta_file_path = try std.fs.path.join(alloc, &path_parts);
        const meta_file = std.fs.openFileAbsolute(meta_file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("'{s}' contains no entry.zon, skipping", .{entry.name});
                continue;
            },
            else => return err,
        };
        const stat = try meta_file.stat();

        const bytes = try meta_file.readToEndAllocOptions(alloc, stat.size, null, .of(u8), 0);
        const parsed = std.zon.parse.fromSlice(ParsedEntry, alloc, bytes, null, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.ParseZon => {
                std.log.err("Failed to parse {s}", .{meta_file_path});
                continue;
            },
        };
        const meta = try Entry.init(gpa, path, entry.name, parsed);
        try result.append(gpa, meta);
    }
    return try result.toOwnedSlice(gpa);
}

pub fn join_path(base_dir: []const u8, path: []const u8, buffer: []u8) ![]u8 {
    var fixed = std.heap.FixedBufferAllocator.init(buffer);
    return try std.fs.path.join(fixed.allocator(), &.{ base_dir, path });
}

test {
    const gpa = std.testing.allocator;
    var base_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var entries_buf: [std.fs.max_path_bytes]u8 = undefined;

    const base_dir = try std.posix.getcwd(&base_dir_buf);
    const entries_path = try join_path(base_dir, "entries", &entries_buf);
    const entries = try parse(gpa, entries_path);
    defer gpa.free(entries);
    defer for (entries) |*e| e.deinit(gpa);
}

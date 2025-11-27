const std = @import("std");

const Meta = @import("meta.zig");
const View = @import("view.zig");
const Tournament = @import("tournament.zig");

fn help(stderr: *std.Io.Writer) !void {
    try stderr.print("Usage: in-deep-ship [play | debug]\n", .{});
}

fn helpDebug(stderr: *std.Io.Writer) !void {
    try stderr.print(
        \\Usage: in-deep-ship debug PLAYER0 PLAYER1
        \\
        \\  PLAYER0 and PLAYER1 are paths to executables
        \\
        \\  Hint: use in-deep-ship debug path0 path1 2>/tmp/stderr
        \\  and tail -f /tmp/stderr in another window
        \\
    , .{});
}

pub fn main() !void {
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const seed: u64 = @intCast(std.time.microTimestamp());
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    const gpa = std.heap.page_allocator;
    var base_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var entries_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir = try std.posix.getcwd(&base_dir_buf);
    const entries_path = try Meta.join_path(base_dir, "entries", &entries_buf);
    const entries = try Meta.parse(gpa, entries_path);

    var args = std.process.args();
    // Skip binary file path
    if (!args.skip()) {
        try help(stderr);
        return;
    }
    const command = args.next() orelse {
        try help(stderr);
        return;
    };
    const mode: View.Mode = if (std.mem.eql(u8, "play", command))
        .kitty
    else if (std.mem.eql(u8, "debug", command))
        .debug
    else {
        try help(stderr);
        std.process.exit(1);
    };
    var kitty_view: View.Kitty = undefined;
    var debug_view: View.Debug = undefined;
    const view: View.Interface = switch (mode) {
        .kitty => blk: {
            kitty_view = View.Kitty.init(gpa, stdout);
            break :blk .{ .kitty = &kitty_view };
        },
        .debug => blk: {
            debug_view = View.Debug.init(stdout);
            break :blk .{ .debug = &debug_view };
        },
    };
    var tournament = try Tournament.init(
        gpa,
        stdin,
        stdout,
        random,
        entries,
        base_dir,
    );
    // Leak tournament
    try tournament.play(view);
}

test {
    std.testing.refAllDeclsRecursive(Meta);
    const R = @import("resource.zig");
    std.testing.refAllDeclsRecursive(R);
    std.testing.refAllDeclsRecursive(Tournament);
}

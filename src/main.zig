const std = @import("std");

const Meta = @import("meta.zig");
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
    var tournament: Tournament = .{
        .gpa = gpa,
        .stdin = stdin,
        .stdout = stdout,
        .random = random,
        .entries = entries,
        .cwd = base_dir,
    };

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
    if (std.mem.eql(u8, "play", command)) {
        tournament.play() catch |err| switch (err) {
            error.WindowTooSmall => {
                std.log.err("Window is too small or font size is too big to render game", .{});
                std.process.exit(1);
            },
            else => return err,
        };
        //var kitty = View.Kitty.init(stdout);
        // try play(std.heap.page_allocator, stdin, stdout, random, entries, .{ .kitty = &kitty });
        return;
    }
    if (std.mem.eql(u8, "debug", command)) {
        const name0 = args.next();
        const name1 = args.next();
        if (name0 == null or name1 == null) {
            try helpDebug(stderr);
            return;
        }
        try tournament.debug(
            name0 orelse unreachable,
            name1 orelse unreachable,
        );
        return;
    }
    try help(stderr);
}

test {
    std.testing.refAllDeclsRecursive(Meta);
}

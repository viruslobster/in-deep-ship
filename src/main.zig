const std = @import("std");
const Game = @import("game.zig");
const Protocol = @import("protocol.zig");

const game_ships: [5]Game.Ship = .{
    .{ .size = 5 },
    .{ .size = 4 },
    .{ .size = 3 },
    .{ .size = 3 },
    .{ .size = 2 },
};

const game_width = 10;
const game_height = 10;
const GameBoard = Game.Board(game_width, game_height, &game_ships);

fn play(
    gpa: std.mem.Allocator,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    random: std.Random,
) !void {
    const player = GameBoard.init();
    _ = player;
    _ = gpa;
    _ = stdin;
    _ = stdout;
    _ = random;

    while (true) {
        std.log.info("looping", .{});
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

pub fn main() !void {
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const seed: u64 = @intCast(std.time.microTimestamp());
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    try play(std.heap.page_allocator, stdin, stdout, random);
    try stdout.flush();
}

test {
    std.testing.refAllDeclsRecursive(Protocol);
}

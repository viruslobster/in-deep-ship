const std = @import("std");

const Protocol = @import("protocol.zig");
const View = @import("view.zig");
const Meta = @import("meta.zig");
const Battleship = @import("battleship.zig");
const Tournament = @import("tournament.zig");
const Time = @import("time.zig");

pub const Fn = *const fn (*std.Io.Reader, *std.Io.Writer) std.Io.Writer.Error!void;

var placements = [_]Battleship.Placement{
    .{ .size = 2, .orientation = .Horizontal, .x = 1, .y = 1 },
    .{ .size = 3, .orientation = .Horizontal, .x = 1, .y = 2 },
    .{ .size = 3, .orientation = .Horizontal, .x = 1, .y = 3 },
    .{ .size = 4, .orientation = .Horizontal, .x = 1, .y = 4 },
    .{ .size = 5, .orientation = .Horizontal, .x = 1, .y = 5 },
};

pub fn behaved(stdin: *std.Io.Reader, stdout: *std.Io.Writer) !void {
    _ = stdin;
    const place_ships = Protocol.Message{ .place_ships_response = &placements };
    try stdout.print("{f}\n", .{place_ships});
    try stdout.flush();
    std.log.debug("placed ships", .{});

    for (0..Tournament.game_width) |x| {
        for (0..Tournament.game_height) |y| {
            const shot = Protocol.Message{ .turn_response = .{ .x = x, .y = y } };
            try stdout.print("{f}\n", .{shot});
            try stdout.flush();
        }
    }
}

pub fn completely_unresponsive(stdin: *std.Io.Reader, stdout: *std.Io.Writer) !void {
    _ = stdin;
    _ = stdout;
}

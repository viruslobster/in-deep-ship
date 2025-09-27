const std = @import("std");
const Battleship = @import("battleship.zig");

const Who = enum { you, enemy };

pub const Placement = struct {
    size: u8,
    orientation: Battleship.Orientation,
    x: usize,
    y: usize,
};

pub const Shot = union(enum) {
    miss: void,
    hit: void,
    sink: usize,
};

pub const Message = union(enum) {
    round_start: void,
    game_start: void,
    place_ships_request: void,
    place_ships_response: []const Placement,
    turn_request: void,
    turn_response: struct {
        x: usize,
        y: usize,
    },
    turn_result: struct {
        who: Who,
        x: usize,
        y: usize,
        shot: Shot,
    },

    pub fn parse(source: *std.Io.Reader, gpa: std.mem.Allocator) !Message {
        const buffer = try source.takeDelimiterExclusive('\n');
        errdefer std.log.err("failed to parse '{s}'", .{buffer});
        var parts = std.mem.splitScalar(u8, buffer, ';');
        const msg_type = parts.next() orelse return error.TooFewParts;

        if (std.mem.eql(u8, msg_type, "round-start")) {
            return .{ .round_start = {} };
        } else if (std.mem.eql(u8, msg_type, "game-start")) {
            return .{ .game_start = {} };
        } else if (std.mem.eql(u8, msg_type, "place-ships")) {
            if (parts.peek() == null) {
                return .{ .place_ships_request = {} };
            }
            // place-ships;3;horizontal;A0;4;vertical;J9\n
            var placements = try std.ArrayList(Placement).initCapacity(gpa, 5);
            while (true) {
                const size_bytes = parts.next() orelse return error.TooFewParts;
                const orientation_bytes = parts.next() orelse return error.TooFewParts;
                const cord_bytes = parts.next() orelse return error.TooFewParts;
                if (cord_bytes.len < 2) return error.Format;

                const orientation: Battleship.Orientation =
                    if (std.mem.eql(u8, "vertical", orientation_bytes))
                        .Vertical
                    else if (std.mem.eql(u8, "horizontal", orientation_bytes))
                        .Horizontal
                    else
                        return error.Format;

                const placement = Placement{
                    .size = try std.fmt.parseInt(u8, size_bytes, 10),
                    .orientation = orientation,
                    .x = try std.fmt.parseInt(usize, cord_bytes[1..], 10),
                    .y = std.mem.indexOf(u8, std.ascii.uppercase, cord_bytes[0..1]) orelse return error.Format,
                };
                try placements.append(gpa, placement);
                if (parts.peek() == null) break;
            }
            return .{ .place_ships_response = try placements.toOwnedSlice(gpa) };
        } else if (std.mem.eql(u8, msg_type, "turn")) {
            if (parts.peek() == null) {
                return .{ .turn_request = {} };
            }
            // turn;A0
            const cord_bytes = parts.next() orelse return error.TooFewParts;
            if (cord_bytes.len < 2) return error.Format;

            return .{
                .turn_response = .{
                    .x = try std.fmt.parseInt(usize, cord_bytes[1..], 10),
                    .y = std.mem.indexOf(u8, std.ascii.uppercase, cord_bytes[0..1]) orelse return error.Format,
                },
            };
        } else if (std.mem.eql(u8, msg_type, "turn-result")) {
            // turn-result;enemy;D2;sink;5\n
            const who_bytes = parts.next() orelse return error.TooFewParts;
            const cord_bytes = parts.next() orelse return error.TooFewParts;
            const shot_bytes = parts.next() orelse return error.TooFewParts;
            const shot: Shot = if (std.mem.eql(u8, "miss", shot_bytes))
                .{ .miss = {} }
            else if (std.mem.eql(u8, "hit", shot_bytes))
                .{ .hit = {} }
            else if (std.mem.eql(u8, "sink", shot_bytes)) blk: {
                const size_bytes = parts.next() orelse return error.TooFewParts;
                const size = try std.fmt.parseInt(usize, size_bytes, 10);
                break :blk .{ .sink = size };
            } else return error.Format;

            const who: Who = if (std.mem.eql(u8, "you", who_bytes))
                .you
            else if (std.mem.eql(u8, "enemy", who_bytes))
                .enemy
            else
                return error.Format;

            return .{
                .turn_result = .{
                    .who = who,
                    .shot = shot,
                    .x = try std.fmt.parseInt(usize, cord_bytes[1..], 10),
                    .y = std.mem.indexOf(u8, std.ascii.uppercase, cord_bytes[0..1]) orelse return error.Format,
                },
            };
        }
        return error.UnknownMessage;
    }

    pub fn format(self: *const Message, sink: *std.Io.Writer) !void {
        switch (self.*) {
            .round_start => try sink.print("round-start", .{}),
            .game_start => try sink.print("game-start", .{}),
            .place_ships_request => try sink.print("place-ships", .{}),
            .place_ships_response => |placements| {
                try sink.print("place-ships", .{});
                for (placements) |*placement| {
                    const letter = std.ascii.uppercase[placement.y];
                    try sink.print(
                        ";{d};{f};{c}{d}",
                        .{ placement.size, placement.orientation, letter, placement.x },
                    );
                }
                try sink.print("", .{});
            },
            .turn_request => try sink.print("turn", .{}),
            .turn_response => |turn| {
                const letter = std.ascii.uppercase[turn.y];
                try sink.print("turn;{c}{d}", .{ letter, turn.x });
            },
            .turn_result => |turn| {
                try sink.print("turn-result;", .{});
                try switch (turn.who) {
                    .you => sink.print("you;", .{}),
                    .enemy => sink.print("enemy;", .{}),
                };
                const letter = std.ascii.uppercase[turn.y];
                try sink.print("{c}{d};", .{ letter, turn.x });
                try switch (turn.shot) {
                    .miss => sink.print("miss", .{}),
                    .hit => sink.print("hit", .{}),
                    .sink => |size| sink.print("sink;{d}", .{size}),
                };
            },
        }
    }
};

test "message-format" {
    var buffer: [256]u8 = undefined;
    {
        var sink = std.Io.Writer.fixed(&buffer);
        const msg: Message = .{ .round_start = {} };
        try msg.format(&sink);
        try std.testing.expectEqualStrings("round-start", sink.buffered());
    }
    {
        var sink = std.Io.Writer.fixed(&buffer);
        const msg: Message = .{ .game_start = {} };
        try msg.format(&sink);
        try std.testing.expectEqualStrings("game-start", sink.buffered());
    }
    {
        var sink = std.Io.Writer.fixed(&buffer);
        const msg: Message = .{ .place_ships_request = {} };
        try msg.format(&sink);
        try std.testing.expectEqualStrings("place-ships", sink.buffered());
    }
    {
        var sink = std.Io.Writer.fixed(&buffer);
        const placements = [_]Placement{
            .{ .size = 3, .orientation = .Horizontal, .x = 0, .y = 0 },
            .{ .size = 4, .orientation = .Vertical, .x = 9, .y = 9 },
        };
        const msg: Message = .{ .place_ships_response = &placements };
        try msg.format(&sink);
        try std.testing.expectEqualStrings("place-ships;3;horizontal;A0;4;vertical;J9", sink.buffered());
    }
    {
        var sink = std.Io.Writer.fixed(&buffer);
        const msg: Message = .{ .turn_request = {} };
        try msg.format(&sink);
        try std.testing.expectEqualStrings("turn", sink.buffered());
    }
    {
        var sink = std.Io.Writer.fixed(&buffer);
        const msg: Message = .{ .turn_response = .{ .x = 1, .y = 1 } };
        try msg.format(&sink);
        try std.testing.expectEqualStrings("turn;B1", sink.buffered());
    }
    {
        var sink = std.Io.Writer.fixed(&buffer);
        const msg: Message = .{
            .turn_result = .{ .who = .you, .x = 2, .y = 3, .shot = .miss },
        };
        try msg.format(&sink);
        try std.testing.expectEqualStrings("turn-result;you;D2;miss", sink.buffered());
    }
    {
        var sink = std.Io.Writer.fixed(&buffer);
        const msg: Message = .{
            .turn_result = .{ .who = .enemy, .x = 2, .y = 3, .shot = .hit },
        };
        try msg.format(&sink);
        try std.testing.expectEqualStrings("turn-result;enemy;D2;hit", sink.buffered());
    }
    {
        var sink = std.Io.Writer.fixed(&buffer);
        const msg: Message = .{
            .turn_result = .{ .who = .enemy, .x = 2, .y = 3, .shot = .{ .sink = 5 } },
        };
        try msg.format(&sink);
        try std.testing.expectEqualStrings("turn-result;enemy;D2;sink;5", sink.buffered());
    }
}

test "message-parse" {
    const gpa = std.testing.allocator;
    {
        var source = std.Io.Reader.fixed("round-start\n");
        const actual = try Message.parse(&source, gpa);
        const expected: Message = .{ .round_start = {} };
        try std.testing.expectEqual(expected, actual);
    }
    {
        var source = std.Io.Reader.fixed("game-start\n");
        const actual = try Message.parse(&source, gpa);
        const expected: Message = .{ .game_start = {} };
        try std.testing.expectEqual(expected, actual);
    }
    {
        var source = std.Io.Reader.fixed("place-ships\n");
        const actual = try Message.parse(&source, gpa);
        const expected: Message = .{ .place_ships_request = {} };
        try std.testing.expectEqual(expected, actual);
    }
    {
        var source = std.Io.Reader.fixed("place-ships;3;horizontal;A0;4;vertical;J9\n");
        const result = try Message.parse(&source, gpa);
        defer gpa.free(result.place_ships_response);

        try std.testing.expect(result == .place_ships_response);
        try std.testing.expectEqual(result.place_ships_response.len, 2);
        try std.testing.expectEqual(
            result.place_ships_response[0],
            Placement{ .size = 3, .orientation = .Horizontal, .x = 0, .y = 0 },
        );
        try std.testing.expectEqual(
            result.place_ships_response[1],
            Placement{ .size = 4, .orientation = .Vertical, .x = 9, .y = 9 },
        );
    }
    {
        var source = std.Io.Reader.fixed("turn\n");
        const actual = try Message.parse(&source, gpa);
        const expected: Message = .{ .turn_request = {} };
        try std.testing.expectEqual(expected, actual);
    }
    {
        var source = std.Io.Reader.fixed("turn;A0\n");
        const actual = try Message.parse(&source, gpa);
        const expected: Message = .{ .turn_response = .{ .x = 0, .y = 0 } };
        try std.testing.expectEqual(expected, actual);
    }
    {
        var source = std.Io.Reader.fixed("turn-result;enemy;D2;sink;5\n");
        const actual = try Message.parse(&source, gpa);
        const expected: Message = .{
            .turn_result = .{ .who = .enemy, .x = 2, .y = 3, .shot = .{ .sink = 5 } },
        };
        try std.testing.expectEqual(expected, actual);
    }
}

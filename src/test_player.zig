const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const Protocol = @import("protocol.zig");
const View = @import("view.zig");
const Meta = @import("meta.zig");
const Battleship = @import("battleship.zig");
const Tournament = @import("tournament.zig");
const Time = @import("time.zig");
const Bridge = @import("bridge.zig");

pub const Fn = *const fn (*std.Io.Reader, *std.Io.Writer) std.Io.Writer.Error!void;

var placements = [_]Battleship.Placement{
    .{ .size = 2, .orientation = .Horizontal, .x = 1, .y = 1 },
    .{ .size = 3, .orientation = .Horizontal, .x = 1, .y = 2 },
    .{ .size = 3, .orientation = .Horizontal, .x = 1, .y = 3 },
    .{ .size = 4, .orientation = .Horizontal, .x = 1, .y = 4 },
    .{ .size = 5, .orientation = .Horizontal, .x = 1, .y = 5 },
};

pub const Event = union(enum) {
    message: Protocol.Message,
    sleep_ms: i64,
};

/// Turns a slice of messages into a stream bytes to parse. For use in tests.
pub const EventReader = struct {
    time: Time,
    sleep_until: i64 = -1,
    msg_idx: usize = 0,
    events: []const Event,
    interface: std.Io.Reader,

    pub fn init(time: Time, events: []const Event, buffer: []u8) EventReader {
        return .{
            .time = time,
            .events = events,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .seek = 0,
                .end = 0,
                .buffer = buffer,
            },
        };
    }

    fn stream(reader: *Reader, writer: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *EventReader = @alignCast(@fieldParentPtr("interface", reader));

        for (0..1e6) |_| {
            if (self.events.len == 0) return Reader.StreamError.EndOfStream;
            if (self.time.nowMs() < self.sleep_until) {
                // Simulate a WouldBlock err
                return Reader.StreamError.ReadFailed;
            }
            switch (self.events[0]) {
                .message => |msg| {
                    std.log.info("emit msg", .{});
                    return self.writeMessage(msg, writer, limit);
                },
                .sleep_ms => |ms| {
                    std.log.info("emit sleep", .{});
                    self.sleep_until = self.time.nowMs() + ms;
                    self.events = self.events[1..];
                },
            }
        } else return Reader.StreamError.ReadFailed;
    }

    fn writeMessage(
        self: *EventReader,
        msg: Protocol.Message,
        writer: *Writer,
        limit: std.Io.Limit,
    ) Reader.StreamError!usize {
        var buffer: [256]u8 = undefined;
        var subwriter = Writer.fixed(&buffer);
        try subwriter.print("{f}\n", .{msg});

        const remaining = subwriter.buffered()[self.msg_idx..];
        const bytes = limit.slice(remaining);
        const n = try writer.write(bytes);

        if (n == remaining.len) {
            // Wrote the entire message
            self.msg_idx = 0;
            self.events = self.events[1..];
        } else {
            // Partially wrote this message
            self.msg_idx += n;
        }
        return n;
    }
};

/// Simulates a player that immediatly responds to everything
pub fn behaved(gpa: std.mem.Allocator) !std.ArrayList(Event) {
    var result = try std.ArrayList(Event).initCapacity(gpa, 100);
    const place_ships = Protocol.Message{ .place_ships_response = &placements };
    try result.append(gpa, .{ .message = place_ships });

    for (0..Tournament.game_width) |x| {
        for (0..Tournament.game_height) |y| {
            const shot = Protocol.Message{ .turn_response = .{ .x = x, .y = y } };
            try result.append(gpa, .{ .message = shot });
        }
    }
    return result;
}

/// Simulates a player the same as `behaved` but with over a second of lag before every response.
pub fn laggy(gpa: std.mem.Allocator) !std.ArrayList(Event) {
    var behaved_events = try behaved(gpa);
    defer behaved_events.deinit(gpa);

    var result = try std.ArrayList(Event).initCapacity(gpa, behaved_events.items.len * 2);
    for (behaved_events.items) |event| {
        result.appendAssumeCapacity(.{ .sleep_ms = 1000 });
        result.appendAssumeCapacity(event);
    }
    return result;
}

test "EventReader with Bridge" {
    //std.testing.log_level = .debug;
    const events = [_]Event{
        .{ .sleep_ms = 900 },
        .{ .message = .{ .round_start = {} } },
        .{ .message = .{ .game_start = {} } },
        .{ .sleep_ms = 100 },
        .{ .message = .{ .place_ships_request = {} } },
    };

    var fake_time = Time.Fake{};
    const time = fake_time.interface();

    var reader_buffer: [256]u8 = undefined;
    var event_reader = EventReader.init(time, &events, &reader_buffer);
    const reader = &event_reader.interface;

    var discarding = std.Io.Writer.Discarding.init(&.{});
    var bridge = Bridge.InMemory.init(&discarding.writer, reader);
    const gpa = std.testing.allocator;

    // Polling without advancing time should always do nothing
    for (0..100) |_| {
        const actual = try bridge.pollMessage(gpa);
        try std.testing.expectEqual(null, actual);
    }

    {
        time.sleep(899 * std.time.ns_per_ms);
        const actual = try bridge.pollMessage(gpa);
        try std.testing.expectEqual(null, actual);
    }

    {
        time.sleep(1 * std.time.ns_per_ms);
        const expected = events[1].message;
        const actual = try bridge.pollMessage(gpa);
        try std.testing.expectEqual(expected, actual);
    }

    {
        const expected = events[2].message;
        const actual = try bridge.pollMessage(gpa);
        try std.testing.expectEqual(expected, actual);
    }

    {
        const actual = try bridge.pollMessage(gpa);
        try std.testing.expectEqual(null, actual);
    }

    {
        time.sleep(500 * std.time.ns_per_ms);
        const expected = events[4].message;
        const actual = try bridge.pollMessage(gpa);
        try std.testing.expectEqual(expected, actual);
    }
}

test "EventReader: behaved" {
    const gpa = std.testing.allocator;
    var events = try behaved(gpa);
    defer events.deinit(gpa);

    var fake_time = Time.Fake{};
    const time = fake_time.interface();

    var reader_buffer: [256]u8 = undefined;
    var event_reader = EventReader.init(time, events.items, &reader_buffer);
    const reader = &event_reader.interface;

    var writer_buffer: [256]u8 = undefined;
    for (events.items) |event| {
        switch (event) {
            .message => |msg| {
                var writer = std.Io.Writer.fixed(&writer_buffer);
                try writer.print("{f}", .{msg});
                const expected = writer.buffered();
                const actual = try reader.takeDelimiter('\n') orelse return error.Empty;
                try std.testing.expectEqualStrings(expected, actual);
            },
            .sleep_ms => |ms| {
                const actual = try reader.takeDelimiter('\n');
                try std.testing.expectEqual(null, actual);
                const ms_u64: u64 = @intCast(ms);
                time.sleep(ms_u64 * std.time.ns_per_ms);
            },
        }
    }
}

pub fn completely_unresponsive(stdin: *std.Io.Reader, stdout: *std.Io.Writer) !void {
    _ = stdin;
    _ = stdout;
}

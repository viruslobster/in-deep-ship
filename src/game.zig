const std = @import("std");

pub fn Board(width: usize, height: usize, ships: []const Ship) type {
    const board_len = width * height;
    const ship_len = ships.len;
    return struct {
        const Self = @This();

        ships: [ship_len]Ship,
        cells: [board_len]Cell,
        width: usize,
        height: usize,

        pub fn init() Self {
            var cells: [board_len]Cell = undefined;
            for (&cells) |*cell| {
                cell.* = .{};
            }
            return .{
                .ships = ships[0..ship_len].*,
                .cells = cells,
                .width = width,
                .height = height,
            };
        }

        pub inline fn index(x: usize, y: usize) usize {
            return y * width + x;
        }

        pub fn place(
            self: *Self,
            ship: *Ship,
            origin_x: usize,
            origin_y: usize,
            orientation: Orientation,
        ) !void {
            if (origin_x >= self.width or origin_y >= self.height) return error.OutOfBounds;

            for (0..ship.size) |i| {
                const cell = switch (orientation) {
                    .Horizontal => self.at(origin_x + i, origin_y),
                    .Vertical => self.at(origin_x, origin_y + i),
                } catch return error.ShipDoesNotFit;

                if (cell.ship != null) return error.ShipDoesNotFit;
            }

            // Only place ship if we know all cells are free
            for (0..ship.size) |i| {
                const cell = switch (orientation) {
                    .Horizontal => self.at_mut(origin_x + i, origin_y),
                    .Vertical => self.at_mut(origin_x, origin_y + i),
                } catch unreachable;

                cell.ship = ship;
            }
        }

        pub fn at_mut(self: *Self, x: usize, y: usize) !*Cell {
            if (x >= self.width or y >= self.height) return error.OutOfBounds;
            const i = Self.index(x, y);
            return &self.cells[i];
        }

        pub fn at(self: *const Self, x: usize, y: usize) !Cell {
            if (x >= self.width or y >= self.height) return error.OutOfBounds;
            const i = Self.index(x, y);
            return self.cells[i];
        }

        pub fn fire(self: *Self, x: usize, y: usize) Shot {
            if (x >= self.width or y >= self.height) return .{ .Miss = {} };
            const cell = self.at_mut(x, y) catch return .{ .Miss = {} };

            // Don't double count a result on an already explored cell
            if (cell.hit and cell.ship != null) return .{ .Hit = {} };
            if (cell.hit) return .{ .Miss = {} };

            cell.hit = true;
            var ship = cell.ship orelse return .{ .Miss = {} };
            ship.hits += 1;
            std.debug.assert(ship.hits <= ship.size);

            if (ship.hits < ship.size) return .{ .Hit = {} };
            return .{ .Sink = ship };
        }
    };
}

pub const Ship = struct {
    size: u8,
    hits: u8 = 0,
};

pub const Shot = union(enum) {
    Miss: void,
    Hit: void,
    Sink: *Ship,
};

pub const Orientation = enum {
    Horizontal,
    Vertical,

    pub fn format(self: *const Orientation, sink: *std.Io.Writer) !void {
        try switch (self.*) {
            .Horizontal => sink.print("horizontal", .{}),
            .Vertical => sink.print("vertical", .{}),
        };
    }
};

pub const Point = struct {
    x: usize,
    y: usize,
};

const Cell = struct {
    ship: ?*Ship = null,
    hit: bool = false,
};

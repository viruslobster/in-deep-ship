const std = @import("std");

pub fn Board(width: usize, height: usize, ships: []const Ship) type {
    const board_len = width * height;
    const ship_len = ships.len;
    return struct {
        const Self = @This();
        const Cell = struct {
            // index into `ships`
            ship_idx: ?usize = null,
            hit: bool = false,
        };

        ships: [ship_len]Ship,
        placed: [ship_len]bool,
        cells: [board_len]Cell,
        width: usize,
        height: usize,

        pub fn init() Self {
            var cells: [board_len]Cell = undefined;
            for (&cells) |*c| c.* = .{};
            return .{
                .ships = ships[0..ship_len].*,
                .cells = cells,
                .width = width,
                .height = height,
                .placed = [_]bool{false} ** ship_len,
            };
        }

        pub inline fn index(x: usize, y: usize) usize {
            return y * width + x;
        }

        pub fn allSunk(self: *Self) bool {
            for (&self.ships) |*s| if (s.hits < s.size) return false;
            return true;
        }

        pub fn allPlaced(self: *Self) bool {
            for (&self.placed) |placed| if (!placed) return false;
            return true;
        }

        /// If placement is invalid board state may be dirty
        pub fn place(
            self: *Self,
            size: u8,
            origin_x: usize,
            origin_y: usize,
            orientation: Orientation,
        ) !void {
            if (origin_x >= self.width or origin_y >= self.height) return error.OutOfBounds;

            const idx = for (0..self.ships.len) |i| {
                if (self.ships[i].size == size and !self.placed[i]) break i;
            } else {
                return error.NoUnplacedShip;
            };
            self.placed[idx] = true;

            for (0..size) |i| {
                const cell = switch (orientation) {
                    .Horizontal => self.at_ptr(origin_x + i, origin_y),
                    .Vertical => self.at_ptr(origin_x, origin_y + i),
                } catch {
                    std.log.err("{d}, {d}, {d}, {f}, {d}", .{ size, origin_x, origin_y, orientation, i });

                    return error.ShipDoesNotFit;
                };

                if (cell.ship_idx) |id| {
                    std.log.err("Overlap: {any}", .{self.ships[id]});
                    return error.ShipDoesNotFit;
                }
                cell.ship_idx = idx;
            }
        }

        pub fn at_ptr(self: *Self, x: usize, y: usize) !*Cell {
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
            const cell = self.at_ptr(x, y) catch return .{ .Miss = {} };

            // Don't double count a result on an already explored cell
            if (cell.hit and cell.ship_idx != null) return .{ .Hit = {} };
            if (cell.hit) return .{ .Miss = {} };

            cell.hit = true;
            const idx = cell.ship_idx orelse return .{ .Miss = {} };
            const ship = &self.ships[idx];
            ship.hits += 1;
            std.debug.assert(ship.hits <= ship.size);

            if (ship.hits < ship.size) return .{ .Hit = {} };
            return .{ .Sink = ship };
        }

        pub fn format(self: Self, sink: *std.Io.Writer) !void {
            // 0 1 2 3 4... header
            try sink.writeAll("   ");
            for (0..self.width) |i| {
                try sink.print("{d}  ", .{i});
            }
            try sink.writeByte('\n');

            for (0..self.height) |y| {
                try sink.print("{c} ", .{std.ascii.uppercase[y]});
                for (0..self.width) |x| {
                    const cell = self.at(x, y) catch unreachable;
                    const cell_ship = if (cell.ship_idx) |idx| &self.ships[idx] else null;
                    if (cell_ship) |ship| {
                        if (ship.hits >= ship.size) {
                            try csiColor(sink, 41);
                        } else if (cell.hit) {
                            try csiColor(sink, 43);
                        } else {
                            try csiColor(sink, null);
                        }
                        try sink.print("{}{}", .{ ship.size, ship.size });
                        try sink.print(" ", .{});
                        continue;
                    }
                    try csiColor(sink, null);
                    const char: u8 = if (cell.hit) 'X' else ' ';
                    try sink.print("{c}{c} ", .{ char, char });
                }
                try csiColor(sink, null);
                try sink.print("\n", .{});
            }
        }

        pub fn format_radar(self: Self, sink: *std.Io.Writer) !void {
            // 0 1 2 3 4... header
            try sink.writeAll("   ");
            for (0..self.width) |i| {
                try sink.print("{d}  ", .{i});
            }
            try sink.writeByte('\n');

            for (0..self.height) |y| {
                try sink.print("{c} ", .{std.ascii.uppercase[y]});
                for (0..self.width) |x| {
                    const cell = self.at(x, y) catch unreachable;
                    const cell_ship = if (cell.ship_idx) |idx| &self.ships[idx] else null;

                    if (cell.hit and cell_ship != null) {
                        const ship = cell_ship orelse unreachable;
                        if (ship.hits >= ship.size) {
                            try csiColor(sink, 41);
                            try sink.print("{}{}", .{ ship.size, ship.size });
                        } else {
                            try csiColor(sink, 43);
                            try sink.print("XX", .{});
                        }
                        try csiColor(sink, null);
                        try sink.print(" ", .{});
                        continue;
                    }
                    try csiColor(sink, null);
                    const char: u8 = if (cell.hit) 'X' else '?';
                    try sink.print("{c}{c} ", .{ char, char });
                }
                try sink.print("\n", .{});
            }
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

    pub fn format(self: Shot, sink: *std.Io.Writer) !void {
        try switch (self) {
            .Miss => sink.print("miss", .{}),
            .Hit => sink.print("hit", .{}),
            .Sink => |ship| sink.print("sink {d}", .{ship.size}),
        };
    }
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

fn csiColor(sink: *std.Io.Writer, value: ?u16) !void {
    if (value) |v| {
        try sink.print("\x1b[{d}m", .{v});
        return;
    }
    try sink.print("\x1b[m", .{});
}

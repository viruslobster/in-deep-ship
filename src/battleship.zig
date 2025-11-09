const std = @import("std");

pub fn Board(width: usize, height: usize, ships: []const Ship) type {
    const board_len = width * height;
    const ship_len = ships.len;
    return struct {
        const Self = @This();

        ships: [ship_len]Ship,
        placements: [ship_len]?Placement,
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
                .placements = .{null} ** ship_len,
            };
        }

        pub fn interface(self: *const Self) BoardInterface {
            return .{
                .ships = &self.ships,
                .placements = &self.placements,
                .cells = &self.cells,
                .width = self.width,
                .height = self.height,
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
            for (&self.placements) |p| if (p == null) return false;
            return true;
        }

        /// If placement is invalid board state may be dirty
        pub fn place(self: *Self, placement: Placement) !void {
            if (placement.x >= self.width or placement.y >= self.height)
                return error.OutOfBounds;

            const idx = for (0..self.ships.len) |i| {
                if (self.ships[i].size == placement.size and self.placements[i] == null)
                    break i;
            } else {
                return error.NoUnplacedShip;
            };
            self.placements[idx] = placement;

            for (0..placement.size) |i| {
                const cell = switch (placement.orientation) {
                    .Horizontal => self.at_ptr(placement.x + i, placement.y),
                    .Vertical => self.at_ptr(placement.x, placement.y + i),
                } catch {
                    std.log.err("ship does not fit: {any}", .{placement});
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
    };
}

pub const BoardInterface = struct {
    ships: []const Ship,
    placements: []const ?Placement,
    cells: []const Cell,
    width: usize,
    height: usize,
};

const Cell = struct {
    // index into `ships`
    ship_idx: ?usize = null,
    hit: bool = false,
};

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

fn csiColor(sink: *std.Io.Writer, value: ?u16) !void {
    if (value) |v| {
        try sink.print("\x1b[{d}m", .{v});
        return;
    }
    try sink.print("\x1b[m", .{});
}

pub const Placement = struct {
    size: u8,
    orientation: Orientation,
    x: u16,
    y: u16,
};

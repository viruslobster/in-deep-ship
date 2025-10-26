const std = @import("std");

const Battleship = @import("battleship.zig");
const Layout = @import("layout.zig");
const Graphics = @import("graphics.zig");
const R = @import("resource.zig");

// TODO: Interface is a better name?
pub const View = union(enum) {
    debug: *Debug,
    kitty: *Kitty,

    pub fn alloc(self: View, gpa: std.mem.Allocator) !void {
        switch (self) {
            inline else => |variant| try variant.alloc(gpa),
        }
    }

    pub fn draw(
        self: View,
        gpa: std.mem.Allocator,
        player0: Battleship.BoardInterface,
        player1: Battleship.BoardInterface,
    ) !void {
        switch (self) {
            inline else => |variant| try variant.draw(gpa, player0, player1),
        }
    }
};

const Debug = struct {
    fn alloc(self: *Debug, gpa: std.mem.Allocator) !void {
        _ = gpa;
        _ = self;
    }

    fn draw(
        self: *Debug,
        gpa: std.mem.Allocator,
        player0: Battleship.BoardInterface,
        player1: Battleship.BoardInterface,
    ) !void {
        _ = self;
        _ = gpa;
        _ = player0;
        _ = player1;
    }
};

pub const Kitty = struct {
    stdout: *std.Io.Writer,
    spacer0_col: Layout.Column,
    spacer1_col: Layout.Column,
    player0_col: Layout.Column,
    player1_col: Layout.Column,

    pub fn init(stdout: *std.Io.Writer) Kitty {
        return .{
            .stdout = stdout,
            .player0_col = undefined,
            .player1_col = undefined,
            .spacer0_col = undefined,
            .spacer1_col = undefined,
        };
    }

    fn alloc(self: *Kitty, gpa: std.mem.Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var g = try Graphics.init(self.stdout);
        const images: []const R.ImageFile = &.{ R.ImageFile.ship, R.ImageFile.explosion, R.ImageFile.ralf };
        for (images) |img_file| {
            const bytes = R.load(arena_alloc, img_file) catch |err| {
                std.log.err("load file: {any}", .{img_file});
                return err;
            };
            try g.imageBytes(
                bytes,
                .{ .image_id = img_file.id(), .action = .transmit },
            );
            _ = arena.reset(.retain_capacity);
        }
        self.player0_col = try Layout.Column.init(gpa, 100, 100);
        self.player1_col = try Layout.Column.init(gpa, 100, 100);
        self.spacer0_col = try Layout.Column.init(gpa, 1, 100);
        self.spacer1_col = try Layout.Column.init(gpa, 1, 100);
    }

    fn draw(
        self: *Kitty,
        gpa: std.mem.Allocator,
        player0: Battleship.BoardInterface,
        player1: Battleship.BoardInterface,
    ) !void {
        _ = gpa;
        var g = try Graphics.init(self.stdout);
        try g.hideCursor();
        try g.setCursor(.{ .row = 0, .col = 0 });
        try g.eraseBelowCursor();

        const winsize = try Graphics.measureScreen();
        std.log.info("winsize: {any}", .{winsize});

        var col_buffer: [256]u8 = undefined;
        var col_writer = self.player0_col.writer(&col_buffer);
        var col = &col_writer.interface;
        try col.print("Player: foo", .{});
        const grid_start: u16 = 11;
        try col.splatByteAll('\n', grid_start);

        try col.print("{s}\n", .{grid_template});
        try col.flush();

        self.spacer0_col.reset();

        self.spacer1_col.reset();
        var spacer1_writer = self.spacer1_col.writer(&.{});
        const spacer1 = &spacer1_writer.interface;
        try spacer1.splatByteAll(' ', 5);

        const layout = Layout.init(
            &.{ &self.spacer0_col, &self.player0_col, &self.spacer1_col, &self.player0_col },
        );
        var spacer0_writer = self.spacer0_col.writer(&.{});
        const spacer0 = &spacer0_writer.interface;
        if (winsize.col < layout.width()) return error.WindowTooSmall;

        const left_margin = (winsize.col - layout.width()) / 2;
        try spacer0.splatByteAll(' ', left_margin);

        try self.stdout.print("{f}", .{layout});

        // Draw contestant pics
        {
            const offset_x: u16 = @intCast(layout.offset(0) + 1);
            const offset_y: u16 = 2;
            try g.imagePos(offset_x, offset_y, R.ralph.imageOptions());
        }
        {
            const offset_x: u16 = @intCast(layout.offset(2) + 1);
            const offset_y: u16 = 2;
            try g.imagePos(offset_x, offset_y, R.ralph.imageOptions());
        }

        // Draw ships
        {
            const offset_x: u16 = @intCast(layout.offset(0) + 4);
            const offset_y: u16 = grid_start + 3;
            try drawPlacements(&g, offset_x, offset_y, player0.placements);
        }
        {
            const offset_x: u16 = @intCast(layout.offset(2) + 4);
            const offset_y: u16 = grid_start + 3;
            try drawPlacements(&g, offset_x, offset_y, player1.placements);
        }
        try self.stdout.flush();

        std.Thread.sleep(2000 * std.time.ns_per_ms);
        try self.sampleAnimation(&g);
        try g.setCursor(.{
            .row = 40,
            .col = 0,
        });
        try g.showCursor();
        try self.stdout.flush();
    }

    fn sampleAnimation(self: *Kitty, g: *Graphics) !void {
        for (0..5) |j| {
            const j_u32: u32 = @intCast(j);

            for (0..10) |i| {
                const i_u32: u32 = @intCast(i);
                try g.imagePos(
                    30,
                    20,
                    .{
                        .action = .put,
                        .image_id = R.ImageFile.explosion.id(),
                        .placement_id = 1,
                        .source_rect = .{
                            .x = 100 * i_u32,
                            .y = 100 * j_u32,
                            .w = 100,
                            .h = 100,
                        },
                        .zindex = 1,
                    },
                );
                try self.stdout.flush();
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
        std.Thread.sleep(2000 * std.time.ns_per_ms);
    }
};

fn drawPlacements(
    g: *Graphics,
    offset_x: u16,
    offset_y: u16,
    placements: []?Battleship.Placement,
) !void {
    for (0..placements.len) |i| {
        const placement = placements[i] orelse continue;
        const x = offset_x + placement.x * 6;
        const y = offset_y + placement.y * 3;
        const res = switch (placement.orientation) {
            .Horizontal => horizontal_ships[i],
            .Vertical => vertical_ships[i],
        };
        try g.imagePos(@intCast(x), y, res.imageOptions());
    }
}

const grid_template =
    \\     0     1     2     3     4     5     6     7     8     9    10
    \\  ╭─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────╮
    \\A │     │     │     │     │     │     │     │     │     │     │     │
    \\  │     │     │     │     │     │     │     │     │     │     │     │
    \\  ├─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
    \\B │     │     │     │     │     │     │     │     │     │     │     │
    \\  │     │     │     │     │     │     │     │     │     │     │     │
    \\  ├─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
    \\C │     │     │     │     │     │     │     │     │     │     │     │
    \\  │     │     │     │     │     │     │     │     │     │     │     │
    \\  ├─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
    \\D │     │     │     │     │     │     │     │     │     │     │     │
    \\  │     │     │     │     │     │     │     │     │     │     │     │
    \\  ├─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
    \\E │     │     │     │     │     │     │     │     │     │     │     │
    \\  │     │     │     │     │     │     │     │     │     │     │     │
    \\  ├─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
    \\F │     │     │     │     │     │     │     │     │     │     │     │
    \\  │     │     │     │     │     │     │     │     │     │     │     │
    \\  ├─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
    \\G │     │     │     │     │     │     │     │     │     │     │     │
    \\  │     │     │     │     │     │     │     │     │     │     │     │
    \\  ├─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
    \\H │     │     │     │     │     │     │     │     │     │     │     │
    \\  │     │     │     │     │     │     │     │     │     │     │     │
    \\  ├─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
    \\I │     │     │     │     │     │     │     │     │     │     │     │
    \\  │     │     │     │     │     │     │     │     │     │     │     │
    \\  ╰─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────╯
;

const horizontal_ships = [_]R{
    R.carrier_horizontal,
    R.battleship_horizontal,
    R.cruiser_horizontal,
    R.submarine_horizontal,
    R.destroyer_horizontal,
};
const vertical_ships = [_]R{
    R.carrier_vertical,
    R.battleship_vertical,
    R.cruiser_vertical,
    R.submarine_vertical,
    R.destroyer_vertical,
};

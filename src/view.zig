const std = @import("std");

const Battleship = @import("battleship.zig");
const Layout = @import("layout.zig");
const Graphics = @import("graphics.zig");
const R = @import("resource.zig");
const Tournament = @import("tournament.zig");

pub const Mode = enum {
    debug,
    kitty,
};

pub const Interface = union(Mode) {
    /// A simple text implementation
    debug: *Debug,

    /// A more involved implementation using the Kitty Graphics protocol
    kitty: *Kitty,

    pub fn deinit(self: Interface, gpa: std.mem.Allocator) !void {
        switch (self) {
            inline else => |variant| try variant.deinit(gpa),
        }
    }

    pub fn alloc(self: Interface, gpa: std.mem.Allocator) !void {
        switch (self) {
            inline else => |variant| try variant.alloc(gpa),
        }
    }

    pub fn startRound(self: Interface, game: *const Tournament.Game) !void {
        switch (self) {
            inline else => |variant| try variant.startRound(game),
        }
    }

    pub fn finishGame(self: Interface, winner_id: usize, game: *const Tournament.Game) !void {
        switch (self) {
            inline else => |variant| try variant.finishGame(winner_id, game),
        }
    }

    pub fn boards(self: Interface, game: *const Tournament.Game) !void {
        switch (self) {
            inline else => |variant| try variant.boards(game),
        }
    }
};

pub const Debug = struct {
    g: Graphics,

    pub fn init(stdout: *std.Io.Writer) Debug {
        return .{ .g = Graphics.init(stdout) };
    }

    pub fn deinit(self: *Debug, gpa: std.mem.Allocator) void {
        _ = self;
        _ = gpa;
    }

    fn alloc(self: *Debug, gpa: std.mem.Allocator) !void {
        _ = gpa;
        _ = self;
    }

    fn startRound(self: *Debug, game: *const Tournament.Game) !void {
        try self.g.setCursor(.{ .row = 0, .col = 0 });
        try self.g.eraseBelowCursor();
        try self.g.stdout.print("{s} vs {s}", .{ game.entries[0].name, game.entries[1].name });
        try self.g.stdout.flush();
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }

    fn finishGame(self: *Debug, winner_id: usize, game: *const Tournament.Game) !void {
        _ = game;
        try self.g.stdout.print("Player {d} won!\n", .{winner_id});
        try self.g.stdout.flush();
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }

    fn boards(self: *Debug, game: *const Tournament.Game) !void {
        try self.g.setCursor(.{ .row = 0, .col = 0 });
        try self.g.eraseBelowCursor();
        try self.g.stdout.print("Player 0: \n{f}", .{game.boards[0]});
        try self.g.stdout.print("Player 1: \n{f}", .{game.boards[1]});
        try self.g.stdout.flush();
    }
};

pub const Kitty = struct {
    g: Graphics,
    spacer0_col: Layout.Column = undefined,
    spacer1_col: Layout.Column = undefined,
    player_cols: [2]Layout.Column = undefined,
    last_winsize: std.posix.winsize = .{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 },

    pub fn init(stdout: *std.Io.Writer) Kitty {
        return .{ .g = Graphics.init(stdout) };
    }

    pub fn deinit(self: *Kitty, gpa: std.mem.Allocator) void {
        _ = gpa;
        self.g.showCursor() catch |err| std.log.err("couldn't show cursor: {}", .{err});
        self.g.stdout.flush() catch |err| std.log.err("flush: {}", .{err});
    }

    fn alloc(self: *Kitty, gpa: std.mem.Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const images: []const R.ImageFile = &.{
            R.ImageFile.spritesheet,
            R.ImageFile.water,
            R.ImageFile.ralf,
            R.ImageFile.hit,
            R.ImageFile.miss,
        };
        for (images) |img_file| {
            const bytes = R.load(arena_alloc, img_file) catch |err| {
                std.log.err("load file: {any}", .{img_file});
                return err;
            };
            try self.g.imageBytes(
                bytes,
                .{ .image_id = img_file.id(), .action = .transmit },
            );
            _ = arena.reset(.retain_capacity);
        }
        self.player_cols[0] = try Layout.Column.init(gpa, 100, 100);
        self.player_cols[1] = try Layout.Column.init(gpa, 100, 100);
        self.spacer0_col = try Layout.Column.init(gpa, 1, 100);
        self.spacer1_col = try Layout.Column.init(gpa, 1, 100);
        try self.g.hideCursor();
        // TODO: disable being able to type
    }

    fn startRound(self: *Kitty, game: *const Tournament.Game) !void {
        try self.g.setCursor(.{ .row = 0, .col = 0 });
        try self.g.eraseBelowCursor();
        try self.g.stdout.print("{s} vs {s}", .{ game.entries[0].name, game.entries[1].name });
        try self.g.stdout.flush();
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }

    fn finishGame(self: *Kitty, winner_id: usize, game: *const Tournament.Game) !void {
        _ = game;
        try self.g.stdout.print("Player {d} won!\n", .{winner_id});
        try self.g.stdout.flush();
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }

    fn boards(self: *Kitty, game: *const Tournament.Game) !void {
        self.spacer0_col.reset();
        self.spacer1_col.reset();
        for (&self.player_cols) |*c| c.reset();
        try self.g.setCursor(.{ .row = 0, .col = 0 });

        const winsize = Graphics.measureWindow();
        if (!std.meta.eql(winsize, self.last_winsize)) {
            // On size change everything will be drawn out of place. Erase everything and start fresh
            try self.g.setCursor(.{ .row = 1, .col = 1 });
            try self.g.eraseBelowCursor();
            try self.g.image(.{ .action = .delete });
            self.last_winsize = winsize;
        }

        // Write player columns
        var col_buffer: [256]u8 = undefined;
        const grid_start: u16 = 11;
        inline for (0..2) |i| {
            var col_writer = self.player_cols[i].writer(&col_buffer);
            var col = &col_writer.interface;
            try col.print("Player: {s}", .{game.entries[i].name});
            try col.splatByteAll('\n', grid_start);
            try col.print("{s}\n", .{grid_template});
            try col.flush();
        }

        // Space between the two player columns
        var spacer1_writer = self.spacer1_col.writer(&.{});
        const spacer1 = &spacer1_writer.interface;
        try spacer1.splatByteAll(' ', 5);

        const layout = Layout.init(
            &.{ &self.spacer0_col, &self.player_cols[0], &self.spacer1_col, &self.player_cols[1] },
        );
        if (winsize.col < layout.width() or winsize.row < layout.height() + 1) {
            try self.g.stdout.print("Window is too small to render game. Increase window size or decrease font size.", .{});
            try self.g.stdout.flush();
            return;
        }

        // Size the left margin such that the game is in the center
        const left_margin = (winsize.col - layout.width()) / 2;
        var spacer0_writer = self.spacer0_col.writer(&.{});
        const spacer0 = &spacer0_writer.interface;
        try spacer0.splatByteAll(' ', left_margin);

        // Render all the text
        try self.g.stdout.print("{f}", .{layout});

        // Render all the images
        // Every image drawn gets a placement_id. Only the pair (image_id, placement_id)
        // has to be unique. We use placement_ids so that existing images are moved

        // Draw contestant pics
        inline for (0..2) |i| {
            const offset_x: u16 = @intCast(layout.offset(i * 2) + 1);
            const offset_y: u16 = 2;
            var opts = R.ralph.imageOptions();
            opts.placement_id = i + 1;
            try self.g.imagePos(offset_x, offset_y, opts);
        }

        // Draw water
        const cell_offset_x: f32 = @as(f32, @floatFromInt(winsize.xpixel)) / @as(f32, @floatFromInt(winsize.col)) / 2 + 0.5;
        const cell_offset_y: f32 = @as(f32, @floatFromInt(winsize.ypixel)) / @as(f32, @floatFromInt(winsize.row)) / 2 + 0.5;
        inline for (0..2) |i| {
            var opts = R.water.imageOptions();
            opts.zindex = -1;
            // This offset is where to start drawing within a cell
            opts.offset_x = @intFromFloat(cell_offset_x);
            opts.offset_y = @intFromFloat(cell_offset_y);
            opts.placement_id = i + 1;
            // This offset is what cell to start drawing at
            const offset_x: u16 = @intCast(layout.offset(i * 2) + 3);
            const offset_y: u16 = grid_start + 2;
            try self.g.imagePos(offset_x, offset_y, opts);
        }

        // Draw ships
        var placement_id: u32 = 1;
        inline for (0..2) |i| {
            const player = game.boards[i].interface();
            const offset_x: u16 = @intCast(layout.offset(i * 2) + 4);
            const offset_y: u16 = grid_start + 3;
            try self.drawPlacements(placement_id, offset_x, offset_y, player.placements);
            placement_id += @intCast(player.placements.len);
        }
        try self.g.stdout.flush();
        try self.playGif(R.hit);
    }

    fn drawPlacements(
        self: *Kitty,
        placement_id: u32,
        offset_x: u16,
        offset_y: u16,
        placements: []const ?Battleship.Placement,
    ) !void {
        for (0..placements.len) |i| {
            const placement = placements[i] orelse continue;
            const x = offset_x + placement.x * 6;
            const y = offset_y + placement.y * 3;
            const res = switch (placement.orientation) {
                .Horizontal => horizontal_ships[i],
                .Vertical => vertical_ships[i],
            };
            var opts = res.imageOptions();
            const i_u32: u32 = @intCast(i);
            opts.placement_id = placement_id + i_u32;
            try self.g.imagePos(@intCast(x), y, opts);
        }
    }

    fn playGif(self: *Kitty, gif: R) !void {
        const sleep_time: u64 = 50;
        for (gif.frames) |frame| {
            try self.g.imagePos(
                32,
                20,
                .{
                    .action = .put,
                    .image_id = gif.image_file.id(),
                    .placement_id = 1,
                    .source_rect = .{ .x = frame.x, .y = frame.y, .w = frame.w, .h = frame.h },
                    .zindex = 1,
                    .rows = gif.rows,
                    .cols = gif.cols,
                },
            );
            try self.g.stdout.flush();
            std.Thread.sleep(sleep_time * std.time.ns_per_ms);
        }
    }
};
var debug_rng = std.Random.DefaultPrng.init(0);

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

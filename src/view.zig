const std = @import("std");

const Battleship = @import("battleship.zig");
const Layout = @import("layout.zig");
const Meta = @import("meta.zig");
const Graphics = @import("graphics.zig");
const R = @import("resource.zig");
const Tournament = @import("tournament.zig");

pub const Mode = enum {
    debug,
    kitty,
    unittest,
};

pub const Interface = union(Mode) {
    /// A simple text implementation
    debug: *Debug,

    /// A more involved implementation using the Kitty Graphics protocol
    kitty: *Kitty,

    /// For use in tests. Mostly does nothing
    unittest: *Unittest,

    pub fn deinit(self: Interface, gpa: std.mem.Allocator) !void {
        switch (self) {
            inline else => |variant| try variant.deinit(gpa),
        }
    }

    pub fn alloc(self: Interface, entries: []const Meta.Entry) !void {
        switch (self) {
            inline else => |variant| try variant.alloc(entries),
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

    pub fn leaderboard(
        self: Interface,
        entries: []const Meta.Entry,
        scores: []const Tournament.Score,
    ) !void {
        switch (self) {
            inline else => |variant| try variant.leaderboard(entries, scores),
        }
    }

    pub fn turn(self: Interface, game: *const Tournament.Game) !void {
        switch (self) {
            inline else => |variant| try variant.turn(game),
        }
    }

    /// player_id makes a shot at the other player
    pub fn fire(self: Interface, player_id: usize, shot: Point, kind: Battleship.Shot) !void {
        switch (self) {
            inline else => |variant| try variant.fire(player_id, shot, kind),
        }
    }

    pub fn clear(self: Interface) !void {
        switch (self) {
            inline else => |variant| try variant.clear(),
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

    fn alloc(self: *Debug, entries: []const Meta.Entry) !void {
        _ = self;
        _ = entries;
    }

    pub fn leaderboard(
        self: *Debug,
        entries: []const Meta.Entry,
        scores: []const Tournament.Score,
    ) !void {
        std.debug.assert(entries.len == scores.len);
        for (0..entries.len) |i| {
            try self.g.stdout.print("{s}: {any}\n", .{ entries[i].name, scores[i] });
        }
        try self.g.stdout.flush();
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

    fn turn(self: *Debug, game: *const Tournament.Game) !void {
        try self.g.setCursor(.{ .row = 0, .col = 0 });
        try self.g.eraseBelowCursor();
        try self.g.stdout.print("Player 0: \n{f}", .{game.boards[0]});
        try self.g.stdout.print("Player 1: \n{f}", .{game.boards[1]});
        try self.g.stdout.flush();
    }

    pub fn fire(self: *Debug, player_id: usize, shot: Point, kind: Battleship.Shot) !void {
        // Noop for debug
        _ = self;
        _ = player_id;
        _ = shot;
        _ = kind;
    }

    pub fn clear(self: *Debug) !void {
        // Noop for debug
        _ = self;
    }
};

pub const Unittest = struct {
    pub fn deinit(self: *Unittest, gpa: std.mem.Allocator) void {
        _ = self;
        _ = gpa;
    }

    fn alloc(self: *Unittest, entries: []const Meta.Entry) !void {
        _ = self;
        _ = entries;
    }

    pub fn leaderboard(
        self: *Unittest,
        entries: []const Meta.Entry,
        scores: []const Tournament.Score,
    ) !void {
        _ = self;
        _ = entries;
        _ = scores;
    }

    fn startRound(self: *Unittest, game: *const Tournament.Game) !void {
        _ = self;
        _ = game;
    }

    fn finishGame(self: *Unittest, winner_id: usize, game: *const Tournament.Game) !void {
        _ = self;
        _ = winner_id;
        _ = game;
    }

    fn turn(self: *Unittest, game: *const Tournament.Game) !void {
        _ = self;
        _ = game;
    }

    pub fn fire(self: *Unittest, player_id: usize, shot: Point, kind: Battleship.Shot) !void {
        _ = self;
        _ = player_id;
        _ = shot;
        _ = kind;
    }

    pub fn clear(self: *Unittest) !void {
        _ = self;
    }
};

pub const Kitty = struct {
    const grid_start: u16 = 11;

    g: Graphics,
    gpa: std.mem.Allocator,
    spacer0_col: Layout.Column = undefined,
    spacer1_col: Layout.Column = undefined,
    content0_col: Layout.Column = undefined,
    content1_col: Layout.Column = undefined,
    last_winsize: std.posix.winsize = .{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 },

    pub fn init(gpa: std.mem.Allocator, stdout: *std.Io.Writer) Kitty {
        return .{ .g = Graphics.init(stdout), .gpa = gpa };
    }

    pub fn deinit(self: *Kitty) void {
        self.g.showCursor() catch |err| std.log.err("couldn't show cursor: {}", .{err});
        self.g.stdout.flush() catch |err| std.log.err("flush: {}", .{err});
    }

    fn alloc(self: *Kitty, entries: []const Meta.Entry) !void {
        const start_ts = std.time.milliTimestamp();
        for (&R.Image.static) |image| {
            try self.g.imageBytes(
                image.bytes,
                .{ .image_id = image.id, .action = .transmit },
            );
        }
        for (entries) |entry| {
            const image = try R.Image.dynamic(self.gpa, entry.img);
            try self.g.imageBytes(
                image.bytes,
                .{ .image_id = image.id, .action = .transmit },
            );
        }
        self.content0_col = try Layout.Column.init(self.gpa, 100, 100);
        self.content1_col = try Layout.Column.init(self.gpa, 100, 100);
        self.spacer0_col = try Layout.Column.init(self.gpa, 1, 100);
        self.spacer1_col = try Layout.Column.init(self.gpa, 1, 100);
        try self.g.hideCursor();
        const elapsed = std.time.milliTimestamp() - start_ts;
        std.log.info("Took {d}ms to send image bytes", .{elapsed});
        // TODO: disable being able to type
    }

    pub fn leaderboard(
        self: *Kitty,
        entries: []const Meta.Entry,
        scores: []const Tournament.Score,
    ) !void {
        std.debug.assert(entries.len == scores.len);
        self.resetCols();
        try self.clear();
        const winsize = Graphics.measureWindow();
        const img_rows = 3;
        const img_cols = 6;
        const space_between_rows = 1;
        // Above this number of rows we will use two columns
        const two_col_threshold = winsize.row / (img_rows + space_between_rows);
        // We only draw this many entries
        const limit = two_col_threshold * 2 - 1;

        var buffer0: [256]u8 = undefined;
        var content_writer0 = self.content0_col.writer(&buffer0);
        const content0 = &content_writer0.interface;

        var buffer1: [256]u8 = undefined;
        var content_writer1 = self.content1_col.writer(&buffer1);
        const content1 = &content_writer1.interface;

        var spacer_writer0 = self.spacer0_col.writer(&.{});
        const spacer0 = &spacer_writer0.interface;

        var spacer_writer1 = self.spacer1_col.writer(&.{});
        const spacer1 = &spacer_writer1.interface;
        try spacer1.splatByteAll(' ', 10);
        try spacer1.flush();

        // Vertically center text with image
        try content0.splatByteAll('\n', img_rows / 2);
        try content1.splatByteAll('\n', img_rows / 2);

        // Write entry names from highest to lowest score
        var ordered_indices = try sortByScore(self.gpa, scores);
        if (ordered_indices.len > limit) {
            ordered_indices = ordered_indices[0..limit];
        }
        defer self.gpa.free(ordered_indices);

        for (ordered_indices, 1..) |i, place| {
            const content = if (place <= two_col_threshold) content0 else content1;
            try content.splatByteAll(' ', img_cols);
            try content.print("{d}. {s}: {f}\n", .{ place, entries[i].name, scores[i] });
            if (place != two_col_threshold)
                try content.splatByteAll('\n', space_between_rows + img_rows - 1);
        }
        if (entries.len > limit) try content1.print("...", .{});
        try content0.flush();
        try content1.flush();

        // Center the list in the window
        const cols = if (entries.len <= two_col_threshold)
            &.{ &self.spacer0_col, &self.content0_col }
        else
            &.{ &self.spacer0_col, &self.content0_col, &self.spacer1_col, &self.content1_col };

        const layout = Layout.init(cols);
        const left_margin = (winsize.col - layout.width()) / 2;
        try spacer0.splatByteAll(' ', left_margin);
        try spacer0.flush();

        // Render text
        try self.g.stdout.print("{f}", .{layout});

        // Draw entry images
        var img_y: u16 = 1;
        for (ordered_indices, 1..) |i, place| {
            const offset = if (place <= two_col_threshold) layout.offset(0) else layout.offset(2);
            const img_x: u16 = @intCast(offset);
            const res = try R.portraitNoAlloc(entries[i].img);
            var opts = res.imageOptions();
            opts.rows = img_rows;
            opts.cols = img_cols;
            try self.g.imagePos(img_x, img_y, opts);
            img_y += img_rows;
            img_y += space_between_rows;
            if (place == two_col_threshold) img_y = 1;
        }
        try self.g.stdout.flush();
        std.Thread.sleep(5000 * std.time.ns_per_ms);
        try self.clear();
    }

    fn startRound(self: *Kitty, game: *const Tournament.Game) !void {
        try self.g.setCursor(.{ .row = 0, .col = 0 });
        try self.g.eraseBelowCursor();
        try self.g.stdout.print("{s} vs {s}", .{ game.entries[0].name, game.entries[1].name });
        try self.g.stdout.flush();
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }

    fn finishGame(self: *Kitty, winner_id: usize, game: *const Tournament.Game) !void {
        const loser_id = (winner_id + 1) % 2;
        _ = game;
        const layout = Layout.init(
            &.{ &self.spacer0_col, &self.content0_col, &self.spacer1_col, &self.content1_col },
        );

        // Draw winner banner
        {
            var x: u16 = @intCast(layout.offset(winner_id * 2));
            if (R.winner.cols > x) {
                std.log.err("Screen to small to show finihsGame", .{});
                return;
            }
            x -= R.winner.cols;
            const y: u16 = 0;
            try self.g.imagePos(x, y, R.winner.imageOptions());
        }

        // Draw loser banner
        {
            var x: u16 = @intCast(layout.offset(loser_id * 2));
            if (R.loser.cols > x) {
                std.log.err("Screen to small to show finihsGame", .{});
                return;
            }
            x -= R.loser.cols;
            const y: u16 = 0;
            try self.g.imagePos(x, y, R.loser.imageOptions());
        }
        try self.g.stdout.flush();
        std.Thread.sleep(5000 * std.time.ns_per_ms);
    }

    fn turn(self: *Kitty, game: *const Tournament.Game) !void {
        self.resetCols();
        try self.g.setCursor(.{ .row = 0, .col = 0 });

        const winsize = Graphics.measureWindow();
        if (!std.meta.eql(winsize, self.last_winsize)) {
            // On size change everything will be drawn out of place. Erase everything and start fresh
            try self.clear();
            self.last_winsize = winsize;
        }

        // Write player columns
        var col_buffer: [256]u8 = undefined;
        const portrait_width: usize = 18;
        inline for (0..2) |i| {
            var col_writer = if (i == 0) self.content0_col.writer(&col_buffer) else self.content1_col.writer(&col_buffer);
            var col = &col_writer.interface;
            try col.splatByteAll(' ', portrait_width + 1);
            try col.print(" Player: {s}\n", .{game.entries[i].name});
            try col.splatByteAll(' ', portrait_width + 1);
            try col.print(
                " Round: {d} wins, {d} losses, {d} penalties\n",
                .{ game.scores[i].wins, game.scores[i].losses, game.scores[i].penalties },
            );
            try col.splatByteAll(' ', portrait_width + 1);
            try col.print(" Tournament: todo...\n", .{});

            try col.splatByteAll('\n', grid_start - 3);
            try col.print("{s}\n", .{grid_template});
            try col.flush();
        }

        // Space between the two player columns
        var spacer1_writer = self.spacer1_col.writer(&.{});
        const spacer1 = &spacer1_writer.interface;
        try spacer1.splatByteAll(' ', 5);

        const layout = Layout.init(
            &.{ &self.spacer0_col, &self.content0_col, &self.spacer1_col, &self.content1_col },
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
        var status_buffer: [256]u8 = undefined;
        var status = std.io.Writer.fixed(&status_buffer);
        try status.print(
            "Game {} of {}. Match {} of {}",
            .{ game.current_game, game.total_games, game.current_round, game.total_rounds },
        );
        const status_col: u16 = @intCast(winsize.col - status.buffered().len);
        try self.g.setCursor(.{ .row = winsize.row, .col = status_col });
        try self.g.stdout.writeAll(status.buffered());

        // Render all the images
        // Every image drawn gets a placement_id. Only the pair (image_id, placement_id)
        // has to be unique. We use placement_ids so that existing images are moved

        // Draw contestant pics
        inline for (0..2) |i| {
            const offset_x: u16 = @intCast(layout.offset(i * 2) + 1);
            const offset_y: u16 = 0;
            const res = try R.portraitNoAlloc(game.entries[i].img);
            var opts = res.imageOptions();
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
            const board = game.boards[i].interface();
            const offset_x: u16 = @intCast(layout.offset(i * 2) + 4);
            const offset_y: u16 = grid_start + 3;
            try self.drawShipPlacements(placement_id, offset_x, offset_y, board);
            placement_id += @intCast(board.placements.len);
        }

        // Draw past shot marks
        // The animation takes the 1 id, got to be a better way...
        var shot_placement_id: u32 = 2;
        inline for (0..2) |i| {
            const board = game.boards[i].interface();
            const offset_x: u16 = @intCast(layout.offset(i * 2) + 4);
            const offset_y: u16 = grid_start + 3;
            for (0..board.height) |y| {
                for (0..board.width) |x| {
                    const cell = board.at(x, y) catch unreachable;
                    const shot = cell.shot orelse continue;
                    const image: R = switch (shot) {
                        .Hit, .Sink => R.hit,
                        .Miss => R.miss,
                    };
                    const frame_idx = image.frames.len - 1;
                    var opts = image.imageOptions2(frame_idx);
                    opts.placement_id = shot_placement_id;
                    try self.g.imagePos(
                        offset_x + @as(u16, @intCast(x)) * 6,
                        offset_y + @as(u16, @intCast(y)) * 3,
                        opts,
                    );

                    shot_placement_id += 1;
                }
            }
        }
        try self.g.stdout.flush();
    }

    /// Assumes Kitty.boards has already been called
    pub fn fire(self: *Kitty, player_id: usize, shot: Point, kind: Battleship.Shot) !void {
        const other_player = (player_id + 1) % 2;
        const layout = Layout.init(
            &.{ &self.spacer0_col, &self.content0_col, &self.spacer1_col, &self.content1_col },
        );
        const col_id = other_player * 2;
        const offset_x: u16 = @as(u16, @intCast(layout.offset(col_id) + 4)) + shot.x * 6;
        const offset_y: u16 = grid_start + 3 + shot.y * 3;
        const gif: R = switch (kind) {
            .Hit, .Sink => R.hit,
            .Miss => R.miss,
        };
        try self.playGif(gif, offset_x, offset_y);
    }

    pub fn clear(self: *Kitty) !void {
        try self.g.setCursor(.{ .row = 1, .col = 1 });
        try self.g.eraseBelowCursor();
        try self.g.image(.{ .action = .delete });
    }

    fn drawShipPlacements(
        self: *Kitty,
        placement_id: u32,
        offset_x: u16,
        offset_y: u16,
        board: Battleship.BoardInterface,
    ) !void {
        for (0..board.placements.len) |i| {
            const placement = board.placements[i];
            const ship = board.ships[i];
            const x = offset_x + placement.x * 6;
            const y = offset_y + placement.y * 3;
            const res = switch (placement.orientation) {
                .Horizontal => horizontal_ships[i],
                .Vertical => vertical_ships[i],
            };
            const frame_id: usize = if (ship.hits >= ship.size) 1 else 0;
            var opts = res.imageOptions2(frame_id);
            const i_u32: u32 = @intCast(i);
            opts.placement_id = placement_id + i_u32;
            try self.g.imagePos(@intCast(x), y, opts);
        }
    }

    fn playGif(self: *Kitty, gif: R, x: u16, y: u16) !void {
        //var sleep_time: u64 = 55;
        var sleep_time: u64 = 0;
        for (gif.frames) |frame| {
            if (sleep_time > 10) sleep_time -= 2;

            try self.g.imagePos(
                x,
                y,
                .{
                    .action = .put,
                    .image_id = gif.image.id,
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

    fn resetCols(self: *Kitty) void {
        self.spacer0_col.reset();
        self.spacer1_col.reset();
        self.content0_col.reset();
        self.content1_col.reset();
    }
};

/// Returns a slice of indices that gives the sorted order of scores by scores[i].value()
/// from low to high
fn sortByScore(gpa: std.mem.Allocator, scores: []const Tournament.Score) ![]usize {
    const ordered_indices = try gpa.alloc(usize, scores.len);
    for (0..scores.len) |i| ordered_indices[i] = i;

    const Context = struct {
        scores: []const Tournament.Score,

        pub fn lessThan(this: *@This(), idx0: usize, idx1: usize) bool {
            return this.scores[idx0].value() > this.scores[idx1].value();
        }
    };
    var ctx = Context{ .scores = scores };
    std.mem.sort(usize, ordered_indices, &ctx, Context.lessThan);
    return ordered_indices;
}

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
    R.destroyer_horizontal,
    R.submarine_horizontal,
    R.cruiser_horizontal,
    R.battleship_horizontal,
    R.carrier_horizontal,
};
const vertical_ships = [_]R{
    R.destroyer_vertical,
    R.submarine_vertical,
    R.cruiser_vertical,
    R.battleship_vertical,
    R.carrier_vertical,
};

pub const Point = struct {
    x: u16,
    y: u16,
};

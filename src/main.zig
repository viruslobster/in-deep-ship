const std = @import("std");
const Battleship = @import("battleship.zig");
const Protocol = @import("protocol.zig");
const Meta = @import("meta.zig");

const game_ships: [5]Battleship.Ship = .{
    .{ .size = 5 },
    .{ .size = 4 },
    .{ .size = 3 },
    .{ .size = 3 },
    .{ .size = 2 },
};

const game_width = 10;
const game_height = 10;
const BattleshipBoard = Battleship.Board(game_width, game_height, &game_ships);
const Game = struct {
    players: [2]Player,
    boards: [2]BattleshipBoard,
    radars: [2]BattleshipBoard,
    penalties: [2]u32,

    fn init(gpa: std.mem.Allocator, entry0: *const Meta.Entry, entry1: *const Meta.Entry) Game {
        const boards = [2]BattleshipBoard{
            BattleshipBoard.init(),
            BattleshipBoard.init(),
        };
        return .{
            .players = [2]Player{
                Player.init(entry0, gpa),
                Player.init(entry1, gpa),
            },
            .boards = boards,
            .radars = boards,
            .penalties = [2]u32{ 0, 0 },
        };
    }

    pub fn deinit(self: *Game) void {
        for (&self.players) |*p| p.deinit();
    }

    pub fn allPlaced(self: *Game) bool {
        for (&self.boards) |*b| if (!b.allPlaced()) return false;
        return true;
    }

    fn playerIndex(self: *Game, player: *Player) usize {
        if (&self.players[0] == player) return 0;
        return 1;
    }

    fn startRound(self: *Game) !void {
        for (&self.players) |*player| {
            try player.spawn();
            try player.writeMessage(.{ .round_start = {} });
        }
    }

    fn resetState(self: *Game) !void {
        self.boards = [2]BattleshipBoard{ BattleshipBoard.init(), BattleshipBoard.init() };
        self.radars = [2]BattleshipBoard{ BattleshipBoard.init(), BattleshipBoard.init() };
    }

    fn placeShips(self: *Game, player_id: usize, placements: []const Protocol.Placement) !void {
        const player = &self.players[player_id];
        const board = &self.boards[player_id];
        placeIfValid(board, placements) catch |err| {
            std.log.err("{s}: placements '{any}' are invalid: {}", .{ player.entry.name, placements, err });
            return error.InvalidPlacement;
        };
        std.log.info("{s}: placed ships", .{player.entry.name});
        return;
    }

    fn takeTurn(self: *Game, player_id: usize, x: usize, y: usize) !void {
        const player = &self.players[player_id];
        const other = (player_id + 1) % 2;
        const other_board = &self.boards[other];
        const other_player = &self.players[other];
        const shot = other_board.fire(x, y);
        try player.writeMessage(.{ .turn_result = .{
            .x = x,
            .y = y,
            .shot = protocolShot(shot),
            .who = .you,
        } });
        try other_player.writeMessage(.{ .turn_result = .{
            .x = x,
            .y = y,
            .shot = protocolShot(shot),
            .who = .enemy,
        } });
        return;
    }
};

fn protocolShot(shot: Battleship.Shot) Protocol.Shot {
    return switch (shot) {
        .Miss => .{ .miss = {} },
        .Hit => .{ .hit = {} },
        .Sink => |ship| .{ .sink = ship.size },
    };
}

fn placeIfValid(board: *BattleshipBoard, placements: []const Protocol.Placement) !void {
    const empty_board = BattleshipBoard.init();
    if (!std.meta.eql(board.*, empty_board)) return error.BoardDirty;

    for (placements) |placement| {
        board.place(placement.size, placement.x, placement.y, placement.orientation) catch |err| {
            board.* = empty_board;
            return err;
        };
    }
    for (&board.placed) |placed| if (!placed) return error.NotAllShipsPlaced;
}

pub const Player = struct {
    entry: *const Meta.Entry,
    stdin_buffer: [256]u8 = undefined,
    stdout_buffer: [256]u8 = undefined,
    child: ?std.process.Child = null,
    stdout: ?std.fs.File.Reader = null,
    stdin: ?std.fs.File.Writer = null,
    gpa: std.mem.Allocator,

    pub fn init(entry: *const Meta.Entry, gpa: std.mem.Allocator) Player {
        return .{
            .entry = entry,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Player) void {
        if (self.child) |*child| {
            _ = child.kill() catch |err| {
                std.log.err("Failed to kill {s}: {}", .{ self.entry.name, err });
            };
        }
    }

    pub fn spawn(self: *Player) !void {
        var child = std.process.Child.init(&.{self.entry.runnable}, self.gpa);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        const stdout = child.stdout orelse return error.NoOutput;
        const stdin = child.stdin orelse return error.NoInput;

        try setNonBlocking(stdout.handle);
        try setNonBlocking(stdin.handle);
        self.child = child;
        self.stdout = stdout.reader(&self.stdout_buffer);
        self.stdin = stdin.writer(&self.stdin_buffer);
    }

    pub fn writeMessage(self: *Player, message: Protocol.Message) !void {
        const child = self.child orelse return error.MustCallSpawnFirst;

        if (self.stdin == null) {
            const stdin = child.stdin orelse unreachable;
            self.stdin = stdin.writer(&self.stdin_buffer);
        }
        const stdin = &(self.stdin orelse unreachable);
        try stdin.interface.print("{f}\n", .{message});
        try stdin.interface.flush();
    }

    pub fn pollMessage(self: *Player) !?Protocol.Message {
        const child = self.child orelse return error.MustCallSpawnFirst;

        if (self.stdout == null) {
            const stdout = child.stdout orelse unreachable;
            self.stdout = stdout.reader(&self.stdout_buffer);
        }
        const stdout = &(self.stdout orelse unreachable);
        const message = Protocol.Message.parse(&stdout.interface, self.gpa) catch |err| {
            if (err != error.ReadFailed) return err;

            const actual_err = stdout.err orelse unreachable;
            switch (actual_err) {
                error.WouldBlock => return null,
                else => return err,
            }
        };
        return message;
    }
};

fn playDebug(
    gpa: std.mem.Allocator,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    random: std.Random,
    entry0: *const Meta.Entry,
    entry1: *const Meta.Entry,
) !void {
    _ = stdin;
    _ = random;
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();

    var game = Game.init(arena_allocator.allocator(), entry0, entry1);
    defer game.deinit();
    try game.startRound();
    var wins = [2]u8{ 0, 0 };
    for (0..3) |i| {
        try setCursor(stdout, .{ .row = 0, .col = 0 });
        try eraseBelowCursor(stdout);
        try stdout.print("Round {d}", .{i});
        try stdout.flush();

        std.Thread.sleep(1000 * std.time.ns_per_ms);
        const winner_id = try playGame(&game, stdout, &arena_allocator);

        try stdout.print("Player {d} won!\n", .{winner_id});
        try stdout.flush();
        std.Thread.sleep(1000 * std.time.ns_per_ms);
        wins[winner_id] += 1;
    }
    try stdout.print("Player 0: {d} wins\n", .{wins[0]});
    try stdout.print("Player 1: {d} wins\n", .{wins[1]});
}

/// Returns the id of the winning player
fn playGame(game: *Game, stdout: *std.Io.Writer, arena_alloc: *std.heap.ArenaAllocator) !usize {
    std.log.debug("Starting game", .{});
    try game.resetState();

    for (&game.players) |*player| {
        try player.writeMessage(.{ .game_start = {} });
        try player.writeMessage(.{ .place_ships_request = {} });
    }

    std.log.debug("Placing ships...", .{});
    // Place ships
    var player_id: usize = 0;
    while (true) {
        player_id = (player_id + 1) % 2;
        const player = &game.players[player_id];
        const maybe_message = try player.pollMessage();
        const message = maybe_message orelse continue;
        switch (message) {
            .place_ships_response => |placements| {
                game.placeShips(player_id, placements) catch |err| {
                    std.log.err("Place ships response: {}", .{err});
                    switch (err) {
                        error.InvalidPlacement => try player.writeMessage(.{ .place_ships_request = {} }),
                        else => return err,
                    }
                };
            },
            else => std.log.info("{s}: Unexpected message: {f}", .{ player.entry.name, message }),
        }
        if (game.allPlaced()) break;
        std.log.debug("Waiting for ships to be placed", .{});
    }

    std.log.debug("Ships placed", .{});
    // Take turns
    // TODO: randomize player_id
    while (true) {
        try playGameTurn(game, player_id);

        try setCursor(stdout, .{ .row = 0, .col = 0 });
        try eraseBelowCursor(stdout);
        try stdout.print("Player 0: \n{f}", .{game.boards[0]});
        try stdout.print("Player 1: \n{f}", .{game.boards[1]});
        try stdout.flush();

        if (game.boards[0].allSunk()) {
            try game.players[0].writeMessage(.{ .lose = {} });
            try game.players[1].writeMessage(.{ .win = {} });
            return 1;
        } else if (game.boards[1].allSunk()) {
            try game.players[0].writeMessage(.{ .win = {} });
            try game.players[1].writeMessage(.{ .lose = {} });
            return 0;
        }

        player_id = (player_id + 1) % 2;
        _ = arena_alloc.reset(.retain_capacity);
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn playGameTurn(game: *Game, player_id: usize) !void {
    const player = &game.players[player_id];
    try player.writeMessage(.{ .turn_request = {} });
    const t0 = std.time.milliTimestamp();

    while (true) {
        const maybe_message = try player.pollMessage();
        const message = maybe_message orelse {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        const elapsed = std.time.milliTimestamp() - t0;
        if (elapsed > 1010) {
            std.log.info("{s} took too long to respond!", .{player.entry.name});
            game.penalties[player_id] += 1;
        }

        switch (message) {
            .turn_response => |turn| try game.takeTurn(player_id, turn.x, turn.y),
            else => {
                std.log.info("{s}: Unexpected message: {f}", .{ player.entry.name, message });
                continue;
            },
        }
        break;
    }
}

fn setNonBlocking(handle: std.fs.File.Handle) !void {
    var flags = try std.posix.fcntl(handle, std.posix.F.GETFL, 0);
    flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = try std.posix.fcntl(handle, std.posix.F.SETFL, flags);
}

const Cursor = struct { row: u8, col: u8 };

pub fn setCursor(stdout: *std.Io.Writer, cursor: Cursor) !void {
    try stdout.print("\x1b[{};{}H", .{ cursor.row, cursor.col });
}

pub fn eraseBelowCursor(stdout: *std.Io.Writer) !void {
    try stdout.print("\x1b[J", .{});
}

fn help(stderr: *std.Io.Writer) !void {
    try stderr.print("Usage: in-deep-ship [play | debug]\n", .{});
}

fn helpDebug(stderr: *std.Io.Writer) !void {
    try stderr.print(
        \\Usage: in-deep-ship debug PLAYER0 PLAYER1
        \\
        \\  PLAYER0 and PLAYER1 are paths to executables
        \\
        \\  Hint: use in-deep-ship debug path0 path1 2>/tmp/stderr
        \\  and tail -f /tmp/stderr in another window
        \\
    , .{});
}

pub fn main() !void {
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const seed: u64 = @intCast(std.time.microTimestamp());
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    var args = std.process.args();
    // Skip binary file path
    if (!args.skip()) {
        try help(stderr);
        return;
    }
    const command = args.next() orelse {
        try help(stderr);
        return;
    };
    if (std.mem.eql(u8, "play", command)) {
        try stdout.print("todo\n", .{});
        return;
    }
    if (std.mem.eql(u8, "debug", command)) {
        const runnable0 = args.next();
        const runnable1 = args.next();
        if (runnable0 == null or runnable1 == null) {
            try helpDebug(stderr);
            return;
        }
        const entry0: Meta.Entry = .{
            .name = "player0",
            .runnable = runnable0 orelse unreachable,
            .img = &.{},
            .emote = &.{},
        };
        const entry1: Meta.Entry = .{
            .name = "player1",
            .runnable = runnable1 orelse unreachable,
            .img = &.{},
            .emote = &.{},
        };
        try playDebug(std.heap.page_allocator, stdin, stdout, random, &entry0, &entry1);
        return;
    }
    try help(stderr);
}

test {
    std.testing.refAllDeclsRecursive(Protocol);
}

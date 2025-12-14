const std = @import("std");
const View = @import("view.zig");

const Battleship = @import("battleship.zig");
const Meta = @import("meta.zig");
const Protocol = @import("protocol.zig");
const Graphics = @import("graphics.zig");

const Self = @This();
gpa: std.mem.Allocator,
stdin: *std.Io.Reader,
stdout: *std.Io.Writer,
random: std.Random,
entries: []const Meta.Entry,
scores: []Score,
cwd: []const u8,

pub fn init(
    gpa: std.mem.Allocator,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    random: std.Random,
    entries: []const Meta.Entry,
    cwd: []u8,
) !Self {
    const scores = try gpa.alloc(Score, entries.len);
    for (scores) |*s| s.* = .{};
    return .{
        .gpa = gpa,
        .stdin = stdin,
        .stdout = stdout,
        .random = random,
        .entries = entries,
        .cwd = cwd,
        .scores = scores,
    };
}

pub fn deinit(self: *Self) void {
    self.gpa.free(self.scores);
}

fn factorial(x: u64) u64 {
    if (x <= 1) return 1;
    return x * factorial(x - 1);
}

// TODO: this overflows easily. Use the additive formula
fn n_choose_k(n: u32, k: u32) u32 {
    const result = factorial(@intCast(n)) / (factorial(@intCast(k)) * factorial(@intCast(n - k)));
    return @intCast(result);
}

pub fn play(self: *Self, view: View.Interface) !void {
    var g = Graphics.init(self.stdout);
    // Clear any previous images
    try g.image(.{ .action = .delete });

    try view.alloc(self.entries);
    var played_pairs = std.AutoHashMap([2]usize, void).init(self.gpa);
    const players_len: u32 = @intCast(self.entries.len);
    const pairs_len = n_choose_k(players_len, 2);
    try played_pairs.ensureTotalCapacity(pairs_len);

    var player0_id = self.random.intRangeLessThan(usize, 0, players_len);
    var player1_id = self.random.intRangeLessThan(usize, 0, players_len);
    if (player0_id == player1_id) player1_id = (player1_id + 1) % players_len;

    var game_num: u32 = 1;
    while (true) {
        std.debug.assert(player0_id != player1_id);

        const key = pairKey(player0_id, player1_id);
        std.debug.assert(!played_pairs.contains(key));
        try played_pairs.put(key, {});

        try view.leaderboard(self.entries, self.scores);
        const winner = try self.playRound(view, player0_id, player1_id, game_num, pairs_len);
        std.debug.assert(winner == player0_id or winner == player1_id);

        if (played_pairs.count() == pairs_len) break;
        const pair = nextPair(winner, player0_id, player1_id, played_pairs, players_len);
        player0_id = pair[0];
        player1_id = pair[1];
        game_num += 1;
    }
    try view.leaderboard(self.entries, self.scores);
}

fn nextPair(
    winner_id: usize,
    player0_id: usize,
    player1_id: usize,
    played_pairs: std.AutoHashMap([2]usize, void),
    players_len: usize,
) [2]usize {
    // Find an unplayed match with the last winner
    var result = [2]usize{ player0_id, player1_id };
    var idx: usize = if (winner_id == player0_id) 1 else 0;
    for (0..players_len) |_| {
        result[idx] = (result[idx] + 1) % players_len;
        if (result[0] == result[1]) continue;
        const k = pairKey(result[0], result[1]);
        if (!played_pairs.contains(k)) return result;
    }
    // Winner has already player every match, just take the next available match
    idx = (idx + 1) % 2;
    for (0..players_len) |_| {
        result[idx] = (result[idx] + 1) % players_len;
        if (result[0] == result[1]) continue;
        const k = pairKey(result[0], result[1]);
        if (!played_pairs.contains(k)) return result;
    }
    // Should be unreachable if there is an unplayed match
    std.debug.assert(false);
    return result;
}

fn pairKey(player0_id: usize, player1_id: usize) [2]usize {
    var key = [2]usize{ player0_id, player1_id };
    std.mem.sort(usize, &key, {}, std.sort.asc(usize));
    return key;
}

// Returns either player_id0 or player_id1, depending on which player won
fn playRound(
    self: *Self,
    view: View.Interface,
    player0_id: usize,
    player1_id: usize,
    current_round: u32,
    total_rounds: u32,
) !usize {
    var arena_allocator = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_allocator.deinit();

    const total_games = 3;
    var game = Game.init(
        arena_allocator.allocator(),
        &self.entries[player0_id],
        &self.entries[player1_id],
        total_games,
        current_round,
        total_rounds,
    );
    defer game.deinit();
    try game.startRound();
    try view.startRound(&game);
    for (0..total_games) |_| {
        try view.clear();
        // winner and loser ids are 0 or 1 (relative to `game`). They are NOT player0_id or player1_id.
        const winner_id = try playGame(&game, view, &arena_allocator);
        const loser_id = (winner_id + 1) % 2;
        game.scores[winner_id].wins += 1;
        game.scores[loser_id].losses += 1;
        try view.turn(&game);
        try view.finishGame(winner_id, &game);

        game.current_game += 1;
        _ = arena_allocator.reset(.retain_capacity);
    }
    self.scores[player0_id].add(game.scores[0]);
    self.scores[player1_id].add(game.scores[1]);
    // TODO: can there be a tie here? what are the ramifications?
    return if (game.scores[0].value() >= game.scores[1].value()) player0_id else player1_id;
}

/// Returns the id of the winning player
fn playGame(game: *Game, view: View.Interface, arena_alloc: *std.heap.ArenaAllocator) !usize {
    std.log.debug("Starting game", .{});
    try game.resetState();

    for (&game.players) |*player| {
        try player.writeMessage(.{ .game_start = {} });
        try player.writeMessage(.{ .place_ships_request = {} });
    }

    std.log.debug("Placing ships...", .{});
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
            else => std.log.info("{s}: !Unexpected message: {f}", .{ player.entry.name, message }),
        }
        if (game.allPlaced()) {
            std.log.debug("All placed", .{});
            break;
        }
        std.log.debug("Waiting for ships to be placed", .{});
    }

    std.log.debug("Ships placed", .{});
    // Take turns
    // TODO: randomize player_id
    while (true) {
        try view.turn(game);

        if (game.boards[0].allSunk()) {
            try game.players[0].writeMessage(.{ .lose = {} });
            try game.players[1].writeMessage(.{ .win = {} });
            return 1;
        } else if (game.boards[1].allSunk()) {
            try game.players[0].writeMessage(.{ .win = {} });
            try game.players[1].writeMessage(.{ .lose = {} });
            return 0;
        }

        try playGameTurn(game, view, player_id);

        player_id = (player_id + 1) % 2;
        _ = arena_alloc.reset(.retain_capacity);
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn playGameTurn(game: *Game, view: View.Interface, player_id: usize) !void {
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
            game.scores[player_id].penalties += 1;
        }

        switch (message) {
            .turn_response => |turn| {
                const shot = try game.takeTurn(player_id, turn.x, turn.y);
                try view.fire(
                    player_id,
                    .{
                        .x = @intCast(turn.x),
                        .y = @intCast(turn.y),
                    },
                    shot,
                );
            },
            else => {
                std.log.info("{s}: Unexpected message: {f}", .{ player.entry.name, message });
                continue;
            },
        }
        break;
    }
}

fn sortShips(ships: []Battleship.Ship) void {
    const Context = struct {
        fn lessThan(_: @This(), ship0: Battleship.Ship, ship1: Battleship.Ship) bool {
            return ship0.size < ship1.size;
        }
    };
    const ctx = Context{};
    std.mem.sort(Battleship.Ship, ships, ctx, Context.lessThan);
}

fn sortPlacements(placements: []Battleship.Placement) void {
    const Context = struct {
        fn lessThan(_: @This(), p0: Battleship.Placement, p1: Battleship.Placement) bool {
            return p0.size < p1.size;
        }
    };
    const ctx = Context{};
    std.mem.sort(Battleship.Placement, placements, ctx, Context.lessThan);
}

const game_ships: [5]Battleship.Ship = .{
    .{ .size = 2 },
    .{ .size = 3 },
    .{ .size = 3 },
    .{ .size = 4 },
    .{ .size = 5 },
};

test "game-ships-sorted" {
    var copy = game_ships;
    sortShips(&copy);
    for (0..game_ships.len) |i| {
        try std.testing.expectEqual(game_ships[i].size, copy[i].size);
    }
}

pub const PlayerProcess = struct {
    entry: *const Meta.Entry,
    stdin_buffer: [256]u8 = undefined,
    stdout_buffer: [256]u8 = undefined,
    child: ?std.process.Child = null,
    stdout: ?std.fs.File.Reader = null,
    stdin: ?std.fs.File.Writer = null,
    gpa: std.mem.Allocator,

    pub fn init(entry: *const Meta.Entry, gpa: std.mem.Allocator) PlayerProcess {
        return .{
            .entry = entry,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *PlayerProcess) void {
        if (self.child) |*child| {
            _ = child.kill() catch |err| {
                std.log.err("Failed to kill {s}: {}", .{ self.entry.name, err });
            };
        }
    }

    pub fn spawn(self: *PlayerProcess) !void {
        // If we don't make sure the file exists like this the child process will
        // might silently
        const file = std.fs.openFileAbsolute(self.entry.runnable, .{}) catch |err| {
            std.log.err("could not open '{s}'", .{self.entry.runnable});
            return err;
        };
        file.close();

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

    fn setNonBlocking(handle: std.fs.File.Handle) !void {
        var flags = try std.posix.fcntl(handle, std.posix.F.GETFL, 0);
        flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
        // TODO: don't ignore
        _ = try std.posix.fcntl(handle, std.posix.F.SETFL, flags);
    }

    pub fn writeMessage(self: *PlayerProcess, message: Protocol.Message) !void {
        const child = self.child orelse return error.MustCallSpawnFirst;

        if (self.stdin == null) {
            const stdin = child.stdin orelse unreachable;
            self.stdin = stdin.writer(&self.stdin_buffer);
        }
        const stdin = &(self.stdin orelse unreachable);
        try stdin.interface.print("{f}\n", .{message});
        try stdin.interface.flush();
    }

    pub fn pollMessage(self: *PlayerProcess) !?Protocol.Message {
        const child = if (self.child) |*child| child else return error.MustCallSpawnFirst;

        if (self.stdout == null) {
            const stdout = child.stdout orelse unreachable;
            self.stdout = stdout.reader(&self.stdout_buffer);
        }
        const stdout = &(self.stdout orelse unreachable);
        const message = Protocol.Message.parse(&stdout.interface, self.gpa) catch |err| {
            // TODO: actually impl for UnknownMessage
            if (err == error.UnknownMessage) return null;
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

const game_width = 11;
const game_height = 9;
const BattleshipBoard = Battleship.Board(game_width, game_height, &game_ships);
pub const Game = struct {
    entries: [2]*const Meta.Entry,
    players: [2]PlayerProcess,
    boards: [2]BattleshipBoard = undefined,
    scores: [2]Score = [2]Score{ .{}, .{} },
    placed: u8 = 0,

    current_game: u32 = 1,
    total_games: u32,
    current_round: u32,
    total_rounds: u32,

    fn init(
        gpa: std.mem.Allocator,
        entry0: *const Meta.Entry,
        entry1: *const Meta.Entry,
        total_games: u32,
        current_round: u32,
        total_rounds: u32,
    ) Game {
        return .{
            .entries = [2]*const Meta.Entry{ entry0, entry1 },
            .players = [2]PlayerProcess{
                PlayerProcess.init(entry0, gpa),
                PlayerProcess.init(entry1, gpa),
            },
            .total_games = total_games,
            .current_round = current_round,
            .total_rounds = total_rounds,
        };
    }

    pub fn deinit(self: *Game) void {
        for (&self.players) |*p| p.deinit();
    }

    pub fn allPlaced(self: *Game) bool {
        return self.placed >= 2;
    }

    fn playerIndex(self: *Game, player: *PlayerProcess) usize {
        if (&self.players[0] == player) return 0;
        return 1;
    }

    fn startRound(self: *Game) !void {
        for (&self.players) |*player| {
            std.log.debug("Player entry: {f}", .{player.entry});
            try player.spawn();
            try player.writeMessage(.{ .round_start = {} });
            std.log.debug("spawned player '{s}'", .{player.entry.name});
        }
    }

    fn resetState(self: *Game) !void {
        self.placed = 0;
    }

    fn placeShips(
        self: *Game,
        player_id: usize,
        placements: []Battleship.Placement,
    ) !void {
        const player = &self.players[player_id];
        const board = &self.boards[player_id];
        sortPlacements(placements);
        board.* = BattleshipBoard.init(placements) catch |err| {
            std.log.err(
                "{s}: placements '{any}' are invalid: {}",
                .{ player.entry.name, placements, err },
            );
            return error.InvalidPlacement;
        };
        std.log.info("{s}: placed ships", .{player.entry.name});
        self.placed += 1;
        return;
    }

    fn takeTurn(self: *Game, player_id: usize, x: usize, y: usize) !Battleship.Shot {
        const player = &self.players[player_id];
        const other = (player_id + 1) % 2;
        const other_board = &self.boards[other];
        const other_player = &self.players[other];
        const shot = other_board.fire(x, y);
        try player.writeMessage(.{ .turn_result = .{
            .x = x,
            .y = y,
            .shot = protocolShot(shot, other_board),
            .who = .you,
        } });
        try other_player.writeMessage(.{ .turn_result = .{
            .x = x,
            .y = y,
            .shot = protocolShot(shot, other_board),
            .who = .enemy,
        } });
        return shot;
    }

    fn protocolShot(shot: Battleship.Shot, board: *BattleshipBoard) Protocol.Shot {
        return switch (shot) {
            .Miss => .{ .miss = {} },
            .Hit => .{ .hit = {} },
            .Sink => |id| .{ .sink = board.getShip(id).size },
        };
    }
};

pub const Score = struct {
    wins: i32 = 0,
    losses: i32 = 0,
    penalties: i32 = 0,

    pub fn value(self: Score) i32 {
        return 10 * (self.wins - self.losses) - self.penalties;
    }

    pub fn format(self: Score, sink: *std.Io.Writer) !void {
        const win_str = if (self.wins != 1) "wins" else "win";
        const loss_str = if (self.losses != 1) "losses" else "loss";
        const penalty_str = if (self.penalties != 1) "penalties" else "penalty";
        try sink.print(
            "{d} ({d} {s}, {d} {s}, {d} {s})",
            .{
                self.value(),
                self.wins,
                win_str,
                self.losses,
                loss_str,
                self.penalties,
                penalty_str,
            },
        );
    }

    pub fn add(self: *Score, other: Score) void {
        self.wins += other.wins;
        self.losses += other.losses;
        self.penalties += other.penalties;
    }
};

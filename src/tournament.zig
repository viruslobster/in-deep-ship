const std = @import("std");

const View = @import("view.zig");
const Battleship = @import("battleship.zig");
const Meta = @import("meta.zig");
const Protocol = @import("protocol.zig");
const Graphics = @import("graphics.zig");
const Time = @import("time.zig");
const TestPlayer = @import("test_player.zig");
const Bridge = @import("bridge.zig");

const Self = @This();
gpa: std.mem.Allocator,
time: Time,
stdin: *std.Io.Reader,
stdout: *std.Io.Writer,
random: std.Random,
entries: []const Meta.Entry,
scores: []Score,
cwd: []const u8,

pub fn init(
    gpa: std.mem.Allocator,
    time: Time,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    random: std.Random,
    entries: []const Meta.Entry,
    cwd: []const u8,
) !Self {
    const scores = try gpa.alloc(Score, entries.len);
    for (scores) |*s| s.* = .{};
    return .{
        .gpa = gpa,
        .time = time,
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
        try view.leaderboard(self.entries, self.scores);

        std.debug.assert(player0_id != player1_id);
        const key = pairKey(player0_id, player1_id);
        std.debug.assert(!played_pairs.contains(key));
        try played_pairs.put(key, {});

        const entry0 = &self.entries[player0_id];
        var process0 = try spawnEntry(self.gpa, entry0);
        defer process0.kill(entry0);
        var stdin_buffer0: [256]u8 = undefined;
        var stdout_buffer0: [256]u8 = undefined;
        var player0_process = Bridge.File.init(
            process0.stdin,
            process0.stdout,
            &stdin_buffer0,
            &stdout_buffer0,
        );

        const entry1 = &self.entries[player1_id];
        var process1 = try spawnEntry(self.gpa, entry1);
        defer process1.kill(entry1);
        var stdin_buffer1: [256]u8 = undefined;
        var stdout_buffer1: [256]u8 = undefined;
        var player1_process = Bridge.File.init(
            process1.stdin,
            process1.stdout,
            &stdin_buffer1,
            &stdout_buffer1,
        );

        const total_games = 3;
        var game = Game.init(
            player0_id,
            player1_id,
            .{ .file = &player0_process },
            .{ .file = &player1_process },
            &self.entries[player0_id],
            &self.entries[player1_id],
            total_games,
            game_num,
            pairs_len,
        );
        defer game.deinit();

        const winner = try self.playRound(view, &game);
        std.debug.assert(winner == player0_id or winner == player1_id);

        if (played_pairs.count() == pairs_len) break;
        const pair = nextPair(winner, player0_id, player1_id, played_pairs, players_len);
        player0_id = pair[0];
        player1_id = pair[1];
        game_num += 1;
    }
    try view.leaderboard(self.entries, self.scores);
}

// Returns either player_id0 or player_id1, depending on which player won
fn playRound(
    self: *Self,
    view: View.Interface,
    game: *Game,
) !usize {
    var arena_allocator = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_allocator.deinit();

    try game.startRound();
    try view.startRound(game);
    for (0..game.total_games) |_| {
        try view.clear();
        self.playGame(game, view, &arena_allocator) catch |err| switch (err) {
            error.PlayerError => std.log.info("Game halted early because of uncooperative player", .{}),
            else => return err,
        };
        try view.turn(game);
        const winner_id = game.winner();
        try view.finishGame(winner_id, game);

        game.current_game += 1;
        _ = arena_allocator.reset(.retain_capacity);
    }
    self.scores[game.player0_id].add(game.scores[0]);
    self.scores[game.player1_id].add(game.scores[1]);
    // TODO: can there be a tie here? what are the ramifications?
    return if (game.scores[0].value() >= game.scores[1].value()) game.player0_id else game.player1_id;
}

/// Returns the id of the winning player
pub fn playGame(
    self: *Self,
    game: *Game,
    view: View.Interface,
    arena_alloc: *std.heap.ArenaAllocator,
) !void {
    const gpa = arena_alloc.allocator();
    std.log.debug("Starting game", .{});

    for (&game.players) |player| {
        try player.writeMessage(.{ .game_start = {} });
        try player.writeMessage(.{ .place_ships_request = {} });
    }

    std.log.debug("Placing ships...", .{});
    try self.placeShips(gpa, game);
    std.log.debug("Ships placed", .{});

    // Take turns
    // TODO: randomize player_id
    var player_id: usize = 0;
    var winner_id: usize = 0;
    for (0..1e6) |_| {
        try view.turn(game);

        if (game.boards[0].allSunk()) {
            try game.players[0].writeMessage(.{ .lose = {} });
            try game.players[1].writeMessage(.{ .win = {} });
            winner_id = 1;
            break;
        } else if (game.boards[1].allSunk()) {
            try game.players[0].writeMessage(.{ .win = {} });
            try game.players[1].writeMessage(.{ .lose = {} });
            winner_id = 0;
            break;
        }

        try self.playGameTurn(gpa, game, view, player_id);

        player_id = (player_id + 1) % 2;
        _ = arena_alloc.reset(.retain_capacity);
        self.time.sleep(10 * std.time.ns_per_ms);
    } else {
        return error.InfiniteLoop;
    }
    const loser_id = (winner_id + 1) % 2;
    game.scores[winner_id].wins += 1;
    game.scores[loser_id].losses += 1;
}

fn placeShips(self: *Self, gpa: std.mem.Allocator, game: *Game) !void {
    var player_id: usize = 0;
    const base_attempt = RequestAttempt{
        .start_ms = self.time.nowMs(),
        .timeout_ms = 1000,
        .max_tries = 3,
    };
    var attempts = [2]RequestAttempt{ base_attempt, base_attempt };
    // Apply any penalties for late answers
    defer for (0..2) |i| {
        const attempt = &attempts[i];
        if (attempt.retries > 0) {
            std.log.info(
                "{s} awarded {d} penalties in placeShips",
                .{ self.entries[i].name, attempt.retries },
            );
        }
        game.scores[i].penalties += attempt.retries;
    };
    var placed = [2]bool{ false, false };
    for (0..1e6) |_| {
        std.log.debug("Waiting for ships to be placed", .{});
        if (placed[0] and placed[1]) break;
        player_id = (player_id + 1) % 2;
        if (placed[player_id]) continue;
        defer self.time.sleep(10 * std.time.ns_per_ms);

        const attempt = &attempts[player_id];
        const now = self.time.nowMs();
        if (attempt.timedout(now)) {
            // TODO: player losses
            endGameEarly(game, &placed);
            return error.PlayerError;
        }

        const player = game.players[player_id];
        const maybe_message = try player.pollMessage(gpa);
        std.log.debug("message: {any}", .{maybe_message});

        const message = maybe_message orelse continue;
        if (message != .place_ships_response) {
            const entry = game.entries[player_id];
            std.log.info("{s}: !Unexpected message: {f}", .{ entry.name, message });
            continue;
        }
        const placements = message.place_ships_response;
        game.placeShips(player_id, placements) catch |err| {
            std.log.err("Place ships response: {}", .{err});
            switch (err) {
                error.InvalidPlacement => try player.writeMessage(.{ .place_ships_request = {} }),
                else => return err,
            }
        };
        placed[player_id] = true;
    } else return error.InfiniteLoop;
}

/// Called when one or more player fails to cooperate. Placed[i] is
/// true if player i successfully placed ships before this function was called
pub fn endGameEarly(game: *Game, placed: *const [2]bool) void {
    if (placed[0] and !placed[1]) {
        game.scores[0].wins += 1;
        game.scores[1].losses += 1;
        return;
    }
    if (placed[1] and !placed[0]) {
        game.scores[1].wins += 1;
        game.scores[0].losses += 1;
        return;
    }
    game.scores[0].losses += 1;
    game.scores[1].losses += 1;
}

pub fn playGameTurn(
    self: *Self,
    gpa: std.mem.Allocator,
    game: *Game,
    view: View.Interface,
    player_id: usize,
) !void {
    const entry = game.entries[player_id];
    const player = game.players[player_id];
    try player.writeMessage(.{ .turn_request = {} });
    var attempt = RequestAttempt{
        .start_ms = self.time.nowMs(),
        .timeout_ms = 1000,
        .max_tries = 3,
    };
    defer {
        if (attempt.retries > 0) {
            std.log.info(
                "{s} awarded {d} penalties in playGameTurn",
                .{ self.entries[player_id].name, attempt.retries },
            );
        }
        game.scores[player_id].penalties += attempt.retries;
    }

    for (0..1e9) |_| {
        const now = self.time.nowMs();
        if (attempt.timedout(now)) {
            std.log.info("{s} took too long to respond, skipping their turn", .{entry.name});
            return;
        }
        defer self.time.sleep(10 * std.time.ns_per_ms);
        const message = try player.pollMessage(gpa) orelse continue;
        if (message != .turn_response) {
            std.log.info("{s}: Unexpected message: {f}", .{ entry.name, message });
            continue;
        }
        const turn = message.turn_response;
        const shot = try game.takeTurn(player_id, turn.x, turn.y);
        try view.fire(
            player_id,
            .{ .x = @intCast(turn.x), .y = @intCast(turn.y) },
            shot,
        );
        break;
    } else {
        return error.InfiniteLoop;
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

test "game ships sorted" {
    var copy = game_ships;
    sortShips(&copy);
    for (0..game_ships.len) |i| {
        try std.testing.expectEqual(game_ships[i].size, copy[i].size);
    }
}

const ChildWithIo = struct {
    child: std.process.Child,
    stdout: std.fs.File,
    stdin: std.fs.File,

    fn kill(self: *ChildWithIo, entry: *const Meta.Entry) void {
        _ = self.child.kill() catch |err| {
            std.log.err("Failed to kill {s}: {}", .{ entry.name, err });
        };
    }
};

pub fn spawnEntry(gpa: std.mem.Allocator, entry: *const Meta.Entry) !ChildWithIo {
    // If we don't make sure the file exists like this the child process will
    // might silently
    const file = std.fs.openFileAbsolute(entry.runnable, .{}) catch |err| {
        std.log.err("could not open '{s}'", .{entry.runnable});
        return err;
    };
    file.close();

    var child = std.process.Child.init(&.{entry.runnable}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const stdout = child.stdout orelse return error.NoOutput;
    const stdin = child.stdin orelse return error.NoInput;

    try setNonBlocking(stdout.handle);
    try setNonBlocking(stdin.handle);
    return .{ .child = child, .stdout = stdout, .stdin = stdin };
}

const ThreadWithIo = struct {
    thread: std.Thread,
    stdin: std.fs.File,
    stdout: std.fs.File,
};

pub fn spawnFn(function: TestPlayer.Fn) !ThreadWithIo {
    const stdout = try std.posix.pipe();
    const stdin = try std.posix.pipe();

    try setNonBlocking(stdin[0]);
    try setNonBlocking(stdin[1]);
    try setNonBlocking(stdout[0]);
    try setNonBlocking(stdout[1]);

    const Context = struct {
        function: TestPlayer.Fn,
        stdout: std.fs.File,
        stdin: std.fs.File,

        fn init(func: TestPlayer.Fn, stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t) @This() {
            return .{
                .function = func,
                .stdin = std.fs.File{ .handle = stdin_fd },
                .stdout = std.fs.File{ .handle = stdout_fd },
            };
        }

        fn go(ctx: @This()) !void {
            defer ctx.stdin.close();
            defer ctx.stdout.close();

            var stdin_buffer: [256]u8 = undefined;
            var stdin_reader = ctx.stdin.reader(&stdin_buffer);
            var stdout_buffer: [256]u8 = undefined;
            var stdout_writer = ctx.stdout.writer(&stdout_buffer);
            try ctx.function(&stdin_reader.interface, &stdout_writer.interface);
        }
    };
    const ctx = Context.init(function, stdin[0], stdout[1]);
    const thread = try std.Thread.spawn(.{}, Context.go, .{ctx});
    return .{
        .thread = thread,
        .stdin = std.fs.File{ .handle = stdin[1] },
        .stdout = std.fs.File{ .handle = stdout[0] },
    };
}

fn setNonBlocking(handle: std.fs.File.Handle) !void {
    var flags = try std.posix.fcntl(handle, std.posix.F.GETFL, 0);
    flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    // TODO: don't ignore
    _ = try std.posix.fcntl(handle, std.posix.F.SETFL, flags);
}

pub const game_width = 11;
pub const game_height = 9;
pub const BattleshipBoard = Battleship.Board(game_width, game_height, &game_ships);
pub const Game = struct {
    entries: [2]*const Meta.Entry,
    players: [2]Bridge.Interface,
    boards: [2]BattleshipBoard = undefined,
    scores: [2]Score = [2]Score{ .{}, .{} },

    player0_id: usize,
    player1_id: usize,
    current_game: u32 = 1,
    total_games: u32,
    current_round: u32,
    total_rounds: u32,

    pub fn init(
        player0_id: usize,
        player1_id: usize,
        process0: Bridge.Interface,
        process1: Bridge.Interface,
        entry0: *const Meta.Entry,
        entry1: *const Meta.Entry,
        total_games: u32,
        current_round: u32,
        total_rounds: u32,
    ) Game {
        return .{
            .entries = [2]*const Meta.Entry{ entry0, entry1 },
            .players = [2]Bridge.Interface{ process0, process1 },
            .player0_id = player0_id,
            .player1_id = player1_id,
            .total_games = total_games,
            .current_round = current_round,
            .total_rounds = total_rounds,
        };
    }

    pub fn deinit(self: *Game) void {
        _ = self;
    }

    fn startRound(self: *Game) !void {
        for (&self.players) |player| {
            try player.writeMessage(.{ .round_start = {} });
        }
    }

    pub fn placeShips(
        self: *Game,
        player_id: usize,
        placements: []Battleship.Placement,
    ) !void {
        const board = &self.boards[player_id];
        sortPlacements(placements);
        board.* = BattleshipBoard.init(placements) catch {
            return error.InvalidPlacement;
        };
    }

    fn takeTurn(self: *Game, player_id: usize, x: usize, y: usize) !Battleship.Shot {
        const player = self.players[player_id];
        const other = (player_id + 1) % 2;
        const other_board = &self.boards[other];
        const other_player = self.players[other];
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

    fn winner(self: *Game) usize {
        // TODO: ties
        return if (self.scores[0].value() > self.scores[1].value()) 0 else 1;
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

const RequestAttempt = struct {
    start_ms: i64,
    timeout_ms: i64,
    max_tries: i32,
    retries: i32 = 0,

    pub fn timedout(self: *RequestAttempt, now: i64) bool {
        const elapsed = now - self.start_ms;
        const tries: i32 = @intCast(@divTrunc(elapsed, self.timeout_ms));
        if (tries >= self.max_tries) {
            self.retries = self.max_tries;
            return true;
        }
        self.retries = tries;
        return false;
    }
};

test "RequestAttempt" {
    var fake_time = Time.Fake{};
    const time = fake_time.interface();

    var attempt = RequestAttempt{
        .start_ms = time.nowMs(),
        .timeout_ms = 1000,
        .max_tries = 3,
    };
    var now = time.nowMs();
    try std.testing.expect(!attempt.timedout(now));
    try std.testing.expectEqual(0, attempt.retries);

    time.sleep(1000 * std.time.ns_per_ms);
    now = time.nowMs();
    try std.testing.expect(!attempt.timedout(now));
    try std.testing.expectEqual(1, attempt.retries);

    time.sleep(1000 * std.time.ns_per_ms);
    now = time.nowMs();
    try std.testing.expect(!attempt.timedout(now));
    try std.testing.expectEqual(2, attempt.retries);

    time.sleep(1000 * std.time.ns_per_ms);
    now = time.nowMs();
    try std.testing.expect(attempt.timedout(now));
    try std.testing.expectEqual(3, attempt.retries);
}

const TestEnv = struct {
    const entry0 = Meta.Entry.defaultForTest("entry0");
    const entry1 = Meta.Entry.defaultForTest("entry1");
    const entries = [_]Meta.Entry{ entry0, entry1 };
    rng: std.Random.DefaultPrng,
    time: Time.Fake = .{},
    input: std.Io.Reader,
    output: std.Io.Writer.Discarding,

    fn init() TestEnv {
        return .{
            .rng = std.Random.DefaultPrng.init(std.testing.random_seed),
            .input = std.Io.Reader.fixed(&.{}),
            .output = std.Io.Writer.Discarding.init(&.{}),
        };
    }

    fn testGame(
        self: *TestEnv,
        player_events0: []TestPlayer.Event,
        player_events1: []TestPlayer.Event,
    ) !Game {
        var tourney = try Self.init(
            std.testing.allocator,
            self.time.interface(),
            &self.input,
            &self.output.writer,
            self.rng.random(),
            &entries,
            "/base/dir",
        );
        defer tourney.deinit();

        var test_view: View.Unittest = .{};
        const view: View.Interface = .{ .unittest = &test_view };

        var buffer0: [256]u8 = undefined;
        var reader0 = TestPlayer.EventReader.init(
            self.time.interface(),
            player_events0,
            &buffer0,
        );
        var discarding0 = std.Io.Writer.Discarding.init(&.{});
        var bridge0 = Bridge.InMemory.init(&discarding0.writer, &reader0.interface);

        var buffer1: [256]u8 = undefined;
        var reader1 = TestPlayer.EventReader.init(
            self.time.interface(),
            player_events1,
            &buffer1,
        );
        var discarding1 = std.Io.Writer.Discarding.init(&.{});
        var bridge1 = Bridge.InMemory.init(&discarding1.writer, &reader1.interface);

        var game = Game.init(
            0,
            1,
            .{ .in_memory = &bridge0 },
            .{ .in_memory = &bridge1 },
            &entry0,
            &entry1,
            1,
            1,
            1,
        );
        defer game.deinit();

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        _ = tourney.playGame(&game, view, &arena) catch |err| switch (err) {
            error.PlayerError => std.log.debug("Test game ended early because of uncooperative player", .{}),
            else => return err,
        };
        return game;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "both players behaved" {
    std.testing.log_level = .err;
    var env = TestEnv.init();
    const gpa = std.testing.allocator;
    var events0 = try TestPlayer.behaved(gpa);
    defer events0.deinit(gpa);

    var game = try env.testGame(events0.items, events0.items);
    defer game.deinit();

    const sunk0 = game.boards[0].allSunk();
    const sunk1 = game.boards[1].allSunk();
    try expect(sunk0 ^ sunk1);
    for (&game.scores) |score| try expectEqual(0, score.penalties);
}

test "one player unresponsive" {
    std.testing.log_level = .err;
    var env = TestEnv.init();
    const gpa = std.testing.allocator;
    var behaved_events = try TestPlayer.behaved(gpa);
    defer behaved_events.deinit(gpa);

    const no_events = &.{};
    var game = try env.testGame(behaved_events.items, no_events);
    defer game.deinit();

    try expectEqual(0, game.scores[0].penalties);
    try expectEqual(3, game.scores[1].penalties);
}

test "one player laggy" {
    std.testing.log_level = .err;
    var env = TestEnv.init();
    const gpa = std.testing.allocator;

    var behaved_events = try TestPlayer.behaved(gpa);
    defer behaved_events.deinit(gpa);

    var laggy_events = try TestPlayer.laggy(gpa);
    defer laggy_events.deinit(gpa);

    var game = try env.testGame(behaved_events.items, laggy_events.items);
    defer game.deinit();

    const sunk0 = game.boards[0].allSunk();
    const sunk1 = game.boards[1].allSunk();
    try expect(sunk0 ^ sunk1);
    try expectEqual(0, game.scores[0].penalties);
    try expectEqual(51, game.scores[1].penalties);
}

test "one player unreliable" {
    //std.testing.log_level = .debug;
    var env = TestEnv.init();
    const gpa = std.testing.allocator;

    var behaved_events = try TestPlayer.behaved(gpa);
    defer behaved_events.deinit(gpa);

    var unreliable_events = try TestPlayer.unreliable(gpa);
    defer unreliable_events.deinit(gpa);

    var game = try env.testGame(unreliable_events.items, behaved_events.items);
    defer game.deinit();

    const sunk0 = game.boards[0].allSunk();
    const sunk1 = game.boards[1].allSunk();
    try expect(sunk0);
    try expect(!sunk1);
    try expectEqual(1, game.winner());
    // TODO: how many penalties should they have?
}

test "one player corrupt" {
    std.testing.log_level = .err;
    var env = TestEnv.init();
    const gpa = std.testing.allocator;

    var behaved_events = try TestPlayer.behaved(gpa);
    defer behaved_events.deinit(gpa);

    var currupt_events = try TestPlayer.corrupt(gpa);
    defer currupt_events.deinit(gpa);

    var game = try env.testGame(behaved_events.items, currupt_events.items);
    defer game.deinit();

    try expectEqual(0, game.winner());
    // TODO: how many penalties should they have?
}

// TODO: one player drops, one player currupted, one player latent currupted, both player variants

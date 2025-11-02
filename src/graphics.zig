const std = @import("std");
const Resource = @import("resource.zig");

const Self = @This();
stdout: *std.Io.Writer,

pub fn init(stdout: *std.Io.Writer) Self {
    return .{ .stdout = stdout };
}

pub const ImageOptions = struct {
    action: enum(u8) {
        transmit = 't',
        transmit_display = 'T',
        transmit_frame = 'f',
        query = 'q',
        put = 'p',
        delete = 'd',
        control_animation = 'a',
        compose_animation = 'c',
    } = .transmit_display,

    format: enum(u8) {
        rgb_24 = 24,
        rgb_32 = 32,
        png = 100,
    } = .png,

    source_rect: ?struct { x: u32, y: u32, w: u32, h: u32 } = null,
    rows: ?u16 = null,
    cols: ?u16 = null,
    image_id: ?u32 = null,
    placement_id: ?u32 = null,
    zindex: ?u32 = null,
    quiet: enum(u8) { no = 0, kinda = 1, yes = 2 } = .yes,
};

fn imageHeader(self: *Self, opts: ImageOptions) !void {
    try self.stdout.print("\x1b_G", .{});
    try self.stdout.print(
        "a={c},f={d}",
        .{ @intFromEnum(opts.action), @intFromEnum(opts.format) },
    );
    if (opts.rows) |rows| try self.stdout.print(",r={d}", .{rows});
    if (opts.cols) |cols| try self.stdout.print(",c={d}", .{cols});
    if (opts.source_rect) |rect|
        try self.stdout.print(
            ",x={d},y={d},w={d},h={d}",
            .{ rect.x, rect.y, rect.w, rect.h },
        );
    if (opts.image_id) |id| try self.stdout.print(",i={d}", .{id});
    if (opts.placement_id) |id| try self.stdout.print(",p={d}", .{id});
    if (opts.quiet != .no)
        try self.stdout.print(",q={d}", .{@intFromEnum(opts.quiet)});

    if (opts.zindex) |zindex| {
        try self.stdout.print(",z={d}", .{zindex});
    }
    try self.stdout.print(";", .{});
}

pub fn imageBytes(self: *Self, bytes: []u8, opts: ImageOptions) !void {
    try self.imageHeader(opts);
    try std.base64.standard.Encoder.encodeWriter(self.stdout, bytes);
    try self.stdout.print("\x1b\\\n", .{});
}

pub fn imagePos(self: *Self, col: u16, row: u16, opts: ImageOptions) !void {
    try self.setCursor(.{ .row = row, .col = col });
    try self.imageHeader(opts);
    try self.stdout.print("\x1b\\\n", .{});
}

pub fn image(self: *Self, opts: ImageOptions) !void {
    try self.imageHeader(opts);
    try self.stdout.print("\x1b\\\n", .{});
}

pub fn drawRes(self: *Self, row: u16, col: u16, res: *Resource) !void {
    try self.imagePos(
        row,
        col,
        .{
            .action = .put,
            .image_id = res.image_file.id(),
            .rows = res.rows,
            .cols = res.cols,
            .source_rect = .{
                .x = res.frames[0].x,
                .y = res.frames[0].y,
                .w = res.frames[0].w,
                .h = res.frames[0].h,
            },
        },
    );
}

const Cursor = struct { row: u16, col: u16 };

pub fn setCursor(self: *Self, cursor: Cursor) !void {
    try self.stdout.print("\x1b[{};{}H", .{ cursor.row, cursor.col });
}

pub fn eraseBelowCursor(self: *Self) !void {
    try self.stdout.print("\x1b[J", .{});
}

pub fn hideCursor(self: *Self) !void {
    try self.stdout.print("\x1b[?25l", .{});
}

pub fn showCursor(self: *Self) !void {
    try self.stdout.print("\x1b[?25h", .{});
}

pub fn measureScreen() !std.posix.winsize {
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = std.posix.system.ioctl(0, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(result) != .SUCCESS) {
        return error.MeasureScreen;
    }
    return winsize;
}

const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    runnable: []const u8,
    img: []const u8,
    emote: []const u8,
};

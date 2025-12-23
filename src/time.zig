const std = @import("std");

const Self = @This();
ctx: *anyopaque,
vtable: VTable,

const VTable = struct {
    nowMs: *const fn (*anyopaque) i64,
    sleep: *const fn (*anyopaque, u64) void,
};

pub fn nowMs(self: Self) i64 {
    return self.vtable.nowMs(self.ctx);
}

pub fn sleep(self: Self, delta: u64) void {
    self.vtable.sleep(self.ctx, delta);
}

pub const Real = struct {
    pub fn nowMs(ctx: *anyopaque) i64 {
        const self: *Real = @ptrCast(@alignCast(ctx));
        _ = self;
        return std.time.milliTimestamp();
    }

    pub fn sleep(ctx: *anyopaque, delta: u64) void {
        const self: *Real = @ptrCast(@alignCast(ctx));
        _ = self;
        std.Thread.sleep(delta);
    }

    pub fn interface(self: *Real) Self {
        return .{
            .ctx = self,
            .vtable = .{
                .nowMs = Real.nowMs,
                .sleep = Real.sleep,
            },
        };
    }
};

pub const Fake = struct {
    t: u64 = 0,

    pub fn nowMs(ctx: *anyopaque) i64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return @as(i64, @intCast(@divFloor(self.t, std.time.ns_per_ms)));
    }

    pub fn sleep(ctx: *anyopaque, delta: u64) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.t += delta;
    }

    pub fn interface(self: *Fake) Self {
        return .{
            .ctx = self,
            .vtable = .{
                .nowMs = Fake.nowMs,
                .sleep = Fake.sleep,
            },
        };
    }
};

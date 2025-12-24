const std = @import("std");

const Protocol = @import("protocol.zig");

pub const Interface = union(enum) {
    file: *File,
    in_memory: *InMemory,

    pub fn writeMessage(self: Interface, message: Protocol.Message) !void {
        switch (self) {
            inline else => |variant| try variant.writeMessage(message),
        }
    }

    pub fn pollMessage(self: Interface, gpa: std.mem.Allocator) !?Protocol.Message {
        return switch (self) {
            inline else => |variant| try variant.pollMessage(gpa),
        };
    }
};

pub const File = struct {
    // Need to hold on to the File.Writer so I can inspect writer.err
    // to differentiate a real ReadFailed and a WouldBlock
    stdin: std.fs.File.Writer,
    stdout: std.fs.File.Reader,

    pub fn init(
        stdin: std.fs.File,
        stdout: std.fs.File,
        stdin_buf: []u8,
        stdout_buf: []u8,
    ) File {
        return .{
            .stdin = stdin.writer(stdin_buf),
            .stdout = stdout.reader(stdout_buf),
        };
    }

    pub fn writeMessage(self: *File, message: Protocol.Message) !void {
        self.writeMessageImpl(message) catch |err| {
            if (err != error.WriteFailed) return err;
            const actual_err = self.stdin.err orelse return error.UnknownRead;
            switch (actual_err) {
                error.WouldBlock => return error.Undelivered,
                error.BrokenPipe => {
                    // Don't return an error here because this could be intentionally.
                    // Player could have written the rest of their output and exited.
                    // If there is a problem we will know when trying to read a response
                    // that won't ever come.
                    std.log.warn("Message {f} not delivered b/c process likely died", .{message});
                    return;
                },
                else => return actual_err,
            }
        };
    }

    fn writeMessageImpl(self: *File, message: Protocol.Message) !void {
        const stdin = &self.stdin.interface;
        try stdin.print("{f}\n", .{message});
        try stdin.flush();
    }

    pub fn pollMessage(self: *File, gpa: std.mem.Allocator) !?Protocol.Message {
        const stdout = &self.stdout.interface;
        const message = Protocol.Message.parse(stdout, gpa) catch |err| {
            if (err != error.ReadFailed) return err;

            const actual_err = self.stdout.err orelse return error.UnknownWrite;
            std.log.err("actual_err: {any}", .{actual_err});
            switch (actual_err) {
                error.WouldBlock => return null,
                else => return err,
            }
        };
        return message;
    }
};

pub const InMemory = struct {
    stdin: *std.Io.Writer,
    stdout: *std.Io.Reader,

    pub fn init(stdin: *std.Io.Writer, stdout: *std.Io.Reader) InMemory {
        return .{
            .stdin = stdin,
            .stdout = stdout,
        };
    }

    pub fn writeMessage(self: *InMemory, message: Protocol.Message) !void {
        try self.stdin.print("{f}\n", .{message});
        try self.stdin.flush();
    }

    pub fn pollMessage(self: *InMemory, gpa: std.mem.Allocator) !?Protocol.Message {
        const message = Protocol.Message.parse(self.stdout, gpa) catch |err| switch (err) {
            // For this implementation only, assume ReadFailed is equivalent
            // to WouldBlock in the File implementation
            error.ReadFailed => return null,
            else => return err,
        };
        return message;
    }
};

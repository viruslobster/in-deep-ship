const std = @import("std");
const Self = @This();
columns: []const *Column,

pub fn init(columns: []const *Column) Self {
    return .{ .columns = columns };
}

pub fn format(self: *const Self, sink: *std.Io.Writer) !void {
    var max_rows: usize = 0;
    for (self.columns) |column| max_rows = @max(max_rows, column.rows.items.len);

    for (0..max_rows) |row_idx| {
        for (self.columns) |column| {
            var wrote: usize = 0;
            if (row_idx < column.rows.items.len) {
                const row = column.rows.items[row_idx];
                try sink.writeAll(row.items);
                wrote = std.unicode.utf8CountCodepoints(row.items) catch row.items.len;
                std.log.info("wrote({d}): {s}", .{ wrote, row.items });
            }
            // Pad everything to max_row_len for constant column width
            const remaining = column.max_row_len - wrote;
            std.log.info("remaining: {d}", .{remaining});
            if (remaining > 0)
                try sink.splatByteAll(' ', remaining);
        }
        try sink.writeByte('\n');
    }
}

pub const Column = struct {
    rows: std.ArrayList(std.ArrayList(u8)),
    interface: std.Io.Writer,
    cols_hint: u32,
    gpa: std.mem.Allocator,
    err: ?Error = null,
    max_row_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, rows_hint: u32, cols_hint: u32) !Column {
        var rows = try std.ArrayList(std.ArrayList(u8)).initCapacity(gpa, rows_hint);
        const row = try std.ArrayList(u8).initCapacity(gpa, cols_hint);
        try rows.append(gpa, row);
        return .{
            .rows = rows,
            .gpa = gpa,
            .cols_hint = cols_hint,
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = &.{},
            },
        };
    }

    fn writeByte(self: *Column, byte: u8) std.Io.Writer.Error!void {
        switch (byte) {
            '\n' => {
                const row = std.ArrayList(u8).initCapacity(self.gpa, self.cols_hint) catch {
                    self.err = Error.OutOfMemory;
                    return std.Io.Writer.Error.WriteFailed;
                };
                self.rows.append(self.gpa, row) catch {
                    self.err = Error.OutOfMemory;
                    return std.Io.Writer.Error.WriteFailed;
                };
            },
            else => {
                const last_idx = self.rows.items.len - 1;
                const row = &self.rows.items[last_idx];
                row.append(self.gpa, byte) catch {
                    self.err = Error.OutOfMemory;
                    return std.Io.Writer.Error.WriteFailed;
                };
                // This will fail if the bytes aren't valid utf8. Could happen
                // between writes
                const maybe_row_len = std.unicode.utf8CountCodepoints(row.items) catch null;
                if (maybe_row_len) |row_len| {
                    self.max_row_len = @max(self.max_row_len, row_len);
                }
            },
        }
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *Column = @alignCast(@fieldParentPtr("interface", writer));
        const buffered = writer.buffered();
        if (buffered.len > 0) {
            for (buffered) |byte| try self.writeByte(byte);
            return writer.consume(buffered.len);
        }
        for (data[0 .. data.len - 1]) |buf| {
            if (buf.len == 0) continue;
            for (buf) |byte| try self.writeByte(byte);
            return writer.consume(buf.len);
        }
        const pattern = data[data.len - 1];
        if (pattern.len == 0 or splat == 0) return 0;
        for (pattern) |byte| try self.writeByte(byte);
        return writer.consume(pattern.len);
    }

    pub fn format(self: *const Column, sink: *std.Io.Writer) !void {
        for (0..self.rows.items.len) |i| {
            const row = self.rows.items[i];
            try sink.writeAll(row.items);
            if (i < self.rows.items.len - 1) try sink.writeByte('\n');
        }
    }
};

const Error = error{
    OutOfMemory,
};

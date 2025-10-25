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
            }
            // Pad everything to max_row_len for constant column width
            const remaining = column.max_row_len - wrote;
            if (remaining > 0)
                try sink.splatByteAll(' ', remaining);
        }
        try sink.writeByte('\n');
    }
}

/// Returns the x coordinate for the column
pub fn offset(self: *const Self, column_index: usize) usize {
    var result: usize = 0;
    for (0..column_index + 1) |i| {
        if (i >= self.columns.len) break;
        result += self.columns[i].max_row_len;
    }
    return result;
}

pub fn width(self: *const Self) usize {
    return self.offset(self.columns.len - 1);
}

/// Implements std.Io.Writer for Column
pub const ColumnWriter = struct {
    column: *Column,
    interface: std.Io.Writer,

    pub fn init(column: *Column, buffer: []u8) ColumnWriter {
        return .{
            .column = column,
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = buffer,
            },
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *ColumnWriter = @alignCast(@fieldParentPtr("interface", writer));
        const buffered = writer.buffered();
        if (buffered.len > 0) {
            const n = try self.drainBytes(buffered);
            return writer.consume(n);
        }
        for (data[0 .. data.len - 1]) |buf| {
            if (buf.len == 0) continue;
            const n = try self.drainBytes(buffered);
            return writer.consume(n);
        }
        const pattern = data[data.len - 1];
        if (pattern.len == 0 or splat == 0) return 0;
        for (pattern) |byte| {
            if (byte == '\n') {
                try self.column.newRow();
                continue;
            }
            const bytes = .{byte};
            try self.column.writeRowBytes(&bytes);
        }
        return writer.consume(pattern.len);
    }

    inline fn drainBytes(
        self: *ColumnWriter,
        data: []const u8,
    ) std.Io.Writer.Error!usize {
        var n: usize = 0;
        while (data[n] != '\n') n += 1;
        try self.column.writeRowBytes(data[0..n]);
        if (data[n] == '\n') {
            try self.column.newRow();
            n += 1;
        }
        return n;
    }
};

pub const Column = struct {
    rows: std.ArrayList(std.ArrayList(u8)),
    cols_hint: u32,
    gpa: std.mem.Allocator,
    err: ?Error = null,
    row_idx: usize = 0,
    max_row_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, rows_hint: u32, cols_hint: u32) !Column {
        var rows = try std.ArrayList(std.ArrayList(u8)).initCapacity(gpa, rows_hint);
        const row = try std.ArrayList(u8).initCapacity(gpa, cols_hint);
        try rows.append(gpa, row);
        return .{
            .rows = rows,
            .gpa = gpa,
            .cols_hint = cols_hint,
        };
    }

    pub fn reset(self: *Column) void {
        for (self.rows.items) |*row| {
            row.clearRetainingCapacity();
        }
        self.row_idx = 0;
        self.max_row_len = 0;
    }

    pub fn writer(self: *Column, buffer: []u8) ColumnWriter {
        return .init(self, buffer);
    }

    fn newRow(self: *Column) std.Io.Writer.Error!void {
        const row = std.ArrayList(u8).initCapacity(self.gpa, self.cols_hint) catch {
            self.err = Error.OutOfMemory;
            return std.Io.Writer.Error.WriteFailed;
        };
        self.rows.append(self.gpa, row) catch {
            self.err = Error.OutOfMemory;
            return std.Io.Writer.Error.WriteFailed;
        };
        self.row_idx += 1;
    }

    /// Write `bytes` all to the same row. Must not containe a '\n'
    fn writeRowBytes(self: *Column, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        const row = &self.rows.items[self.row_idx];
        row.appendSlice(self.gpa, bytes) catch {
            self.err = Error.OutOfMemory;
            return std.Io.Writer.Error.WriteFailed;
        };
        // This will fail if the bytes aren't valid utf8. Could happen
        // between writes
        const maybe_row_len = std.unicode.utf8CountCodepoints(row.items) catch null;
        if (maybe_row_len) |row_len| {
            self.max_row_len = @max(self.max_row_len, row_len);
        }
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

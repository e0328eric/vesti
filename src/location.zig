const std = @import("std");
const ziglyph = @import("ziglyph");
const dw = ziglyph.display_width;

pub const Location = struct {
    row: usize,
    column: usize,

    pub fn moveRight(self: *@This(), chr: u21) void {
        self.column += @intCast(usize, dw.codePointWidth(chr, .half));
    }

    pub fn newLine(self: *@This()) void {
        self.column = 1;
        self.row += 1;
    }
};

pub const Span = struct {
    start: Location,
    end: Location,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{d}:{d}--{d}:{d}", .{
            self.start.row, self.start.column, self.end.row, self.end.column,
        });
    }
};

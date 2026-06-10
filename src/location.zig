const std = @import("std");
const uucode = @import("uucode");
const unicode = std.unicode;

pub const Location = struct {
    row: usize = 1,
    col: usize = 1,

    pub fn move(self: *@This(), chr: u21) void {
        if (chr == '\n') {
            self.row += 1;
            self.col = 1;
            return;
        }

        self.col += uucode.get(.wcwidth_standalone, chr);
    }
};

pub const Span = struct {
    start: Location = Location{},
    end: Location = Location{},

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{}:{} -- {}:{}", .{
            self.start.row,
            self.start.col,
            self.end.row,
            self.end.col,
        });
    }
};

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

        // codePointWidth can return -1 only if chr is either a backspace or DEL.
        // but these are special character, so in this case, I will ignore it.
        self.col += @intCast(@max(0, uucode.get(.wcwidth_standalone, chr)));
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

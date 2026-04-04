const std = @import("std");
const unicoz = @import("unicoz");
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

        self.col += unicoz.wcwidth(chr);
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

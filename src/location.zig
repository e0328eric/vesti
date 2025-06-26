const std = @import("std");
const unicode = std.unicode;
const DisplayWidth = @import("zg_DisplayWidth");

pub const Location = struct {
    row: usize = 1,
    col: usize = 1,

    pub fn move(self: *@This(), chr: u21, dw: DisplayWidth) void {
        if (chr == '\n') {
            self.row += 1;
            self.col = 1;
            return;
        }

        // codePointWidth can return -1 only if chr is either a backspace or DEL.
        // but these are special character, so in this case, I will ignore it.
        self.col += @intCast(@max(0, dw.codePointWidth(chr)));
    }
};

pub const Span = struct {
    start: Location = Location{},
    end: Location = Location{},

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;

        if (comptime std.mem.eql(u8, fmt, "span")) {
            try writer.print("{}:{} -- {}:{}", .{
                self.start.row,
                self.start.col,
                self.end.row,
                self.end.col,
            });
        } else {
            try writer.print("{any}", .{self});
        }
    }
};

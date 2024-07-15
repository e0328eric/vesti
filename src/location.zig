const std = @import("std");
const unicode = std.unicode;

const DisplayWidth = @import("zg_DisplayWidth");

pub const Location = struct {
    row: usize = 1,
    col: usize = 1,

    pub fn move(self: *@This(), dw: DisplayWidth, chr: u21) void {
        if (chr == '\n') {
            self.row += 1;
            self.col = 1;
            return;
        }

        var buf = [_]u8{0} ** 6;
        const len = unicode.utf8Encode(chr, &buf) catch @panic("character must be a valid UTF8 character");

        self.col += dw.strWidth(buf[0..len]);
    }
};

pub const Span = struct {
    start: Location,
    end: Location,
};

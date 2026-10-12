const std = @import("std");
const fmt = std.fmt;

pub const Color = enum(u8) {
    Black = 30,
    Red = 31,
    Green = 32,
    Yellow = 33,
    Blue = 34,
    Magenta = 35,
    Cyan = 36,
    White = 37,
    BrightBlac = 90,
    BrightRed = 91,
    BrightGreen = 92,
    BrightYellow = 93,
    BrightBlue = 94,
    BrightMagenta = 95,
    BrightCyan = 96,
    BrightWhite = 97,
};

pub const Attribute = enum(u8) {
    Reset = 0,
    Bold = 1,
    Faint = 2,
    Italic = 3,
    Underline = 4,
};

pub fn makeAnsi(comptime color: ?Color, comptime attr: ?Attribute) []const u8 {
    comptime var attr_buf = [_]u8{0} ** 4;
    comptime var color_buf = [_]u8{0} ** 5;

    const attr_str = if (attr) |a| blk: {
        break :blk fmt.bufPrint(
            &attr_buf,
            "\x1b[{d}m",
            .{@intFromEnum(a)},
        ) catch unreachable;
    } else "";
    const color_str = if (color) |c| blk: {
        break :blk fmt.bufPrint(
            &color_buf,
            "\x1b[{d}m",
            .{@intFromEnum(c)},
        ) catch unreachable;
    } else "";

    return attr_str ++ color_str;
}

pub const reset = makeAnsi(null, .Reset);
pub const @"error" = makeAnsi(.Red, .Bold);
pub const warn = makeAnsi(.Magenta, .Bold);
pub const note = makeAnsi(.Cyan, .Bold);

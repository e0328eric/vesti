const std = @import("std");
const err_info = @import("error_info.zig");
const math = std.math;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ErrorInfo = err_info.ErrorInfo;
const SplitIterator = std.mem.SplitIterator;

pub const bold_text = "\x1b[1m";
pub const err_color = "\x1b[38;5;9m";
pub const title_color = "\x1b[38;5;15m";
pub const blue_color = "\x1b[38;5;12m";
pub const note_color = "\x1b[38;5;14m";
pub const reset_color = "\x1b[0m";

var space_container = " " ** 300;
var underline_container = "^" ** 300;

pub fn prettyPrint(
    source: []const u8,
    vesti_error: ErrorInfo,
    filepath: []const u8,
    alloc: Allocator,
) !void {
    var lines = std.mem.split(u8, source, "\n");
    const err_code = vesti_error.errCode();
    const err_str = try vesti_error.errStr(alloc);
    defer err_str.deinit();
    const err_detail_str = try vesti_error.errDetailStr(alloc);
    defer err_detail_str.deinit();

    var output = try ArrayList(u8).initCapacity(alloc, 400);
    var writer = output.writer();
    defer output.deinit();

    try writer.print(
        bold_text ++ err_color ++ " error[E{X:0>4}]{s}: {s}" ++ reset_color ++ "\n",
        .{ err_code, title_color, err_str.items },
    );

    const start_row_num = vesti_error.span.start.row;
    const start_column_num = vesti_error.span.start.column;
    const start_row_num_len = math.log(usize, 10, start_row_num) + 2;

    try writer.print(
        "{s}" ++ bold_text ++ blue_color ++ "--> " ++ reset_color ++ "{s}:{}:{}\n",
        .{
            space_container[0..start_row_num_len],
            filepath,
            start_row_num,
            start_column_num,
        },
    );

    try writer.print(
        bold_text ++ blue_color ++ "{s}|\n {} |   " ++ reset_color,
        .{ space_container[0..(start_row_num_len +| 1)], start_row_num },
    );

    const nth_line = getNthFromIter(&lines, start_row_num);
    if (nth_line) |inner| {
        try writer.print("{s}\n", .{inner});
    }

    const end_column_num = vesti_error.span.end.column;
    const padding_space = end_column_num -| start_column_num + 1;
    _ = padding_space;

    try writer.print(
        bold_text ++ blue_color ++ "{s}|   {s}" ++ err_color ++ "{s}\n\n",
        .{
            space_container[0..(start_row_num_len +| 1)],
            space_container[0..(start_column_num -| 1)],
            underline_container[0..(end_column_num -| start_column_num)],
        },
    );
    try writer.print(
        bold_text ++ note_color ++ " note: " ++ reset_color ++ "{s}",
        .{err_detail_str.items},
    );

    std.debug.print("{s}\n", .{output.items});
}

fn getNthFromIter(iter: *SplitIterator(u8), nth: usize) ?[]const u8 {
    var output: ?[]const u8 = undefined;

    var i = nth;
    while (i > 0) : (i -= 1) {
        output = iter.next();
    }

    return output;
}

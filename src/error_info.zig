const std = @import("std");
const location = @import("location.zig");
const token = @import("token.zig");

const print = std.debug.print;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const ErrorInfo = struct {
    kind: union(enum) {
        eof_found,
        illegal_token_found,
        type_mismatch: struct {
            expected: []const token.Type,
            got: token.Type,
        },
        parse_int_failed,
        parse_float_failed,
        bracket_number_mismatched,
        name_miss: token.Type,
        is_not_opened: struct {
            open: []const token.Type,
            close: token.Type,
        },
        is_not_closed: struct {
            open: token.Type,
            close: token.Type,
        },
        illegal_used: token.Type,
    },
    span: location.Span,

    const Self = @This();

    pub fn errCode(self: *const Self) u16 {
        return switch (self.kind) {
            .eof_found => 0x0E0F,
            .illegal_token_found => 0x0101,
            .type_mismatch => 0x0102,
            .parse_int_failed => 0x0103,
            .parse_float_failed => 0x0104,
            .bracket_number_mismatched => 0x0105,
            .name_miss => 0x0106,
            .is_not_opened => 0x0107,
            .is_not_closed => 0x0108,
            .illegal_used => 0x0109,
        };
    }

    pub fn errStr(self: *const Self, alloc: Allocator) !ArrayList(u8) {
        var output = ArrayList(u8).init(alloc);
        errdefer output.deinit();
        var writer = output.writer();

        switch (self.kind) {
            .eof_found => try writer.print("EOF found unexpectedly", .{}),
            .illegal_token_found => try writer.print("`ILLEGAL` character found", .{}),
            .type_mismatch => try writer.print("Type mismatched", .{}),
            .parse_int_failed => try writer.print("Parsing integer error occurs", .{}),
            .parse_float_failed => try writer.print("Parsing float error occurs", .{}),
            .bracket_number_mismatched => try writer.print("Delimiter pair does not matched", .{}),
            .name_miss => |toktype| try writer.print(
                "Type `{s}` requires its name",
                .{toktype.toString()},
            ),
            .is_not_opened => |info| try writer.print(
                "Type `{s}` is used without the opening part",
                .{info.close.toString()},
            ),
            .is_not_closed => |info| try writer.print(
                "Type `{s}` is not closed",
                .{info.open.toString()},
            ),
            .illegal_used => |toktype| try writer.print(
                "Type `{s}` cannot use out of the math block or the function definition",
                .{toktype.toString()},
            ),
        }

        return output;
    }

    pub fn errDetailStr(self: *const Self, alloc: Allocator) !ArrayList(u8) {
        var output = ArrayList(u8).init(alloc);
        errdefer output.deinit();
        var writer = output.writer();

        switch (self.kind) {
            .eof_found, .illegal_token_found => {},
            .type_mismatch => |info| try writer.print(
                "expected `{any}`, got `{s}`",
                .{ info.expected, info.got.toString() },
            ),
            .parse_int_failed, .parse_float_failed => try writer.print(
                "if this error occurs, this compiler has a bug. So let me know when this message occurs",
                .{},
            ),
            .bracket_number_mismatched => try writer.print(
                "cannot find a bracket that matches with that one. Please close a bracket with an appropriate one",
                .{},
            ),
            .name_miss => |toktype| try writer.print(
                "type `{s}` is used here, but vesti cannot find its part",
                .{toktype.toString()},
            ),
            .is_not_opened => |info| try writer.print(
                "type `{s}` is used, but there is no type `{any}` to be pair with",
                .{ info.close.toString(), info.open },
            ),
            .is_not_closed => |info| try writer.print(
                "cannot find the type `{s}` to close this environment",
                .{info.close.toString()},
            ),
            .illegal_used => try writer.print(
                "wrap the whole expression that uses this token using the math block or the function definition",
                .{},
            ),
        }

        return output;
    }
};

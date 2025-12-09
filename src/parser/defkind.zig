const std = @import("std");

const CowStr = @import("../CowStr.zig").CowStr;
const Writer = std.Io.Writer;

const DefunKindInt = u8;
pub const DefunKind = packed struct(DefunKindInt) {
    redef: bool = false,
    declare: bool = false,
    provide: bool = false,
    expand: bool = false,
    global: bool = false,
    xparse: bool = false,
    trim_left: bool = true,
    trim_right: bool = true,

    const Self = @This();

    const DEFAULT: DefunKindInt = @bitCast(Self{});
    pub const REDEF: DefunKindInt = @as(DefunKindInt, @bitCast(Self{ .redef = true })) & ~DEFAULT;
    pub const DECLARE: DefunKindInt = @as(DefunKindInt, @bitCast(Self{ .declare = true })) & ~DEFAULT;
    pub const PROVIDE: DefunKindInt = @as(DefunKindInt, @bitCast(Self{ .provide = true })) & ~DEFAULT;
    pub const EXPAND: DefunKindInt = @as(DefunKindInt, @bitCast(Self{ .expand = true })) & ~DEFAULT;
    pub const GLOBAL: DefunKindInt = @as(DefunKindInt, @bitCast(Self{ .global = true })) & ~DEFAULT;
    pub const XPARSE: DefunKindInt = @as(DefunKindInt, @bitCast(Self{ .xparse = true })) & ~DEFAULT;

    pub inline fn takeType(self: Self) DefunKindInt {
        return @as(DefunKindInt, @bitCast(self)) & ~DEFAULT;
    }

    pub fn parse(output: *Self, str: []const u8, is_xparse: bool) bool {
        for (str) |s| {
            switch (s) {
                'r', 'R' => output.redef = true,
                'p', 'P' => output.provide = true,
                '!' => output.declare = true,
                'e', 'E' => output.expand = true,
                'g', 'G' => output.global = true,
                '<' => output.trim_left = false,
                '>' => output.trim_right = false,
                else => return false,
            }
        }

        output.xparse = is_xparse;

        return switch (output.takeType()) {
            0,
            REDEF,
            DECLARE,
            REDEF | DECLARE,
            EXPAND,
            EXPAND | REDEF,
            EXPAND | DECLARE,
            EXPAND | REDEF | DECLARE,
            GLOBAL,
            GLOBAL | REDEF,
            GLOBAL | DECLARE,
            GLOBAL | REDEF | DECLARE,
            GLOBAL | EXPAND,
            GLOBAL | EXPAND | REDEF,
            GLOBAL | EXPAND | DECLARE,
            GLOBAL | EXPAND | REDEF | DECLARE,
            XPARSE,
            XPARSE | REDEF,
            XPARSE | PROVIDE,
            XPARSE | DECLARE,
            XPARSE | EXPAND,
            XPARSE | EXPAND | REDEF,
            XPARSE | EXPAND | PROVIDE,
            XPARSE | EXPAND | DECLARE,
            => true,
            else => false,
        };
    }

    pub fn prologue(self: Self, name: CowStr, writer: *Writer) !void {
        const CHECK_REDEF =
            \\\expandafter\ifx\csname {1f}\endcsname\relax
            \\{s}\{1f}
        ;
        const NO_CHECK_REDEF = "{s}\\{f}";
        const XPARSE_DEF = "{s}{{\\{f}}}";

        switch (self.takeType()) {
            0 => try writer.print(CHECK_REDEF, .{
                "\\protected\\def", name,
            }),
            REDEF => try writer.print(NO_CHECK_REDEF, .{
                "\\protected\\def", name,
            }),
            DECLARE => try writer.print(CHECK_REDEF, .{
                "\\def", name,
            }),
            REDEF | DECLARE => try writer.print(NO_CHECK_REDEF, .{
                "\\def", name,
            }),
            EXPAND => try writer.print(CHECK_REDEF, .{
                "\\protected\\edef", name,
            }),
            EXPAND | REDEF => try writer.print(NO_CHECK_REDEF, .{
                "\\protected\\edef", name,
            }),
            EXPAND | DECLARE => try writer.print(CHECK_REDEF, .{
                "\\edef", name,
            }),
            EXPAND | REDEF | DECLARE => try writer.print(NO_CHECK_REDEF, .{
                "\\edef", name,
            }),
            GLOBAL => try writer.print(CHECK_REDEF, .{
                "\\protected\\gdef", name,
            }),
            GLOBAL | REDEF => try writer.print(NO_CHECK_REDEF, .{
                "\\protected\\gdef", name,
            }),
            GLOBAL | DECLARE => try writer.print(CHECK_REDEF, .{
                "\\gdef", name,
            }),
            GLOBAL | REDEF | DECLARE => try writer.print(NO_CHECK_REDEF, .{
                "\\gdef", name,
            }),
            GLOBAL | EXPAND => try writer.print(CHECK_REDEF, .{
                "\\protected\\xdef", name,
            }),
            GLOBAL | EXPAND | REDEF => try writer.print(NO_CHECK_REDEF, .{
                "\\protected\\xdef", name,
            }),
            GLOBAL | EXPAND | DECLARE => try writer.print(CHECK_REDEF, .{
                "\\xdef", name,
            }),
            GLOBAL | EXPAND | REDEF | DECLARE => try writer.print(NO_CHECK_REDEF, .{
                "\\xdef", name,
            }),
            XPARSE => try writer.print(XPARSE_DEF, .{
                "\\NewDocumentCommand", name,
            }),
            XPARSE | REDEF => try writer.print(XPARSE_DEF, .{
                "\\RenewDocumentCommand", name,
            }),
            XPARSE | PROVIDE => try writer.print(XPARSE_DEF, .{
                "\\ProvideDocumentCommand", name,
            }),
            XPARSE | DECLARE => try writer.print(XPARSE_DEF, .{
                "\\DeclareDocumentCommand", name,
            }),
            XPARSE | EXPAND => try writer.print(XPARSE_DEF, .{
                "\\NewExpandableDocumentCommand", name,
            }),
            XPARSE | EXPAND | REDEF => try writer.print(XPARSE_DEF, .{
                "\\RenewExpandableDocumentCommand", name,
            }),
            XPARSE | EXPAND | PROVIDE => try writer.print(XPARSE_DEF, .{
                "\\ProvideExpandableDocumentCommand", name,
            }),
            XPARSE | EXPAND | DECLARE => try writer.print(XPARSE_DEF, .{
                "\\DeclareExpandableDocumentCommand", name,
            }),
            // assume every DefunKind comes from parseDefunKind
            else => unreachable,
        }
    }

    pub fn param(self: Self, param_str: ?CowStr, writer: *Writer) !void {
        if (self.takeType() & XPARSE == 0) {
            if (param_str) |str| {
                try writer.print("{f}{{", .{str});
            } else {
                try writer.writeByte('{');
            }
        } else {
            if (param_str) |str| {
                try writer.print("{{{f}}}{{", .{str});
            } else {
                try writer.writeAll("{}{");
            }
        }
    }

    pub fn epilogue(self: Self, name: CowStr, writer: *Writer) !void {
        if (self.takeType() & REDEF == 0 and self.takeType() & XPARSE == 0) {
            try writer.print(
                "}}%\n\\else\\errmessage{{{f} is already defined}}\\fi\n",
                .{name},
            );
        } else {
            try writer.writeAll("}%\n");
        }
    }
};

const DefenvKindInt = u7;
pub const DefenvKind = packed struct(DefenvKindInt) {
    redef: bool = false,
    provide: bool = false,
    declare: bool = false,
    begin_trim_left: bool = true,
    begin_trim_right: bool = true,
    end_trim_left: bool = true,
    end_trim_right: bool = true,

    const Self = @This();

    const DEFAULT: DefenvKindInt = @bitCast(Self{});
    pub const REDEF: DefenvKindInt = @as(DefenvKindInt, @bitCast(Self{ .redef = true })) & ~DEFAULT;
    pub const PROVIDE: DefenvKindInt = @as(DefenvKindInt, @bitCast(Self{ .provide = true })) & ~DEFAULT;
    pub const DECLARE: DefenvKindInt = @as(DefenvKindInt, @bitCast(Self{ .declare = true })) & ~DEFAULT;

    pub inline fn takeType(self: Self) DefenvKindInt {
        return @as(DefenvKindInt, @bitCast(self)) & ~DEFAULT;
    }

    pub fn parse(output: *Self, str: []const u8, _: void) bool {
        for (str) |s| {
            switch (s) {
                'r', 'R' => output.redef = true,
                'p', 'P' => output.provide = true,
                '!' => output.declare = true,
                '<' => output.begin_trim_left = false,
                '>' => output.begin_trim_right = false,
                '(' => output.end_trim_left = false,
                ')' => output.end_trim_right = false,
                else => return false,
            }
        }

        return switch (output.takeType()) {
            0, REDEF, PROVIDE, DECLARE => true,
            else => false,
        };
    }

    pub fn prologue(self: Self, name: CowStr, writer: *Writer) !void {
        const XPARSE_DEF = "{s}{{{f}}}";

        switch (self.takeType()) {
            0 => try writer.print(XPARSE_DEF, .{
                "\\NewDocumentEnvironment", name,
            }),
            REDEF => try writer.print(XPARSE_DEF, .{
                "\\RenewDocumentEnvironment", name,
            }),
            PROVIDE => try writer.print(XPARSE_DEF, .{
                "\\ProvideDocumentEnvironment", name,
            }),
            DECLARE => try writer.print(XPARSE_DEF, .{
                "\\DeclareDocumentEnvironment", name,
            }),
            else => unreachable, // assume every DefunKind comes from parseDefunKind
        }
    }
};

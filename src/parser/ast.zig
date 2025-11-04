const std = @import("std");
const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const CowStr = @import("../CowStr.zig").CowStr;
const Span = @import("../location.zig").Span;
const Writer = std.Io.Writer;

pub const UsePackage = struct {
    name: CowStr,
    options: ?ArrayList(CowStr),

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.name.deinit(allocator);
        if (self.options) |*options| {
            for (options.items) |*option| {
                option.deinit(allocator);
            }
            options.deinit(allocator);
        }
    }
};

pub const TrimWhitespace = struct {
    start: bool = true,
    mid: ?bool = null,
    end: bool = true,
};

pub const MathState = enum(u2) {
    Inline,
    Display,
    Labeled,
};

pub const DelimiterKind = enum(u2) {
    None,
    LeftBig,
    RightBig,
};

pub const ArgNeed = enum(u2) {
    MainArg,
    Optional,
    StarArg,
};

const DefunKindInt = u8;
pub const DefunKind = packed struct(DefunKindInt) {
    redef: bool = false,
    raw: bool = false,
    provide: bool = false,
    expand: bool = false,
    global: bool = false,
    xparse: bool = false,
    trim_left: bool = true,
    trim_right: bool = true,

    const Self = @This();

    const DEFAULT: DefunKindInt = @bitCast(Self{});
    pub const REDEF: DefunKindInt = @as(DefunKindInt, @bitCast(Self{ .redef = true })) & ~DEFAULT;
    pub const RAW: DefunKindInt = @as(DefunKindInt, @bitCast(Self{ .raw = true })) & ~DEFAULT;
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
                '!' => output.raw = true,
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
            RAW,
            REDEF | RAW,
            EXPAND,
            EXPAND | REDEF,
            EXPAND | RAW,
            EXPAND | REDEF | RAW,
            GLOBAL,
            GLOBAL | REDEF,
            GLOBAL | RAW,
            GLOBAL | REDEF | RAW,
            GLOBAL | EXPAND,
            GLOBAL | EXPAND | REDEF,
            GLOBAL | EXPAND | RAW,
            GLOBAL | EXPAND | REDEF | RAW,
            XPARSE,
            XPARSE | REDEF,
            XPARSE | PROVIDE,
            XPARSE | RAW, // declare
            XPARSE | EXPAND,
            XPARSE | EXPAND | REDEF,
            XPARSE | EXPAND | PROVIDE,
            XPARSE | EXPAND | RAW, // declare
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
            RAW => try writer.print(CHECK_REDEF, .{
                "\\def", name,
            }),
            REDEF | RAW => try writer.print(NO_CHECK_REDEF, .{
                "\\def", name,
            }),
            EXPAND => try writer.print(CHECK_REDEF, .{
                "\\protected\\edef", name,
            }),
            EXPAND | REDEF => try writer.print(NO_CHECK_REDEF, .{
                "\\protected\\edef", name,
            }),
            EXPAND | RAW => try writer.print(CHECK_REDEF, .{
                "\\edef", name,
            }),
            EXPAND | REDEF | RAW => try writer.print(NO_CHECK_REDEF, .{
                "\\edef", name,
            }),
            GLOBAL => try writer.print(CHECK_REDEF, .{
                "\\protected\\gdef", name,
            }),
            GLOBAL | REDEF => try writer.print(NO_CHECK_REDEF, .{
                "\\protected\\gdef", name,
            }),
            GLOBAL | RAW => try writer.print(CHECK_REDEF, .{
                "\\gdef", name,
            }),
            GLOBAL | REDEF | RAW => try writer.print(NO_CHECK_REDEF, .{
                "\\gdef", name,
            }),
            GLOBAL | EXPAND => try writer.print(CHECK_REDEF, .{
                "\\protected\\xdef", name,
            }),
            GLOBAL | EXPAND | REDEF => try writer.print(NO_CHECK_REDEF, .{
                "\\protected\\xdef", name,
            }),
            GLOBAL | EXPAND | RAW => try writer.print(CHECK_REDEF, .{
                "\\xdef", name,
            }),
            GLOBAL | EXPAND | REDEF | RAW => try writer.print(NO_CHECK_REDEF, .{
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
            XPARSE | RAW => try writer.print(XPARSE_DEF, .{
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
            XPARSE | EXPAND | RAW => try writer.print(XPARSE_DEF, .{
                "\\DeclareExpandableDocumentCommand", name,
            }),
            else => unreachable, // assume every DefunKind comes from parseDefunKind
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

pub const Arg = struct {
    needed: ArgNeed,
    ctx: ArrayList(Stmt),

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        for (self.ctx.items) |*c| c.deinit(allocator);
        self.ctx.deinit(allocator);
    }
};

pub const Stmt = union(enum(u8)) {
    NopStmt = 0,
    Placeholder,
    TextLit: CowStr,
    MathLit: []const u8,
    MathCtx: struct {
        state: MathState,
        inner: ArrayList(Stmt),
        label: ?ArrayList(u8) = null,
    },
    Braced: struct {
        unwrap_brace: bool = false,
        inner: ArrayList(Stmt),
    },
    Fraction: struct {
        numerator: ArrayList(Stmt),
        denominator: ArrayList(Stmt),
    },
    DocumentStart,
    DocumentEnd,
    DocumentClass: struct {
        name: CowStr,
        options: ?ArrayList(CowStr),
    },
    ImportSinglePkg: UsePackage,
    ImportMultiplePkgs: ArrayList(UsePackage),
    ImportVesti: ArrayList(u8),
    PlainTextInMath: struct {
        add_front_space: bool,
        add_back_space: bool,
        inner: ArrayList(Stmt),
    },
    MathDelimiter: struct {
        delimiter: []const u8,
        kind: DelimiterKind,
    },
    DefunParamList: struct {
        nested: usize, // 0: #, 1: ##, 2: ####, etc.
        arg_num: usize, // must be from 1 to 9
        span: Span,
    },
    DefineFunction: struct {
        name: CowStr,
        param_str: ?CowStr = null,
        kind: DefunKind,
        inner: ArrayList(Stmt),
    },
    DefineEnv: struct {
        name: CowStr,
        param_str: ?CowStr = null,
        kind: DefenvKind,
        inner_begin: ArrayList(Stmt),
        inner_end: ArrayList(Stmt),
    },
    Environment: struct {
        name: CowStr,
        args: ArrayList(Arg),
        inner: ArrayList(Stmt),
        label: ?ArrayList(u8) = null,
    },
    // `picture` environment generated from #picture builtin
    // reference: https://lab.uklee.pe.kr/tex-archive/info/latex2e-help-texinfo/latex2e.html#picture
    PictureEnvironment: struct {
        width: usize,
        height: usize,
        xoffset: ?usize,
        yoffset: ?usize,
        // its default value is backed in `Codegen.zig`.
        unit_length: ?ArrayList(u8) = null,
        inner: ArrayList(Stmt),
    },
    BeginPhantomEnviron: struct {
        name: CowStr,
        args: ArrayList(Arg),
        add_newline: bool,
    },
    EndPhantomEnviron: CowStr,
    FilePath: CowStr,
    LuaCode: struct {
        code_span: Span,
        is_global: bool,
        code_import: ?ArrayList([]const u8),
        code_export: ?[]const u8,
        code: ArrayList(u8),
    },

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        switch (self.*) {
            .TextLit => |*inner| inner.deinit(allocator),
            .DocumentClass => |*inner| {
                inner.name.deinit(allocator);
                if (inner.options) |*options| {
                    for (options.items) |*option| option.deinit(allocator);
                    options.deinit(allocator);
                }
            },
            .ImportSinglePkg => |*pkg| pkg.deinit(allocator),
            .ImportMultiplePkgs => |*pkgs| {
                for (pkgs.items) |*pkg| pkg.deinit(allocator);
                pkgs.deinit(allocator);
            },
            .ImportVesti => |*str| str.deinit(allocator),
            .PlainTextInMath => |*inner| {
                for (inner.inner.items) |*stmt| stmt.deinit(allocator);
                inner.inner.deinit(allocator);
            },
            .EndPhantomEnviron => |*name| name.deinit(allocator),
            .MathCtx => |*math_ctx| {
                if (math_ctx.label) |*label| label.deinit(allocator);
                for (math_ctx.inner.items) |*stmt| stmt.deinit(allocator);
                math_ctx.inner.deinit(allocator);
            },
            .Braced => |*bs| {
                for (bs.inner.items) |*stmt| stmt.deinit(allocator);
                bs.inner.deinit(allocator);
            },
            .Fraction => |*ctx| {
                for (ctx.numerator.items) |*c| c.deinit(allocator);
                for (ctx.denominator.items) |*c| c.deinit(allocator);
                ctx.numerator.deinit(allocator);
                ctx.denominator.deinit(allocator);
            },
            .Environment => |*ctx| {
                ctx.name.deinit(allocator);
                for (ctx.args.items) |*arg| arg.deinit(allocator);
                for (ctx.inner.items) |*expr| expr.deinit(allocator);
                ctx.args.deinit(allocator);
                ctx.inner.deinit(allocator);
                if (ctx.label) |*label| label.deinit(allocator);
            },
            .PictureEnvironment => |*ctx| {
                if (ctx.unit_length) |*ul| ul.deinit(allocator);
                for (ctx.inner.items) |*expr| expr.deinit(allocator);
                ctx.inner.deinit(allocator);
            },
            .DefineFunction => |*ctx| {
                ctx.name.deinit(allocator);
                if (ctx.param_str) |*str| str.deinit(allocator);
                for (ctx.inner.items) |*expr| expr.deinit(allocator);
                ctx.inner.deinit(allocator);
            },
            .DefineEnv => |*ctx| {
                ctx.name.deinit(allocator);
                if (ctx.param_str) |*str| str.deinit(allocator);
                for (ctx.inner_begin.items) |*expr| expr.deinit(allocator);
                ctx.inner_begin.deinit(allocator);
                for (ctx.inner_end.items) |*expr| expr.deinit(allocator);
                ctx.inner_end.deinit(allocator);
            },
            .BeginPhantomEnviron => |*ctx| {
                ctx.name.deinit(allocator);
                for (ctx.args.items) |*arg| arg.deinit(allocator);
                ctx.args.deinit(allocator);
            },
            .FilePath => |*ctx| ctx.deinit(allocator),
            .LuaCode => |*cb| {
                if (cb.code_import) |*import| import.deinit(allocator);
                cb.code.deinit(allocator);
            },
            else => {},
        }
    }
};

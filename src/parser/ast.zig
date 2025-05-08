const std = @import("std");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Span = @import("../location.zig").Span;
const CowStr = @import("../CowStr.zig").CowStr;

pub const UsePackage = struct {
    name: CowStr,
    options: ?ArrayList(CowStr),

    pub fn deinit(self: @This()) void {
        self.name.deinit();
        if (self.options) |options| {
            for (options.items) |option| {
                option.deinit();
            }
            options.deinit();
        }
    }
};

pub const TrimWhitespace = struct {
    start: bool = true,
    mid: ?bool = null,
    end: bool = true,
};

pub const MathState = enum(u1) {
    Inline,
    Display,
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

pub const Arg = struct {
    needed: ArgNeed,
    ctx: ArrayList(Stmt),

    pub fn deinit(self: @This()) void {
        for (self.ctx.items) |c| c.deinit();
        self.ctx.deinit();
    }
};

pub const Stmt = union(enum(u8)) {
    NopStmt = 0,
    NonStopMode,
    MakeAtLetter,
    MakeAtOther,
    Latex3On,
    Latex3Off,
    ImportExpl3Pkg,
    Int: i128, // TODO: deprecated
    Float: f128, // TODO: deprecated
    TextLit: []const u8,
    MathLit: []const u8,
    MathCtx: struct {
        state: MathState,
        ctx: ArrayList(Stmt),
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
    Environment: struct {
        name: CowStr,
        args: ArrayList(Arg),
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
        code_import: ?ArrayList([]const u8),
        code_export: ?[]const u8,
        code: []const u8,
    },

    pub fn deinit(self: @This()) void {
        switch (self) {
            .DocumentClass => |inner| {
                inner.name.deinit();
                if (inner.options) |options| {
                    for (options.items) |option| option.deinit();
                    options.deinit();
                }
            },
            .ImportSinglePkg => |pkg| pkg.deinit(),
            .ImportMultiplePkgs => |pkgs| {
                for (pkgs.items) |pkg| pkg.deinit();
                pkgs.deinit();
            },
            .ImportVesti => |str| str.deinit(),
            .PlainTextInMath => |inner| {
                for (inner.inner.items) |stmt| stmt.deinit();
                inner.inner.deinit();
            },
            .EndPhantomEnviron => |name| name.deinit(),
            .MathCtx => |math_ctx| {
                for (math_ctx.ctx.items) |stmt| stmt.deinit();
                math_ctx.ctx.deinit();
            },
            .Braced => |bs| {
                for (bs.inner.items) |stmt| stmt.deinit();
                bs.inner.deinit();
            },
            .Fraction => |ctx| {
                for (ctx.numerator.items) |c| c.deinit();
                for (ctx.denominator.items) |c| c.deinit();
                ctx.numerator.deinit();
                ctx.denominator.deinit();
            },
            .Environment => |ctx| {
                ctx.name.deinit();
                for (ctx.args.items) |arg| arg.deinit();
                for (ctx.inner.items) |expr| expr.deinit();
                ctx.args.deinit();
                ctx.inner.deinit();
            },
            .BeginPhantomEnviron => |ctx| {
                ctx.name.deinit();
                for (ctx.args.items) |arg| arg.deinit();
                ctx.args.deinit();
            },
            .FilePath => |ctx| ctx.deinit(),
            .LuaCode => |cb| if (cb.code_import) |imports| imports.deinit(),
            else => {},
        }
    }
};

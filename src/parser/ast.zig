const std = @import("std");
const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Span = @import("../location.zig").Span;
const CowStr = @import("../CowStr.zig").CowStr;

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

pub const DefunKind = packed struct(u4) {
    redef: bool = false,
    expand: bool = false,
    long: bool = false,
    outer: bool = false,

    pub fn parseDefunKind(output: *@This(), str: []const u8) bool {
        for (str) |s| {
            switch (s) {
                'r', 'R' => output.redef = true,
                'e', 'E' => output.expand = true,
                'l', 'L' => output.long = true,
                'o', 'O' => output.outer = true,
                else => return false,
            }
        }
        return true;
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
    NonStopMode,
    MakeAtLetter,
    MakeAtOther,
    Latex3On,
    Latex3Off,
    ImportExpl3Pkg,
    TextLit: []const u8,
    MathLit: []const u8,
    DefunParamLit: struct {
        span: Span,
        value: CowStr,
    },
    MathCtx: struct {
        state: MathState,
        inner: ArrayList(Stmt),
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
    DefineFunction: struct {
        name: CowStr,
        params: [9]CowStr = @splat(.Empty),
        param_str: ?CowStr = null,
        kind: DefunKind,
        inner: ArrayList(Stmt),
    },
    DefineEnv: struct {
        name: CowStr,
        is_redefine: bool,
        num_args: usize,
        default_arg: ?Arg,
        inner_begin: ArrayList(Stmt),
        inner_end: ArrayList(Stmt),
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
    PyCode: struct {
        code_span: Span,
        code_import: ?ArrayList([]const u8),
        code_export: ?[]const u8,
        is_global: bool,
        code: ArrayList(u8),
    },

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        switch (self.*) {
            .DefunParamLit => |*val| val.value.deinit(allocator),
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
            },
            .DefineFunction => |*ctx| {
                ctx.name.deinit(allocator);
                for (&ctx.params) |*param| param.deinit(allocator);
                if (ctx.param_str) |*str| str.deinit(allocator);
                for (ctx.inner.items) |*expr| expr.deinit(allocator);
                ctx.inner.deinit(allocator);
            },
            .DefineEnv => |*ctx| {
                ctx.name.deinit(allocator);
                if (ctx.default_arg) |*a| a.deinit(allocator);
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
            .PyCode => |*cb| {
                if (cb.code_import) |*import| import.deinit(allocator);
                cb.code.deinit(allocator);
            },
            else => {},
        }
    }
};

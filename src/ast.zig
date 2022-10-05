const std = @import("std");
const token = @import("token.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const GenerateAstError = error{
    AppendToLatexFailed,
    CloneLatexFailed,
};

pub const Latex = struct {
    stmts: ArrayList(Statement),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .stmts = ArrayList(Statement).init(allocator) };
    }

    pub fn deinit(self: Self) void {
        for (self.stmts.items) |*stmt| {
            stmt.deinit();
        }
        self.stmts.deinit();
    }

    pub fn append(self: *Self, stmt: Statement) GenerateAstError!void {
        self.stmts.append(stmt) catch return error.AppendToLatexFailed;
    }

    pub fn len(self: *Self) usize {
        return self.stmts.len;
    }
};

pub const StatementType = enum(u8) {
    document_class,
    use_packages,
    document_start,
    document_end,
    main_text,
    integer,
    float,
    raw_latex,
    math_text,
    latex_function,
    plain_text_in_math,
    environment,
    phantom_begin_environment,
    phantom_end_environment,
    function_define,
    environment_define,
};

pub const Statement = union(StatementType) {
    document_class: Package,
    use_packages: ArrayList(Package),
    document_start: void,
    document_end: void,
    main_text: []const u8,
    integer: i64,
    float: f64,
    raw_latex: []const u8,
    math_text: MathText,
    plain_text_in_math: PlainTextInMath,
    latex_function: LatexFnt,
    environment: Environment,
    phantom_begin_environment: PhantomBeginEnv,
    phantom_end_environment: ArrayList(u8),
    function_define: FunctionDefine,
    environment_define: EnvironmentDefine,

    pub fn deinit(self: @This()) void {
        switch (self) {
            .document_class => |*class| class.deinit(),
            .use_packages => |*pkgs| {
                for (pkgs.items) |*pkg| {
                    pkg.deinit();
                }
                pkgs.deinit();
            },
            .math_text => |*math_text| math_text.deinit(),
            .plain_text_in_math => |*plain_text| plain_text.deinit(),
            .latex_function => |*fnt| fnt.deinit(),
            .environment => |*env| env.deinit(),
            .phantom_begin_environment => |*env| env.deinit(),
            .phantom_end_environment => |*env| env.deinit(),
            .function_define => |*fnt_def| fnt_def.deinit(),
            .environment_define => |*env_def| env_def.deinit(),
            else => {},
        }
    }
};

pub const Package = struct {
    name: ArrayList(u8),
    options: ?ArrayList(Latex),

    pub fn init(alloc: Allocator, comptime has_option: bool) @This() {
        if (has_option) {
            return .{
                .name = undefined,
                .options = ArrayList(Latex).init(alloc),
            };
        } else {
            return .{
                .name = undefined,
                .options = null,
            };
        }
    }

    pub fn deinit(self: @This()) void {
        self.name.deinit();

        if (self.options) |options| {
            for (options.items) |*latex| {
                latex.deinit();
            }
            options.deinit();
        }
    }
};

pub const MathText = struct {
    state: MathState,
    text: Latex,

    pub fn init(alloc: Allocator) @This() {
        return .{ .state = undefined, .text = Latex.init(alloc) };
    }

    pub fn deinit(self: @This()) void {
        self.text.deinit();
    }
};

pub const PlainTextInMath = struct {
    trim: TrimWhitespace,
    text: Latex,

    pub fn deinit(self: @This()) void {
        self.text.deinit();
    }
};

pub const LatexFnt = struct {
    name: []const u8,
    args: ArrayList(Argument),
    has_space: bool,

    pub fn deinit(self: @This()) void {
        for (self.args.items) |*arg| {
            arg.deinit();
        }
        self.args.deinit();
    }
};

pub const Environment = struct {
    name: ArrayList(u8),
    args: ArrayList(Argument),
    text: Latex,

    pub fn deinit(self: @This()) void {
        self.name.deinit();
        for (self.args.items) |arg| {
            arg.deinit();
        }
        self.args.deinit();
        self.text.deinit();
    }
};

pub const PhantomBeginEnv = struct {
    name: ArrayList(u8),
    args: ArrayList(Argument),

    pub fn deinit(self: @This()) void {
        self.name.deinit();
        for (self.args.items) |arg| {
            arg.deinit();
        }
        self.args.deinit();
    }
};

pub const FunctionDefine = struct {
    style: FunctionStyle,
    name: ArrayList(u8),
    args: ArrayList(u8),
    trim: TrimWhitespace,
    body: Latex,

    pub fn deinit(self: @This()) void {
        self.name.deinit();
        self.args.deinit();
        self.body.deinit();
    }
};

pub const EnvironmentDefine = struct {
    is_redefine: bool,
    name: ArrayList(u8),
    args_num: u8,
    optional_arg: ?Latex,
    trim: TrimWhitespace,
    begin_part: Latex,
    end_part: Latex,

    pub fn deinit(self: @This()) void {
        self.name.deinit();
        self.begin_part.deinit();
        self.end_part.deinit();
        if (self.optional_arg) |optional| {
            optional.deinit();
        }
    }
};

pub const Argument = struct {
    arg_type: ArgNeed,
    inner: Latex,

    pub fn init(alloc: Allocator) @This() {
        return .{ .arg_type = undefined, .inner = Latex.init(alloc) };
    }

    pub fn deinit(self: @This()) void {
        self.inner.deinit();
    }
};

pub const TrimWhitespace = struct {
    start: bool,
    end: bool,
    mid: ?bool,
};

pub const MathState = enum(u2) {
    text_math,
    display_math,
};

pub const ArgNeed = enum(u2) {
    main_arg,
    optional,
    star_arg,
};

pub const FunctionStyle = enum(u8) {
    plain,
    long_plain,
    outer_plain,
    long_outer_plain,
    expand,
    long_expand,
    outer_expand,
    long_outer_expand,
    global,
    long_global,
    outer_global,
    long_outer_global,
    expand_global,
    long_expand_global,
    outer_expand_global,
    long_outer_expand_global,

    pub inline fn default() @This() {
        return .plain;
    }

    pub fn from_toktype(toktype: token.Type) ?@This() {
        return switch (toktype) {
            .function_def => .plain,
            .long_function_def => .long_plain,
            .outer_function_def => .outer_plain,
            .long_outer_function_def => .long_outer_plain,
            .e_function_def => .expand,
            .e_long_function_def => .long_expand,
            .e_outer_function_def => .outer_expand,
            .e_long_outer_function_def => .long_outer_expand,
            .g_function_def => .global,
            .g_long_function_def => .long_global,
            .g_outer_function_def => .outer_global,
            .g_long_outer_function_def => .long_outer_global,
            .x_function_def => .expand_global,
            .x_long_function_def => .long_expand_global,
            .x_outer_function_def => .outer_expand_global,
            .x_long_outer_function_def => .long_outer_expand_global,
            else => null,
        };
    }
};

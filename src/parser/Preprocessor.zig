const builtin = @import("builtin");
const std = @import("std");
const diag = @import("../diagnostic.zig");
const mem = std.mem;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const CowStr = @import("../CowStr.zig").CowStr;
const EnvMap = std.process.Environ.Map;
const Io = std.Io;
const Lexer = @import("../lexer/Lexer.zig");
const MultiArrayList = std.MultiArrayList;
const Span = @import("../location.zig").Span;
const StringHashMap = std.StringHashMap;
const Token = @import("../lexer/Token.zig");
const TokenType = Token.TokenType;
const zlua = @import("zlua");
const ZigLua = zlua.Lua;

const getConfigPath = @import("../Config.zig").getConfigPath;

allocator: Allocator,
io: Io,
env_map: *const EnvMap,
diagnostic: *diag.Diagnostic,
file_dir: *const Io.Dir,
lexer: Lexer,
curr_tok: Token,
peek_tok: Token,
comptime_fnt: StringHashMap(ComptimeFunction),
state: PreprocessorState,
included_stack: ArrayList([:0]const u8),
included_sources: ArrayList([]const u8),
// stack of open `#if`/`#ifdef`/... blocks; `lua` is a lazily-created state
// used only to evaluate `#if`/`#elif` conditions as lua expressions.
cond_stack: ArrayList(CondFrame),
lua: ?*ZigLua,

const Self = @This();
pub const PreprocessError = Allocator.Error ||
    error{ PreprocessFailed, GetFilePathFailed };

const CondKind = enum {
    if_cond, ifdef, ifndef, elif_cond, elifdef, elifndef, else_cond, endif,
};

const CONDITIONAL_DIRECTIVES = std.StaticStringMap(CondKind).initComptime(.{
    .{ "if", .if_cond },        .{ "ifdef", .ifdef },     .{ "ifndef", .ifndef },
    .{ "elif", .elif_cond },    .{ "elifdef", .elifdef }, .{ "elifndef", .elifndef },
    .{ "else", .else_cond },    .{ "endif", .endif },
});

const CondFrame = struct {
    parent_emit: bool, // enclosing context was emitting when this `#if` opened
    taken: bool, // a branch in this chain was already selected
    emit: bool, // the current branch is being emitted
    seen_else: bool, // an `#else` already appeared in this chain
    open_loc: Span,
};

pub const TokenList = struct {
    inner: ArrayList(Token) = .empty,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.inner.deinit(allocator);
    }

    pub inline fn len(self: *const @This()) usize {
        return self.inner.items.len;
    }

    pub inline fn append(self: *@This(), allocator: Allocator, val: Token) !void {
        try self.inner.append(allocator, val);
    }

    pub inline fn get(self: *const @This(), idx: usize) Token {
        std.debug.assert(idx < self.inner.items.len);
        return self.inner.items[idx];
    }
};

const PreprocessorState = packed struct {
    // after 2020-10-01, latex kernel now allows to use expl3 without importing
    // it.
    // Therefore, we allow to use #ltx3_on and #ltx3_off builtins in default.
    // Also, use xparse commands in default by defining commands and environments
    allow_latex3: bool = true,
    is_premiere: bool = true,
    lex_sleep: bool = false, // "sleep" lexer for one "clock"
};

pub fn init(
    allocator: Allocator,
    io: Io,
    env_map: *const EnvMap,
    file_dir: *const Io.Dir,
    diagnostic: *diag.Diagnostic,
    source: []const u8,
) !Self {
    var self: Self = undefined;

    self.allocator = allocator;
    self.io = io;
    self.env_map = env_map;
    self.diagnostic = diagnostic;
    self.file_dir = file_dir;
    self.lexer = try .init(source);
    self.comptime_fnt = .init(allocator);
    self.curr_tok = .INVALID;
    self.peek_tok = .INVALID;
    self.state = .{};
    self.included_stack = .empty;
    self.included_sources = .empty;
    self.cond_stack = .empty;
    self.lua = null;

    // fill curr_tok and peek_tok
    self.nextToken();
    self.nextToken();

    return self;
}

pub fn deinit(self: *Self) void {
    for (self.included_stack.items) |path| {
        self.allocator.free(path);
    }
    self.included_stack.deinit(self.allocator);

    for (self.included_sources.items) |source| {
        self.allocator.free(source);
    }
    self.included_sources.deinit(self.allocator);

    var val_iter = self.comptime_fnt.valueIterator();
    while (val_iter.next()) |val| {
        val.deinit(self.allocator);
    }
    self.comptime_fnt.deinit();

    self.cond_stack.deinit(self.allocator);
    if (self.lua) |l| l.deinit();
}

fn preprocessLoop(self: *Self, tok_list: *TokenList) PreprocessError!void {
    // Stage 1: Preprocess builtin functions
    // lexer.lex_finished triggered when self.peek_tok == .Eof.
    // Thus we need to preprocess token once more.
    while (!self.lexer.lex_finished) : (self.nextToken()) {
        try self.preprocessToken(tok_list);
    } else {
        try self.preprocessToken(tok_list);
    }
}

pub fn preprocess(self: *Self) PreprocessError!TokenList {
    var output: TokenList = .{};
    errdefer output.deinit(self.allocator);

    try self.preprocessLoop(&output);
    if (self.cond_stack.items.len > 0) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .IllegalUseErr = "unterminated `#if` block (missing `#endif`)" },
            .span = self.cond_stack.items[self.cond_stack.items.len - 1].open_loc,
        } });
        return PreprocessError.PreprocessFailed;
    }
    try output.append(self.allocator, Token.eof(self.curr_tok.span));

    return output;
}

inline fn nextToken(self: *Self) void {
    if (!self.state.lex_sleep) {
        self.curr_tok = self.peek_tok;
        self.peek_tok = self.lexer.next();
    } else {
        self.state.lex_sleep = false;
    }
}

inline fn expect(
    self: Self,
    comptime is_peek: enum(u1) { current, peek },
    comptime toktypes: []const TokenType,
) bool {
    var output: u1 = 0;
    const what_token = switch (is_peek) {
        .current => "curr_tok",
        .peek => "peek_tok",
    };
    inline for (toktypes) |toktype| {
        output |= @intFromBool(@intFromEnum(@field(self, what_token).toktype) ==
            @intFromEnum(toktype));
    }
    return output == 1;
}

inline fn expectWithError(
    self: *Self,
    comptime token: TokenType,
    comptime is_eat: enum(u1) { eat, remain },
) switch (is_eat) {
    .eat => PreprocessError!Token,
    .remain => PreprocessError!void,
} {
    if (!self.expect(.current, &.{token})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{token},
                .obtained = self.curr_tok.toktype,
            } },
            .span = self.curr_tok.span,
        } });
        return PreprocessError.PreprocessFailed;
    }
    if (is_eat == .eat) {
        const curr_tok = self.curr_tok;
        self.nextToken();
        return curr_tok;
    }
}

fn eatWhitespaces(self: *Self, comptime handle_newline: bool) void {
    while (self.expect(.current, &.{ .Space, .Tab }) or
        (handle_newline and self.expect(.current, &.{.Newline})))
    {
        self.nextToken();
    }
}

inline fn isBuiltin(name: []const u8, comptime kind: enum(u2) { preprocess, normal, all }) bool {
    return switch (kind) {
        .preprocess => Token.VESTI_PREPROCESS_BUILTINS.has(name),
        .normal => Token.VESTI_BUILTINS.has(name),
        .all => Token.VESTI_PREPROCESS_BUILTINS.has(name) or
            Token.VESTI_BUILTINS.has(name),
    };
}

fn preprocessToken(self: *Self, tok_list: *TokenList) !void {
    // conditional directives are processed even inside an inactive branch
    if (self.curr_tok.toktype == .BuiltinFunction) {
        if (CONDITIONAL_DIRECTIVES.get(self.curr_tok.toktype.BuiltinFunction)) |kind|
            return try self.preprocessConditional(kind);
    }
    // inside a non-selected `#if` branch: drop everything else
    if (!self.emitting()) return;

    switch (self.curr_tok.toktype) {
        .BuiltinFunction => |name| {
            inline for (comptime Token.VESTI_PREPROCESS_BUILTINS.keys()) |key| {
                if (comptime !CONDITIONAL_DIRECTIVES.has(key)) {
                    const callback = @field(Self, "preprocessBuiltin_" ++ key);
                    if (mem.eql(u8, key, name)) {
                        return try callback(self, tok_list);
                    }
                }
            }

            if (isBuiltin(name, .normal) or Token.isFunctionParam(name) != null) {
                // they are evaluated in the parser
                return try tok_list.append(self.allocator, self.curr_tok);
            }

            const fnt_loc = self.curr_tok.span;
            self.nextToken();
            // eat vesti function
            self.eatWhitespaces(false);
            try self.preprocessExpandDef(fnt_loc, name, tok_list);
        },
        .StartDoc => {
            self.state.is_premiere = false;
            try tok_list.append(self.allocator, self.curr_tok);
        },
        else => try tok_list.append(self.allocator, self.curr_tok),
    }
}

inline fn emitting(self: *const Self) bool {
    const items = self.cond_stack.items;
    return items.len == 0 or items[items.len - 1].emit;
}

fn getCondLua(self: *Self) !*ZigLua {
    if (self.lua) |l| return l;
    const l = try ZigLua.init(self.allocator);
    l.openLibs();
    self.lua = l;
    return l;
}

fn condErr(self: *Self, loc: Span, msg: []const u8) PreprocessError {
    self.diagnostic.initDiagInner(.{ .ParseError = .{
        .err_info = .{ .IllegalUseErr = msg },
        .span = loc,
    } });
    return PreprocessError.PreprocessFailed;
}

// drop the remainder of the directive's line (trailing spaces + its newline)
fn eatDirectiveLineEnd(self: *Self) void {
    while (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
    if (self.expect(.peek, &.{.Newline})) self.nextToken();
}

// curr is the directive builtin; eat it and collect the text between the
// following `( )` (nesting-aware) into `out`. Leaves curr at the closing `)`.
fn collectCondParen(self: *Self, loc: Span, out: *ArrayList(u8)) !void {
    self.nextToken(); // eat the directive builtin
    self.eatWhitespaces(false);
    try self.expectWithError(.Lparen, .remain);
    var nested: usize = 1;
    while (true) {
        switch (self.peek_tok.toktype) {
            .Lparen => nested += 1,
            .Rparen => {
                nested -= 1;
                if (nested == 0) break;
            },
            .Eof => return self.condErr(loc, "`)` expected to close the `#if`/`#elif` condition"),
            else => {},
        }
        try out.appendSlice(self.allocator, self.peek_tok.lit.in_text);
        self.nextToken();
    }
    self.nextToken(); // consume `)`
}

// evaluate `#if (<lua expr>)` / `#elif (...)` by running it as lua.
fn evalIfCondition(self: *Self, loc: Span) !bool {
    var expr: ArrayList(u8) = .empty;
    defer expr.deinit(self.allocator);
    try self.collectCondParen(loc, &expr);

    const lua = try self.getCondLua();
    var code: ArrayList(u8) = .empty;
    errdefer code.deinit(self.allocator);
    try code.appendSlice(self.allocator, "return (");
    try code.appendSlice(self.allocator, expr.items);
    try code.appendSlice(self.allocator, ")");
    const code_z = try code.toOwnedSliceSentinel(self.allocator, 0);
    defer self.allocator.free(code_z);

    lua.doString(code_z) catch {
        const msg = lua.toString(-1) catch "unknown error";
        std.debug.print("[#if] lua error: {s}\n", .{msg});
        lua.setTop(0);
        return self.condErr(loc, "failed to evaluate `#if`/`#elif` condition as lua");
    };
    const result = if (lua.getTop() > 0) lua.toBoolean(-1) else false;
    lua.setTop(0);
    return result;
}

// `#ifdef #name` / `#ifndef #name`: curr is the directive; reads the `#name`
// macro token and reports whether it is defined (xor `negate`).
fn evalDefined(self: *Self, loc: Span, negate: bool) !bool {
    self.nextToken(); // eat the directive builtin
    self.eatWhitespaces(false);
    const name = switch (self.curr_tok.toktype) {
        .BuiltinFunction => |n| n,
        else => return self.condErr(loc, "expected a macro name `#NAME` after `#ifdef`/`#ifndef`"),
    };
    return self.comptime_fnt.contains(name) != negate;
}

// consume a directive's argument without evaluating it (used while skipping).
fn skipCondArg(self: *Self, kind: CondKind, loc: Span) !void {
    switch (kind) {
        .if_cond, .elif_cond => {
            var dump: ArrayList(u8) = .empty;
            defer dump.deinit(self.allocator);
            try self.collectCondParen(loc, &dump);
        },
        .ifdef, .ifndef, .elifdef, .elifndef => {
            self.nextToken(); // eat directive; leave curr at the `#name` token
            self.eatWhitespaces(false);
        },
        .else_cond, .endif => {}, // no argument
    }
}

fn preprocessConditional(self: *Self, kind: CondKind) PreprocessError!void {
    const loc = self.curr_tok.span;
    switch (kind) {
        .if_cond, .ifdef, .ifndef => {
            const parent_emit = self.emitting();
            var cond = false;
            if (parent_emit) {
                cond = switch (kind) {
                    .if_cond => try self.evalIfCondition(loc),
                    .ifdef => try self.evalDefined(loc, false),
                    .ifndef => try self.evalDefined(loc, true),
                    else => unreachable,
                };
            } else {
                // dormant: don't evaluate, just stay in sync with the tokens
                try self.skipCondArg(kind, loc);
            }
            try self.cond_stack.append(self.allocator, .{
                .parent_emit = parent_emit,
                .taken = !parent_emit or cond,
                .emit = parent_emit and cond,
                .seen_else = false,
                .open_loc = loc,
            });
        },
        .elif_cond, .elifdef, .elifndef, .else_cond => {
            if (self.cond_stack.items.len == 0)
                return self.condErr(loc, "`#elif`/`#else` without a matching `#if`");
            const idx = self.cond_stack.items.len - 1;
            if (self.cond_stack.items[idx].seen_else)
                return self.condErr(loc, "`#elif`/`#else` after `#else`");
            if (kind == .else_cond) self.cond_stack.items[idx].seen_else = true;

            // evaluate this branch only if the chain is live and undecided
            if (self.cond_stack.items[idx].parent_emit and !self.cond_stack.items[idx].taken) {
                const cond = switch (kind) {
                    .elif_cond => try self.evalIfCondition(loc),
                    .elifdef => try self.evalDefined(loc, false),
                    .elifndef => try self.evalDefined(loc, true),
                    .else_cond => true,
                    else => unreachable,
                };
                self.cond_stack.items[idx].emit = cond;
                if (cond) self.cond_stack.items[idx].taken = true;
            } else {
                self.cond_stack.items[idx].emit = false;
                try self.skipCondArg(kind, loc);
            }
        },
        .endif => {
            if (self.cond_stack.items.len == 0)
                return self.condErr(loc, "`#endif` without a matching `#if`");
            _ = self.cond_stack.pop();
        },
    }
    self.eatDirectiveLineEnd();
}

const ComptimeFunction = struct {
    params: usize,
    contents: TokenList,

    fn deinit(self: *@This(), allocator: Allocator) void {
        self.contents.deinit(allocator);
    }
};

fn preprocessExpandDef(
    self: *Self,
    fnt_loc: Span,
    fnt_name: []const u8,
    tok_list: *TokenList,
) PreprocessError!void {
    const contents = self.comptime_fnt.get(fnt_name) orelse {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = try CowStr.init(.Owned, .{ self.allocator, fnt_name }),

                .note = "builtins is not defined",
            } },
            .span = fnt_loc,
        } });
        return PreprocessError.PreprocessFailed;
    };

    var params: ArrayList(TokenList) = try .initCapacity(self.allocator, contents.params);
    defer {
        for (params.items) |*param| param.deinit(self.allocator);
        params.deinit(self.allocator);
    }

    // assertion
    if (contents.params > 0) try self.expectWithError(.Lparen, .remain);
    for (0..contents.params) |_| {
        try self.parseParameter(fnt_loc, &params);
        if (self.expect(.peek, &.{.Lparen})) self.nextToken();
    }
    if (contents.params > 0) try self.expectWithError(.Rparen, .remain);

    // Expand the function body recursively
    try self.expandTokens(contents.contents, params.items, tok_list);

    // when contents.params == 0, preprocessor points the next token of the
    // vesti function. After that, preprocessor skip the token, so we need to
    // say to lexer "sleep"
    if (contents.params == 0) self.state.lex_sleep = true;
}

// Recursive function to expand tokens (handling substitution and nested macros)
fn expandTokens(
    self: *Self,
    input_tokens: TokenList,
    args: []const TokenList,
    output: *TokenList,
) PreprocessError!void {
    var i: usize = 0;
    while (i < input_tokens.len()) : (i += 1) {
        const tok = input_tokens.get(i);
        switch (tok.toktype) {
            .BuiltinFunction => |builtin_fnt| {
                if (isBuiltin(builtin_fnt, .preprocess)) {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{ .WrongBuiltin = .{
                            .name = try CowStr.init(.Owned, .{ self.allocator, builtin_fnt }),
                            .note = "there is a builtin function which cannot be used inside of vesti function body",
                        } },
                        .span = tok.span,
                    } });
                    return PreprocessError.PreprocessFailed;
                }

                if (isBuiltin(builtin_fnt, .normal)) {
                    // they are evaluated in the parser
                    try output.append(self.allocator, tok);
                    continue;
                }

                if (Token.isFunctionParam(builtin_fnt)) |fnt_param| {
                    if (fnt_param == 0) {
                        self.diagnostic.initDiagInner(.{ .ParseError = .{
                            .err_info = .{ .InvalidDefunParam = fnt_param },
                            .span = tok.span,
                        } });
                        return PreprocessError.PreprocessFailed;
                    }
                    if (fnt_param > args.len) {
                        // Parameter index out of bounds, maybe error or ignore?
                        // For safety, assuming strict match, but here just robust check.
                        self.diagnostic.initDiagInner(.{ .ParseError = .{
                            .err_info = .{ .InvalidDefunParam = fnt_param },
                            .span = tok.span,
                        } });
                        return PreprocessError.PreprocessFailed;
                    }
                    const param_toks = args[fnt_param - 1];
                    try self.expandTokens(param_toks, &.{}, output);
                } else if (self.comptime_fnt.get(builtin_fnt)) |nested_def| {
                    const parse_res = try self.parseArgs(
                        input_tokens,
                        i + 1,
                        nested_def.params,
                        tok.span,
                    );

                    var resolved_args = try ArrayList(TokenList).initCapacity(
                        self.allocator,
                        nested_def.params,
                    );
                    defer {
                        for (resolved_args.items) |*arg| arg.deinit(self.allocator);
                        resolved_args.deinit(self.allocator);
                    }

                    for (parse_res.args.items) |raw_arg| {
                        var resolved_arg: TokenList = .{};
                        try self.expandTokens(raw_arg, args, &resolved_arg);
                        try resolved_args.append(self.allocator, resolved_arg);
                    }

                    try self.expandTokens(nested_def.contents, resolved_args.items, output);

                    i += parse_res.consumed;

                    var mutable_args = parse_res.args;
                    for (mutable_args.items) |*arg| arg.deinit(self.allocator);
                    mutable_args.deinit(self.allocator);
                } else {
                    try output.append(self.allocator, tok);
                }
            },
            else => try output.append(self.allocator, tok),
        }
    }
}

fn parseArgs(
    self: *Self,
    slice: TokenList,
    start_idx: usize,
    params_count: usize,
    loc: Span,
) !struct {
    args: ArrayList(TokenList),
    consumed: usize,
} {
    var args = try ArrayList(TokenList).initCapacity(self.allocator, params_count);
    errdefer {
        for (args.items) |*a| a.deinit(self.allocator);
        args.deinit(self.allocator);
    }

    var idx = start_idx;
    var count: usize = 0;

    while (count < params_count) : (count += 1) {
        // Skip whitespace
        while (idx < slice.len() and
            (slice.get(idx).toktype == .Space or slice.get(idx).toktype == .Tab or
                slice.get(idx).toktype == .Newline)) : (idx += 1)
        {}

        if (idx >= slice.len() or slice.get(idx).toktype != .Lparen) {
            // TODO: fill note
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .WrongBuiltin = .{
                    .name = CowStr.init(.Borrowed, .{"def"}),
                    .note = "TODO: fill note later",
                } },
                .span = loc,
            } });
            return PreprocessError.PreprocessFailed;
        }

        idx += 1; // Consume '('

        var content = TokenList{};
        errdefer content.deinit(self.allocator);

        var nested: usize = 1;
        while (idx < slice.len()) : (idx += 1) {
            const tok = slice.get(idx);
            if (tok.toktype == .Lparen) {
                nested += 1;
            } else if (tok.toktype == .Rparen) {
                nested -= 1;
                if (nested == 0) break;
            }
            try content.append(self.allocator, tok);
        }

        if (nested != 0) {
            // TODO: fill note
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .WrongBuiltin = .{
                    .name = CowStr.init(.Borrowed, .{"def"}),
                    .note = "TODO: fill note later",
                } },
                .span = loc,
            } });
            return PreprocessError.PreprocessFailed;
        }

        try args.append(self.allocator, content);
        idx += 1; // Consume ')'
    }

    return .{ .args = args, .consumed = idx - start_idx };
}

fn parseParameter(self: *Self, loc: Span, params: *ArrayList(TokenList)) PreprocessError!void {
    var contents: TokenList = .{};
    errdefer contents.deinit(self.allocator);
    _ = try self.expectWithError(.Lparen, .eat);
    var nested: usize = 1;
    while (switch (self.curr_tok.toktype) {
        .Lparen => blk: {
            nested += 1;
            break :blk true;
        },
        .Rparen => blk: {
            nested -= 1;
            if (nested == 0) break :blk false;

            break :blk true;
        },
        .Eof => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = loc,
            } });

            return PreprocessError.PreprocessFailed;
        },
        else => true,
    }) : (self.nextToken()) {
        switch (self.curr_tok.toktype) {
            .BuiltinFunction => |builtin_fnt| {
                if (isBuiltin(builtin_fnt, .preprocess)) {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{ .WrongBuiltin = .{
                            .name = try CowStr.init(.Owned, .{ self.allocator, builtin_fnt }),
                            .note = "there is a builtin which cannot be used in vesti function parameters",
                        } },
                        .span = self.curr_tok.span,
                    } });
                    return PreprocessError.PreprocessFailed;
                }

                if (isBuiltin(builtin_fnt, .normal)) {
                    // they are evaluated in the parser
                    try contents.append(self.allocator, self.curr_tok);
                    continue;
                }

                const fnt_loc = self.curr_tok.span;
                self.nextToken(); // eat vesti function
                self.eatWhitespaces(false);
                try self.preprocessExpandDef(fnt_loc, builtin_fnt, &contents);
            },
            else => try contents.append(self.allocator, self.curr_tok),
        }
    }

    // To be sure that preprocessor stop at .Rbrace
    try self.expectWithError(.Rparen, .remain);
    try params.append(self.allocator, contents);
}

fn preprocessBuiltin_at_on(self: *Self, tok_list: *TokenList) !void {
    const loc = self.curr_tok.span;
    self.lexer.make_at_letter = true;
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();

    try tok_list.append(self.allocator, .{
        .toktype = .Newline,
        .lit = .{
            .in_text = "\n",
            .in_math = "\n",
        },
        .span = loc,
    });
    try tok_list.append(self.allocator, .{
        .toktype = .LatexFunction,
        .lit = .{
            .in_text = "\\makeatletter",
            .in_math = "\\makeatletter",
        },
        .span = loc,
    });
    try tok_list.append(self.allocator, .{
        .toktype = .Newline,
        .lit = .{
            .in_text = "\n",
            .in_math = "\n",
        },
        .span = loc,
    });
}

fn preprocessBuiltin_at_off(self: *Self, tok_list: *TokenList) !void {
    const loc = self.curr_tok.span;
    self.lexer.make_at_letter = true;
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();

    try tok_list.append(self.allocator, .{
        .toktype = .Newline,
        .lit = .{
            .in_text = "\n",
            .in_math = "\n",
        },
        .span = loc,
    });
    try tok_list.append(self.allocator, .{
        .toktype = .LatexFunction,
        .lit = .{
            .in_text = "\\makeatother",
            .in_math = "\\makeatother",
        },
        .span = loc,
    });
    try tok_list.append(self.allocator, .{
        .toktype = .Newline,
        .lit = .{
            .in_text = "\n",
            .in_math = "\n",
        },
        .span = loc,
    });
}

fn preprocessBuiltin_ltx3_on(self: *Self, tok_list: *TokenList) !void {
    const loc = self.curr_tok.span;
    self.lexer.is_latex3_on = true;
    if (self.state.allow_latex3) {
        if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
        try tok_list.append(self.allocator, .{
            .toktype = .Newline,
            .lit = .{
                .in_text = "\n",
                .in_math = "\n",
            },
            .span = loc,
        });
        try tok_list.append(self.allocator, .{
            .toktype = .LatexFunction,
            .lit = .{
                .in_text = "\\ExplSyntaxOn",
                .in_math = "\\ExplSyntaxOn",
            },
            .span = loc,
        });
        try tok_list.append(self.allocator, .{
            .toktype = .Newline,
            .lit = .{
                .in_text = "\n",
                .in_math = "\n",
            },
            .span = loc,
        });
    } else {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{
                .WrongBuiltin = .{
                    .name = CowStr.init(.Borrowed, .{"ltx3_on"}),
                    .note = "must remove `#noltx3` to use this builtin",
                },
            },
            .span = self.curr_tok.span,
        } });
        return PreprocessError.PreprocessFailed;
    }
}

fn preprocessBuiltin_ltx3_off(self: *Self, tok_list: *TokenList) !void {
    const loc = self.curr_tok.span;
    self.lexer.is_latex3_on = true;
    if (self.state.allow_latex3) {
        if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
        try tok_list.append(self.allocator, .{
            .toktype = .Newline,
            .lit = .{
                .in_text = "\n",
                .in_math = "\n",
            },
            .span = loc,
        });
        try tok_list.append(self.allocator, .{
            .toktype = .LatexFunction,
            .lit = .{
                .in_text = "\\ExplSyntaxOff",
                .in_math = "\\ExplSyntaxOff",
            },
            .span = loc,
        });
        try tok_list.append(self.allocator, .{
            .toktype = .Newline,
            .lit = .{
                .in_text = "\n",
                .in_math = "\n",
            },
            .span = loc,
        });
    } else {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{
                .WrongBuiltin = .{
                    .name = CowStr.init(.Borrowed, .{"ltx3_off"}),
                    .note = "must remove `#noltx3` to use this builtin",
                },
            },
            .span = self.curr_tok.span,
        } });
        return PreprocessError.PreprocessFailed;
    }
}

fn preprocessBuiltin_noltx3(self: *Self, _: *TokenList) !void {
    if (self.state.is_premiere) {
        self.state.allow_latex3 = false;
        if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
    } else {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .PreambleErr,
            .span = self.curr_tok.span,
        } });
        return PreprocessError.PreprocessFailed;
    }
}

fn preprocessBuiltin_def(self: *Self, _: *TokenList) !void {
    const def_fnt_loc = self.curr_tok.span;
    // eat #def builtin
    _ = try self.expectWithError(.{ .BuiltinFunction = "def" }, .eat);
    self.eatWhitespaces(false);
    const def_name = switch (self.curr_tok.toktype) {
        .BuiltinFunction => |name| blk: {
            self.nextToken();
            break :blk name;
        },
        else => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .WrongBuiltin = .{
                    .name = CowStr.init(.Borrowed, .{"def"}),
                    .note = "<builtin> expected here",
                } },
                .span = self.curr_tok.span,
            } });
            return PreprocessError.PreprocessFailed;
        },
    };
    self.eatWhitespaces(false);

    // prevent to override existing builtin functions
    if (isBuiltin(def_name, .all)) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = CowStr.init(.Borrowed, .{"def"}),
                .note = "one tried to change override builtin function",
            } },
            .span = def_fnt_loc,
        } });
        return PreprocessError.PreprocessFailed;
    }

    var contents: TokenList = .{};
    errdefer contents.deinit(self.allocator);
    // start to parse body of the contents
    _ = try self.expectWithError(.Lbrace, .eat);
    var params: usize = 0;
    var nested: usize = 1;
    while (switch (self.curr_tok.toktype) {
        .Lbrace => blk: {
            nested += 1;
            break :blk true;
        },
        .Rbrace => blk: {
            nested -= 1;
            if (nested == 0) break :blk false;

            break :blk true;
        },
        .Eof => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = def_fnt_loc,
            } });

            return PreprocessError.PreprocessFailed;
        },
        else => true,
    }) : (self.nextToken()) {
        switch (self.curr_tok.toktype) {
            .BuiltinFunction => |builtin_fnt| {
                if (isBuiltin(builtin_fnt, .preprocess)) {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{ .WrongBuiltin = .{
                            .name = try CowStr.init(.Owned, .{ self.allocator, builtin_fnt }),
                            .note = "there is a builtin function which cannot be used inside of vesti function body",
                        } },
                        .span = self.curr_tok.span,
                    } });
                    return PreprocessError.PreprocessFailed;
                }

                if (isBuiltin(builtin_fnt, .normal)) {
                    // they are evaluated in the parser
                    try contents.append(self.allocator, self.curr_tok);
                    continue;
                }

                if (Token.isFunctionParam(builtin_fnt)) |fnt_param| {
                    if (fnt_param == 0) {
                        self.diagnostic.initDiagInner(.{ .ParseError = .{
                            .err_info = .{ .InvalidDefunParam = fnt_param },

                            .span = def_fnt_loc,
                        } });
                        return PreprocessError.PreprocessFailed;
                    }
                    params = @max(params, fnt_param);
                }
            },
            else => {},
        }
        try contents.append(self.allocator, self.curr_tok);
    }

    // To be sure that preprocessor stop at .Rbrace
    try self.expectWithError(.Rbrace, .remain);
    if (self.expect(.peek, &.{ .Space, .Tab, .Newline })) {
        self.nextToken(); // eat `}`
        while (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
    }

    // def_name_tok.lit should point the source code
    try self.comptime_fnt.put(def_name, .{ .params = params, .contents = contents });
}

fn preprocessBuiltin_undef(self: *Self, _: *TokenList) !void {
    const undef_fnt_loc = self.curr_tok.span;
    // eat #undef builtin
    _ = try self.expectWithError(.{ .BuiltinFunction = "undef" }, .eat);
    self.eatWhitespaces(false);
    const undef_name = switch (self.curr_tok.toktype) {
        .BuiltinFunction => |name| blk: {
            self.nextToken();
            break :blk name;
        },
        else => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .WrongBuiltin = .{
                    .name = CowStr.init(.Borrowed, .{"undef"}),
                    .note = "<builtin> expected here",
                } },
                .span = self.curr_tok.span,
            } });
            return PreprocessError.PreprocessFailed;
        },
    };
    self.eatWhitespaces(false);
    try self.expectWithError(.Newline, .remain);
    // prevent to override existing builtin functions
    if (isBuiltin(undef_name, .all)) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = CowStr.init(.Borrowed, .{"undef"}),
                .note = "cannot undef builtin functions",
            } },

            .span = undef_fnt_loc,
        } });
        return PreprocessError.PreprocessFailed;
    }

    if (!self.comptime_fnt.contains(undef_name)) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = CowStr.init(.Borrowed, .{"undef"}),
                .note = "cannot undef undefined vesti function",
            } },

            .span = undef_fnt_loc,
        } });
        return PreprocessError.PreprocessFailed;
    }

    // deallocate contents
    self.comptime_fnt.getPtr(undef_name).?.deinit(self.allocator);
    _ = self.comptime_fnt.remove(undef_name);
}

fn preprocessBuiltin_include(self: *Self, tok_list: *TokenList) !void {
    const include_loc = self.curr_tok.span;

    // eat #include
    _ = try self.expectWithError(.{ .BuiltinFunction = "include" }, .eat);
    self.eatWhitespaces(false);
    // ensure `(` is present so getFilePath's precondition holds (no assert crash)
    try self.expectWithError(.Lparen, .remain);

    var filepath = try self.getFilePath(include_loc);
    defer filepath.deinit(self.allocator);

    // Canonicalize for cycle detection. realpath also validates the file exists.
    const canon_path = self.file_dir.realPathFileAlloc(
        self.io,
        filepath.items,
        self.allocator,
    ) catch {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = CowStr.init(.Borrowed, .{"include"}),
                .note = "cannot resolve included file path",
            } },
            .span = include_loc,
        } });
        return PreprocessError.PreprocessFailed;
    };
    errdefer self.allocator.free(canon_path);

    // Cycle check
    for (self.included_stack.items) |existing| {
        if (mem.eql(u8, existing, canon_path)) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .WrongBuiltin = .{
                    .name = CowStr.init(.Borrowed, .{"include"}),
                    .note = "circular #include detected",
                } },
                .span = include_loc,
            } });
            return PreprocessError.PreprocessFailed;
        }
    }

    const source = self.file_dir.readFileAlloc(
        self.io,
        filepath.items,
        self.allocator,
        .unlimited,
    ) catch {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = CowStr.init(.Borrowed, .{"include"}),
                .note = "failed to read included file",
            } },
            .span = include_loc,
        } });
        return PreprocessError.PreprocessFailed;
    };
    errdefer self.allocator.free(source);
    try self.included_sources.append(self.allocator, source);
    try self.included_stack.append(self.allocator, canon_path);

    // Save lexer-tied state. We deliberately do NOT save self.state in full —
    // changes like is_premiere=false and new comptime_fnt entries should
    // propagate back to the parent. Only lex_sleep is lexer-local.
    const saved_lexer = self.lexer;
    const saved_curr = self.curr_tok;
    const saved_peek = self.peek_tok;
    const saved_lex_sleep = self.state.lex_sleep;

    self.lexer = try Lexer.init(source);
    self.curr_tok = .INVALID;
    self.peek_tok = .INVALID;
    self.state.lex_sleep = false;
    self.nextToken();
    self.nextToken();

    // preprocess included file
    try self.preprocessLoop(tok_list);

    // Restore parent's lexer position
    self.lexer = saved_lexer;
    self.curr_tok = saved_curr;
    self.peek_tok = saved_peek;
    self.state.lex_sleep = saved_lex_sleep;
}

// TODO: This function and Parser.parseFilepathHelper are same.
// make a single implementation for both
// <return>[1] points <return>[0]
fn getFilePath(
    self: *Self,
    left_parn_loc: Span,
) !ArrayList(u8) {
    std.debug.assert(self.curr_tok.toktype == .Lparen);

    var file_path_str = try ArrayList(u8).initCapacity(self.allocator, 30);
    errdefer file_path_str.deinit(self.allocator);

    var inside_config_dir = false;
    var parse_very_first_chr = false;
    var nested: usize = 1;

    while (true) {
        const chr_ty = self.peek_tok.toktype;
        const chr_str = self.peek_tok.lit.in_text;

        switch (chr_ty) {
            .Lparen => nested += 1,
            .Rparen => {
                nested -= 1;
                if (nested == 0) break;
            },
            .Tilde => if (!parse_very_first_chr) {
                const home_dir = getHomePath(self.env_map) orelse {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{
                            .VestiInternal = "Cannot find home. Check `HOME` env is defined on linux and macos, or `USERPROFILE` on windows",
                        },
                        .span = self.curr_tok.span,
                    } });
                    return PreprocessError.GetFilePathFailed;
                };
                try file_path_str.appendSlice(self.allocator, home_dir);
            } else {
                try file_path_str.appendSlice(self.allocator, chr_str);
            },
            .At => if (!parse_very_first_chr) {
                inside_config_dir = true;
                self.nextToken();

                if (self.peek_tok.toktype != .Slash) {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{
                            .IllegalUseErr = "The next token for `@` should be `/`",
                        },
                        .span = left_parn_loc,
                    } });
                    return PreprocessError.GetFilePathFailed;
                }
                continue;
            },
            .Eof => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .IsNotClosed = .{
                        .open = &.{.Lparen},
                        .close = .Rparen,
                    } },
                    .span = left_parn_loc,
                } });
                return PreprocessError.GetFilePathFailed;
            },
            else => {
                try file_path_str.appendSlice(self.allocator, chr_str);
            },
        }
        parse_very_first_chr = true;
        self.nextToken();
    }
    self.nextToken();

    const file_path_str_raw = try file_path_str.toOwnedSlice(self.allocator);
    defer self.allocator.free(file_path_str_raw);
    if (inside_config_dir) {
        const config_path = try getConfigPath(self.allocator, self.env_map);
        defer self.allocator.free(config_path);
        try file_path_str.print(
            self.allocator,
            "{s}/{s}",
            .{ config_path, mem.trim(u8, file_path_str_raw, " \t") },
        );
    } else if (Io.Dir.path.isAbsolute(file_path_str_raw)) {
        try file_path_str.print(
            self.allocator,
            "{s}",
            .{mem.trim(u8, file_path_str_raw, " \t")},
        );
    } else {
        try file_path_str.print(
            self.allocator,
            "./{s}",
            .{mem.trim(u8, file_path_str_raw, " \t")},
        );
    }

    return file_path_str;
}

inline fn getHomePath(env_map: *const EnvMap) ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => env_map.get("USERPROFILE"),
        .linux, .macos => env_map.get("HOME"),
        else => @compileError("only linux, macos and windows are supported"),
    };
}

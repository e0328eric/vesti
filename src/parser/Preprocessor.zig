const std = @import("std");
const diag = @import("../diagnostic.zig");
const mem = std.mem;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const CowStr = @import("../CowStr.zig").CowStr;
const Lexer = @import("../lexer/Lexer.zig");
const MultiArrayList = std.MultiArrayList;
const Span = @import("../location.zig").Span;
const StringHashMap = std.StringHashMap;
const Token = @import("../lexer/Token.zig");
const TokenType = Token.TokenType;

allocator: Allocator,
diagnostic: *diag.Diagnostic,
lexer: Lexer,
curr_tok: Token,
peek_tok: Token,
comptime_fnt: StringHashMap(ComptimeFunction),
// after 2020-10-01, latex kernel now allows to use expl3 without importing
// it. Therefore, we allow to use #ltx3_on and #ltx3_off builtins in default.
// Also, use xparse commands in default by defining commands and environments
allow_latex3: bool = true,
is_premiere: bool = true,
lex_sleep: bool = false, // "sleep" lexer for one "clock"

const Self = @This();
pub const PreprocessError = Allocator.Error || error{
    ParseFailed,
};

pub const TokenList = struct {
    inner: MultiArrayList(Token) = .{},

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.deinit(allocator);
    }

    pub fn append(self: *@This(), allocator: Allocator, val: Token) !void {
        try self.inner.append(allocator, val);
    }

    pub fn get(self: @This(), idx: usize) Token {
        return self.inner.get(idx);
    }
};

pub fn init(allocator: Allocator, diagnostic: *diag.Diagnostic, source: []const u8) !Self {
    var self: Self = undefined;

    self.allocator = allocator;
    self.diagnostic = diagnostic;
    self.lexer = try .init(source);
    self.comptime_fnt = .init(allocator);
    self.curr_tok = .invalid;
    self.peek_tok = .invalid;

    // fill curr_tok and peek_tok
    self.nextToken();
    self.nextToken();

    return self;
}

pub fn deinit(self: *Self) void {
    var val_iter = self.comptime_fnt.valueIterator();
    while (val_iter.next()) |val| {
        val.deinit(self.allocator);
    }
    self.comptime_fnt.deinit();
}

pub fn preprocess(self: *Self) !TokenList {
    var output: TokenList = .{};
    errdefer output.deinit(self.allocator);

    // lexer.lex_finished triggered when self.peek_tok == .Eof.
    // Thus we need to preprocess token once more.
    while (!self.lexer.lex_finished) : (self.nextToken()) {
        try self.preprocessToken(&output);
    } else {
        try self.preprocessToken(&output);
    }

    return output;
}

inline fn nextToken(self: *Self) void {
    if (!self.lex_sleep) {
        @branchHint(.likely);
        self.curr_tok = self.peek_tok;
        self.peek_tok = self.lexer.next();
    } else {
        self.lex_sleep = false;
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
        return PreprocessError.ParseFailed;
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
    switch (self.curr_tok.toktype) {
        .BuiltinFunction => |name| {
            inline for (comptime Token.VESTI_PREPROCESS_BUILTINS.keys()) |key| {
                const callback = @field(Self, "preprocessBuiltin_" ++ key);
                if (mem.eql(u8, key, name)) {
                    return try callback(self, tok_list);
                }
            }

            if (isBuiltin(name, .normal)) {
                // they are evaluated in the parser
                return try tok_list.append(self.allocator, self.curr_tok);
            }

            const fnt_loc = self.curr_tok.span;
            self.nextToken(); // eat vesti function
            self.eatWhitespaces(false);
            try self.preprocessExpandDef(fnt_loc, name, tok_list);
        },
        .StartDoc => {
            self.is_premiere = false;
            try tok_list.append(self.allocator, self.curr_tok);
        },
        else => try tok_list.append(self.allocator, self.curr_tok),
    }
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
        return PreprocessError.ParseFailed;
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

    // expand function contents
    for (0..contents.contents.inner.len) |i| {
        const tok = contents.contents.get(i);
        switch (tok.toktype) {
            .BuiltinFunction => |builtin_fnt| {
                if (isBuiltin(builtin_fnt, .preprocess)) {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{ .WrongBuiltin = .{
                            .name = try CowStr.init(.Owned, .{ self.allocator, builtin_fnt }),
                            .note = "there is a builtin function which cannot be used inside of vesti function body",
                        } },
                        .span = fnt_loc,
                    } });
                    return PreprocessError.ParseFailed;
                }

                if (isBuiltin(builtin_fnt, .normal)) {
                    // they are evaluated in the parser
                    try tok_list.append(self.allocator, tok);
                    continue;
                }

                if (Token.isFunctionParam(builtin_fnt)) |fnt_param| {
                    if (fnt_param == 0) {
                        self.diagnostic.initDiagInner(.{ .ParseError = .{
                            .err_info = .{ .InvalidDefunParam = fnt_param },
                            .span = fnt_loc,
                        } });
                        return PreprocessError.ParseFailed;
                    }

                    const param = &params.items[fnt_param - 1];
                    for (0..param.inner.len) |j| {
                        try tok_list.append(self.allocator, param.get(j));
                    }
                }
            },
            else => try tok_list.append(self.allocator, tok),
        }
    }

    // when contents.params == 0, preprocessor points the next token of the
    // vesti function. After that, preprocessor skip the token, so we need to
    // say to lexer "sleep"
    if (contents.params == 0) self.lex_sleep = true;
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
            return PreprocessError.ParseFailed;
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
                    return PreprocessError.ParseFailed;
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
    if (self.allow_latex3) {
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
        return PreprocessError.ParseFailed;
    }
}

fn preprocessBuiltin_ltx3_off(self: *Self, tok_list: *TokenList) !void {
    const loc = self.curr_tok.span;
    self.lexer.is_latex3_on = true;
    if (self.allow_latex3) {
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
        return PreprocessError.ParseFailed;
    }
}

fn preprocessBuiltin_noltx3(self: *Self, _: *TokenList) !void {
    if (self.is_premiere) {
        self.allow_latex3 = false;
        if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
    } else {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .PreambleErr,
            .span = self.curr_tok.span,
        } });
        return PreprocessError.ParseFailed;
    }
}

// TODO: one should track locations of parameters inside of luacode
fn preprocessBuiltin_def(self: *Self, _: *TokenList) !void {
    const def_fnt_loc = self.curr_tok.span;

    // eat #def builtin
    _ = try self.expectWithError(.{ .BuiltinFunction = "def" }, .eat);
    self.eatWhitespaces(false);

    const def_name_tok = try self.expectWithError(.Text, .eat);
    self.eatWhitespaces(false);

    // prevent to override existing builtin functions
    if (isBuiltin(def_name_tok.lit.in_text, .all)) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = CowStr.init(.Borrowed, .{"def"}),
                .note = "one tried to change override builtin function",
            } },
            .span = def_fnt_loc,
        } });
        return PreprocessError.ParseFailed;
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
            return PreprocessError.ParseFailed;
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
                    return PreprocessError.ParseFailed;
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
                        return PreprocessError.ParseFailed;
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

    // def_name_tok.lit should point the source code
    try self.comptime_fnt.put(def_name_tok.lit.in_text, .{
        .params = params,
        .contents = contents,
    });
}

fn preprocessBuiltin_undef(self: *Self, _: *TokenList) !void {
    const undef_fnt_loc = self.curr_tok.span;

    // eat #def builtin
    _ = try self.expectWithError(.{ .BuiltinFunction = "undef" }, .eat);
    self.eatWhitespaces(false);

    const undef_name_tok = try self.expectWithError(.Text, .eat);
    const undef_name = undef_name_tok.lit.in_text.toStr();
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
        return PreprocessError.ParseFailed;
    }

    if (!self.comptime_fnt.contains(undef_name)) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = CowStr.init(.Borrowed, .{"undef"}),
                .note = "cannot undef undefined vesti function",
            } },
            .span = undef_fnt_loc,
        } });
        return PreprocessError.ParseFailed;
    }

    // deallocate contents
    self.comptime_fnt.getPtr(undef_name).?.deinit(self.allocator);
    _ = self.comptime_fnt.remove(undef_name);
}

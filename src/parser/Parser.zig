const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const path = fs.path;
const zon = std.zon;
const ast = @import("./ast.zig");
const diag = @import("../diagnostic.zig");

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const CowStr = @import("../CowStr.zig").CowStr;
const ParseErrKind = diag.ParseDiagnostic.ParseErrKind;
const Lexer = @import("../lexer/Lexer.zig");
const Literal = Token.Literal;
const Stmt = ast.Stmt;
const Span = @import("../location.zig").Span;
const Token = @import("../lexer/Token.zig");
const TokenType = Token.TokenType;

const vestiNameMangle = @import("../compile.zig").vestiNameMangle;

allocator: Allocator,
lexer: Lexer,
curr_tok: Token,
peek_tok: Token,
doc_state: DocState,
diagnostic: *diag.Diagnostic,
file_dir: *fs.Dir,
allow_luacode: bool,

const Self = @This();

pub const VESTI_LOCAL_DUMMY_DIR = "./.vesti-dummy";
const ENV_MATH_IDENT = std.StaticStringMap(void).initComptime(.{
    .{"equation"},
    .{"align"},
    .{"array"},
    .{"eqnarray"},
    .{"gather"},
    .{"multline"},
});

pub const ParseError = Allocator.Error ||
    process.GetEnvVarOwnedError ||
    error{ ParseFailed, ParseZon, NameMangle, LuaInitFailed };

pub const VestiModule = struct {
    name: []const u8,
    version: ?[]const u8,
    exports: []const []const u8,
};

const DocState = packed struct {
    latex3_included: bool = false,
    doc_start: bool = false,
    prevent_end_doc: bool = false,
    parsing_define: bool = false,
    math_mode: bool = false,
};

pub fn init(
    allocator: Allocator,
    source: []const u8,
    file_dir: *fs.Dir,
    diagnostic: *diag.Diagnostic,
    allow_luacode: bool,
) !Self {
    var self: Self = undefined;

    self.allocator = allocator;
    self.lexer = try Lexer.init(allocator, source);
    self.curr_tok = self.lexer.next();
    self.peek_tok = self.lexer.next();
    self.doc_state = DocState{};
    self.diagnostic = diagnostic;
    self.file_dir = file_dir;
    self.allow_luacode = allow_luacode;

    return self;
}

pub fn deinit(self: Self) void {
    self.lexer.deinit(self.allocator);
}

pub fn parse(self: *Self) ParseError!ArrayList(Stmt) {
    var stmts = try ArrayList(Stmt).initCapacity(self.allocator, 100);
    errdefer {
        for (stmts.items) |stmt| stmt.deinit();
        stmts.deinit();
    }

    // lexer.lex_finished means that peek_tok is the "last" token from lexer
    while (!self.lexer.lex_finished) : (self.nextToken()) {
        const stmt = try self.parseStatement();
        errdefer stmt.deinit();
        try stmts.append(stmt);
    } else {
        // so we need one more step to exhaust peek_tok
        const stmt = try self.parseStatement();
        errdefer stmt.deinit();
        try stmts.append(stmt);
        if (self.doc_state.doc_start and !self.doc_state.prevent_end_doc)
            try stmts.append(Stmt.DocumentEnd);
    }

    return stmts;
}

inline fn isPremiere(self: Self) bool {
    return !self.doc_state.doc_start and !self.doc_state.parsing_define;
}

inline fn nextToken(self: *Self) void {
    self.curr_tok = self.peek_tok;
    self.peek_tok = self.lexer.next();
}

inline fn nextRawToken(self: *Self) void {
    self.curr_tok = self.peek_tok;
    self.peek_tok = self.lexer.nextRaw();
}

const ExpectKind = enum(u1) {
    current,
    peek,
};

inline fn expect(
    self: Self,
    comptime is_peek: ExpectKind,
    comptime toktypes: []const TokenType,
) bool {
    var output: u1 = 0;
    const what_token = if (is_peek == .peek) "peek_tok" else "curr_tok";
    inline for (toktypes) |toktype| {
        output |= @intFromBool(@intFromEnum(@field(self, what_token).toktype) ==
            @intFromEnum(toktype));
    }
    return output == 1;
}

inline fn currToktype(self: Self) TokenType {
    return self.curr_tok.toktype;
}

inline fn peekToktype(self: Self) TokenType {
    return self.peek_tok.toktype;
}

fn eatWhitespaces(self: *Self, comptime handle_newline: bool) void {
    while (self.expect(.current, &.{ .Space, .Tab }) or
        (handle_newline and self.expect(.current, &.{.Newline})))
    {
        self.nextToken();
    }
}

fn parseStatement(self: *Self) ParseError!Stmt {
    return switch (self.currToktype()) {
        .NonStopMode => blk: {
            if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
            break :blk Stmt.NonStopMode;
        },
        .MakeAtLetter => blk: {
            if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
            break :blk Stmt.MakeAtLetter;
        },
        .MakeAtOther => blk: {
            if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
            break :blk Stmt.MakeAtOther;
        },
        .ImportLatex3 => if (self.isPremiere()) blk: {
            self.doc_state.latex3_included = true;
            if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
            break :blk Stmt.ImportExpl3Pkg;
        } else {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .PremiereErr,
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
        .Latex3On => if (self.doc_state.latex3_included) blk: {
            if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
            break :blk Stmt.Latex3On;
        } else {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{
                    .IllegalUseErr = "must use `useltx3` to use this keyword",
                },
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
        .Latex3Off => if (self.doc_state.latex3_included) blk: {
            if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
            break :blk Stmt.Latex3Off;
        } else {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{
                    .IllegalUseErr = "must use `useltx3` to use this keyword",
                },
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
        .Docclass => blk: {
            break :blk if (self.isPremiere())
                try self.parseDocclass()
            else
                self.parseLiteral();
        },
        .ImportPkg => blk: {
            break :blk if (self.isPremiere())
                try self.parseSinglePkg()
            else
                self.parseLiteral();
        },
        .StartDoc => if (self.isPremiere()) blk: {
            self.doc_state.doc_start = true;
            break :blk Stmt.DocumentStart;
        } else self.parseLiteral(),
        .InlineMathSwitch, .DisplayMathSwitch => if (!self.doc_state.math_mode) blk: {
            self.doc_state.math_mode = true;
            break :blk try self.parseMathStmt();
        } else {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{
                    .IllegalUseErr = "math block is not properly closed",
                },
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
        .DisplayMathStart => blk: {
            self.doc_state.math_mode = true;
            break :blk try self.parseMathStmt();
        },
        .DisplayMathEnd => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{
                    .IllegalUseErr = "math block is not properly closed",
                },
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
        .Question => if (self.doc_state.math_mode)
            try self.parseOpenDelimiter()
        else
            self.parseLiteral(),
        .Period,
        .Lparen,
        .Lsqbrace,
        .Langle,
        .MathLbrace,
        .Vert,
        .Norm,
        .Rparen,
        .Rsqbrace,
        .Rangle,
        .MathRbrace,
        => if (self.doc_state.math_mode)
            try self.parseClosedDelimiter()
        else
            self.parseLiteral(),
        .Lbrace => try self.parseBrace(true),
        .Useenv => try self.parseEnvironment(true),
        .Begenv => try self.parseEnvironment(false),
        .Endenv => try self.parseEndPhantomEnvironment(),
        .MathMode => try self.parseMathMode(),
        .DoubleQuote => if (self.doc_state.math_mode)
            try self.parseTextInMath(false)
        else
            self.parseLiteral(),
        .RawSharp => if (self.doc_state.math_mode)
            try self.parseTextInMath(true)
        else
            self.parseLiteral(),
        .GetFilePath => try self.parseFilepath(),
        .ImportVesti => try self.parseImportVesti(),
        .CopyFile => try self.parseCopyFile(),
        .ImportModule => try self.parseImportModule(),
        .LuaCode => if (self.allow_luacode)
            try self.parseLuaCode()
        else {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .DisallowLuacode,
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
        .Deprecated => |info| {
            if (info.valid_in_text) return self.parseLiteral();
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .Deprecated = info.instead },
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
        else => self.parseLiteral(),
    };
}

fn parseLiteral(self: *Self) Stmt {
    return if (self.doc_state.math_mode)
        Stmt{ .MathLit = self.curr_tok.lit.in_math }
    else
        Stmt{ .TextLit = self.curr_tok.lit.in_text };
}

fn parseDocclass(self: *Self) ParseError!Stmt {
    if (!self.expect(.current, &.{.Docclass})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Docclass},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();
    self.eatWhitespaces(false);

    const name = try self.takeName();
    errdefer name.deinit();
    self.eatWhitespaces(false);

    const options = switch (self.currToktype()) {
        .Eof, .Newline => null,
        else => try self.parseOptions(),
    };
    errdefer {
        if (options) |options_| {
            for (options_.items) |option| option.deinit();
            options_.deinit();
        }
    }

    return Stmt{
        .DocumentClass = .{
            .name = name,
            .options = options,
        },
    };
}

fn parseSinglePkg(self: *Self) ParseError!Stmt {
    if (!self.expect(.current, &.{.ImportPkg})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.ImportPkg},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();
    self.eatWhitespaces(false);

    if (self.expect(.current, &.{.Lbrace})) return self.parseMultiplePkgs();

    const name = try self.takeName();
    errdefer name.deinit();
    self.eatWhitespaces(false);

    const options = switch (self.currToktype()) {
        .Lparen => try self.parseOptions(),
        else => null,
    };
    errdefer {
        if (options) |options_| {
            for (options_.items) |option| option.deinit();
            options_.deinit();
        }
    }

    return Stmt{
        .ImportSinglePkg = .{
            .name = name,
            .options = options,
        },
    };
}

fn parseMultiplePkgs(self: *Self) ParseError!Stmt {
    if (!self.expect(.current, &.{.Lbrace})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Lbrace},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();

    var output = try ArrayList(ast.UsePackage).initCapacity(self.allocator, 10);
    errdefer {
        for (output.items) |pkg| pkg.deinit();
        output.deinit();
    }

    var name = CowStr.init(.Empty, .{});
    errdefer name.deinit();
    var options: ?ArrayList(CowStr) = null;
    errdefer {
        if (options) |o| {
            for (o.items) |s| s.deinit();
            o.deinit();
        }
    }

    while (true) : (self.nextToken()) {
        self.eatWhitespaces(true);
        if (self.expect(.current, &.{.Rbrace})) break;

        name = try self.takeName();
        self.eatWhitespaces(false);

        options = switch (self.currToktype()) {
            .Lparen => blk: {
                const tmp = try self.parseOptions();
                self.nextToken();
                break :blk tmp;
            },
            else => null,
        };
        self.eatWhitespaces(true);

        switch (self.currToktype()) {
            .Comma, .Rbrace => {
                try output.append(.{
                    .name = name,
                    .options = options,
                });

                if (self.expect(.current, &.{.Rbrace})) break else continue;
            },
            .Eof => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .EofErr,
                    .span = self.curr_tok.span,
                } });
                return ParseError.ParseFailed;
            },
            else => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .TokenExpected = .{
                        .expected = &.{ .Comma, .Rbrace },
                        .obtained = self.currToktype(),
                    } },
                    .span = self.curr_tok.span,
                } });
                return ParseError.ParseFailed;
            },
        }
    }
    if (!self.expect(.current, &.{.Rbrace})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{
                .VestiInternal = "`parseMultiplePkgs` implementation bug occurs",
            },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    return Stmt{
        .ImportMultiplePkgs = output,
    };
}

fn parseOptions(self: *Self) ParseError!ArrayList(CowStr) {
    if (!self.expect(.current, &.{.Lparen})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Lparen},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();

    var output = try ArrayList(CowStr).initCapacity(self.allocator, 10);
    errdefer {
        for (output.items) |expr| expr.deinit();
        output.deinit();
    }

    var tmp = CowStr.init(.Empty, .{});
    errdefer tmp.deinit();

    while (switch (self.currToktype()) {
        .Rparen => false,
        .Eof => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
        else => true,
    }) : (self.nextToken()) {
        switch (self.currToktype()) {
            .Comma => {
                if (tmp != .Empty) {
                    try output.append(tmp);
                    tmp = CowStr.init(.Empty, .{});
                }
            },
            .Space, .Tab, .Newline => continue,
            else => try tmp.append(self.allocator, self.curr_tok.lit.in_text),
        }
    } else {
        if (tmp != .Empty) {
            try output.append(tmp);
        }
    }

    return output;
}

fn takeName(self: *Self) ParseError!CowStr {
    if (self.expect(.current, &.{.Eof})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .EofErr,
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    // if next peek token cannot be the pkg name, then save some memory
    var output = switch (self.currToktype()) {
        .Text, .Minus, .Integer => try CowStr.init(
            .Owned,
            .{ self.allocator, self.curr_tok.lit.in_text },
        ),
        else => return CowStr.init(.Borrowed, .{self.curr_tok.lit.in_text}),
    };
    errdefer output.deinit();
    self.nextToken();

    while (self.expect(.current, &.{ .Text, .Minus, .Integer })) : (self.nextToken()) {
        try output.append(self.allocator, self.curr_tok.lit.in_text);
    }

    return output;
}

fn parseMathStmt(self: *Self) !Stmt {
    return switch (self.currToktype()) {
        inline .InlineMathSwitch,
        .DisplayMathSwitch,
        .DisplayMathStart,
        => |_, open_tok| self.parseMathStmtInner(open_tok),
        else => unreachable,
    };
}

fn getClosedMathStmt(comptime open_tok: TokenType) TokenType {
    return switch (open_tok) {
        inline .InlineMathSwitch, .DisplayMathSwitch => |_, toktype| toktype,
        .DisplayMathStart => .DisplayMathEnd,
        else => @compileError("invalid `open_tok` token was given"),
    };
}

fn getMathStmtState(comptime open_tok: TokenType) ast.MathState {
    return switch (open_tok) {
        .InlineMathSwitch => .Inline,
        .DisplayMathSwitch, .DisplayMathStart => .Display,
        else => @compileError("invalid `open_tok` token was given"),
    };
}

fn parseMathStmtInner(self: *Self, comptime open_tok: TokenType) !Stmt {
    const close_tok = comptime getClosedMathStmt(open_tok);
    var ctx = try ArrayList(Stmt).initCapacity(self.allocator, 20);
    errdefer {
        for (ctx.items) |stmt| stmt.deinit();
        ctx.deinit();
    }

    if (!self.expect(.current, &.{open_tok})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{open_tok},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();

    while (switch (self.currToktype()) {
        close_tok => false,
        .Eof => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
        else => true,
    }) : (self.nextToken()) {
        const stmt = try self.parseStatement();
        errdefer stmt.deinit();
        try ctx.append(stmt);
    }

    if (!self.expect(.current, &.{close_tok})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{close_tok},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.doc_state.math_mode = false;

    return Stmt{ .MathCtx = .{
        .state = getMathStmtState(open_tok),
        .ctx = ctx,
    } };
}

fn parseTextInMath(self: *Self, comptime add_front_space: bool) ParseError!Stmt {
    var add_back_space = false;
    var inner = try ArrayList(Stmt).initCapacity(self.allocator, 20);
    errdefer {
        for (inner.items) |stmt| stmt.deinit();
        inner.deinit();
    }

    if (add_front_space) {
        if (!self.expect(.current, &.{.RawSharp})) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .TokenExpected = .{
                    .expected = &.{.RawSharp},
                    .obtained = self.currToktype(),
                } },
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        }
        self.nextToken();
    }
    if (!self.expect(.current, &.{.DoubleQuote})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.DoubleQuote},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();

    self.doc_state.math_mode = false;
    while (switch (self.currToktype()) {
        .DoubleQuote => false,
        .Eof => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
        else => true,
    }) : (self.nextToken()) {
        const stmt = try self.parseStatement();
        errdefer stmt.deinit();
        try inner.append(stmt);
    }
    self.doc_state.math_mode = true;

    if (self.expect(.peek, &.{.RawSharp})) {
        self.nextToken();
        add_back_space = true;
    }

    return Stmt{
        .PlainTextInMath = .{
            .add_front_space = add_front_space,
            .add_back_space = add_back_space,
            .inner = inner,
        },
    };
}

fn parseOpenDelimiter(self: *Self) ParseError!Stmt {
    if (!self.expect(.current, &.{.Question})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Question},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();

    return if (self.expect(.current, &.{
        .Lparen,
        .Lsqbrace,
        .Langle,
        .MathLbrace,
        .Vert,
        .Norm,
        .Rparen,
        .Rsqbrace,
        .Rangle,
        .MathRbrace,
        .Period,
    }))
        Stmt{
            .MathDelimiter = .{
                .delimiter = self.curr_tok.lit.in_math,
                .kind = .LeftBig,
            },
        }
    else
        Stmt{ .MathLit = "?" };
}
fn parseClosedDelimiter(self: *Self) ParseError!Stmt {
    const delimiter = self.curr_tok.lit.in_math;

    return if (self.expect(.peek, &.{.Question})) blk: {
        self.nextToken();
        break :blk Stmt{
            .MathDelimiter = .{
                .delimiter = delimiter,
                .kind = .RightBig,
            },
        };
    } else Stmt{
        .MathDelimiter = .{
            .delimiter = delimiter,
            .kind = .None,
        },
    };
}

fn parseBrace(self: *Self, comptime frac_enable: bool) ParseError!Stmt {
    const begin_location = self.curr_tok.span;
    if (!self.expect(.current, &.{.Lbrace})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Lbrace},
                .obtained = self.currToktype(),
            } },
            .span = begin_location,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();

    var is_fraction = false;
    var numerator = try ArrayList(Stmt).initCapacity(self.allocator, 10);
    errdefer {
        for (numerator.items) |stmt| stmt.deinit();
        numerator.deinit();
    }
    var denominator: ArrayList(Stmt) = if (frac_enable)
        try ArrayList(Stmt).initCapacity(self.allocator, 10)
    else
        undefined; // we do not use this part if `frac_enable` is false.
    errdefer {
        if (frac_enable) {
            for (denominator.items) |stmt| stmt.deinit();
            denominator.deinit();
        }
    }

    while (switch (self.currToktype()) {
        .Rbrace => false,
        .Eof => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = begin_location,
            } });
            return ParseError.ParseFailed;
        },
        else => true,
    }) : (self.nextToken()) {
        if (frac_enable and
            self.expect(.current, &.{.FracDefiner}) and self.doc_state.math_mode)
        {
            is_fraction = true;
            continue;
        }

        if (frac_enable and is_fraction) {
            const denominator_stmt = try self.parseStatement();
            errdefer denominator_stmt.deinit();
            try denominator.append(denominator_stmt);
        } else {
            const numerator_stmt = try self.parseStatement();
            errdefer numerator_stmt.deinit();
            try numerator.append(numerator_stmt);
        }
    }

    if (frac_enable and is_fraction) {
        return Stmt{
            .Fraction = .{
                .numerator = numerator,
                .denominator = denominator,
            },
        };
    } else {
        // As frac_enable is true, denominator is initialized. Also since
        // is_fraction is false, denominator is empty ArrayList.
        // So we should deallocate denominator only
        if (frac_enable) denominator.deinit();
        return Stmt{
            .Braced = .{ .inner = numerator },
        };
    }
}

// <return>[1] points <return>[0]
fn parseFilepathHelper(
    self: *Self,
    left_parn_loc: Span,
) ParseError!struct { ArrayList(u8), []const u8 } {
    var file_path_str = try ArrayList(u8).initCapacity(self.allocator, 30);
    errdefer file_path_str.deinit();

    var inside_config_dir = false;
    var parse_very_first_chr = false;

    while (true) {
        std.debug.assert(self.expect(.peek, &.{
            .{ .RawChar = .{ .start = 0, .end = 0, .chr = 0 } },
        }));
        const chr = self.peek_tok.toktype.RawChar.chr;
        const chr_str = self.peek_tok.lit.in_text;

        if (chr == ')') {
            break;
        } else if (chr_str.len == 1 and std.ascii.isWhitespace(chr_str[0])) {
            self.nextRawToken();
            continue;
        } else if (!parse_very_first_chr and chr == '@') {
            inside_config_dir = true;
            self.nextRawToken();

            if (self.peek_tok.toktype.RawChar.chr != '/') {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{
                        .IllegalUseErr = "The next token for `@` should be `/`",
                    },
                    .span = left_parn_loc,
                } });
                return ParseError.ParseFailed;
            }
            continue;
        } else if (chr == 0) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .IsNotClosed = .{
                    .open = &.{.Lparen},
                    .close = .Rparen,
                } },
                .span = left_parn_loc,
            } });
            return ParseError.ParseFailed;
        } else {
            @branchHint(.likely);
            try file_path_str.appendSlice(chr_str);
        }
        parse_very_first_chr = true;
        self.nextRawToken();
    }
    self.nextToken();

    const file_path_str_raw = try file_path_str.toOwnedSlice();
    defer self.allocator.free(file_path_str_raw);
    if (inside_config_dir) {
        const config_path = try getConfigPath(self.allocator);
        defer self.allocator.free(config_path);
        try file_path_str.writer().print(
            "{s}/{s}",
            .{ config_path, mem.trim(u8, file_path_str_raw, " \t") },
        );
    } else if (path.isAbsolute(file_path_str_raw)) {
        try file_path_str.writer().print(
            "{s}",
            .{mem.trim(u8, file_path_str_raw, " \t")},
        );
    } else {
        try file_path_str.writer().print(
            "./{s}",
            .{mem.trim(u8, file_path_str_raw, " \t")},
        );
    }

    return .{ file_path_str, fs.path.basename(file_path_str.items) };
}

// TODO: This special function is need because of following zig compiler bug:
// - https://github.com/ziglang/zig/issues/5973
// - https://github.com/ziglang/zig/issues/24324
// After these are resolved, remove this function
fn preventBug(s: *const volatile Span) void {
    _ = s;
}

fn parseFilepath(self: *Self) ParseError!Stmt {
    const import_file_loc = self.curr_tok.span;
    if (!self.expect(.current, &.{.GetFilePath})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.GetFilePath},
                .obtained = self.currToktype(),
            } },
            .span = import_file_loc,
        } });
        return ParseError.ParseFailed;
    }
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();

    while (self.expect(.current, &.{ .Space, .Tab }) and
        !self.expect(.peek, &.{ .Lparen, .Eof }))
    {
        self.nextToken();
    } else {
        self.nextRawToken();
    }

    if (!self.expect(.current, &.{.Lparen})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Lparen},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    const left_parn_loc = self.curr_tok.span;
    preventBug(&left_parn_loc);
    const file_name_str, _ = try self.parseFilepathHelper(left_parn_loc);
    defer file_name_str.deinit();

    const filepath_diff = path.relative(
        self.allocator,
        VESTI_LOCAL_DUMMY_DIR,
        file_name_str.items,
    ) catch {
        const io_diag = try diag.IODiagnostic.init(
            self.allocator,
            import_file_loc,
            "cannot get the relative path from {s} to {s}",
            .{
                VESTI_LOCAL_DUMMY_DIR,
                file_name_str.items,
            },
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return ParseError.ParseFailed;
    };
    errdefer self.allocator.free(filepath_diff);

    // why windows path separator is not a slash??
    return if (builtin.os.tag == .windows) blk: {
        const filepath_diff_win = try self.allocator.alloc(u8, filepath_diff.len);
        errdefer self.allocator.free(filepath_diff_win);
        _ = mem.replace(u8, filepath_diff, "\\", "/", filepath_diff_win);

        // we do not need filepath_diff anymore in here
        self.allocator.free(filepath_diff);
        break :blk Stmt{
            .FilePath = CowStr.fromOwnedStr(self.allocator, filepath_diff_win),
        };
    } else Stmt{
        .FilePath = CowStr.fromOwnedStr(self.allocator, filepath_diff),
    };
}

fn parseCopyFile(self: *Self) ParseError!Stmt {
    const import_file_loc = self.curr_tok.span;
    if (!self.expect(.current, &.{.CopyFile})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.CopyFile},
                .obtained = self.currToktype(),
            } },
            .span = import_file_loc,
        } });
        return ParseError.ParseFailed;
    }
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();

    while (self.expect(.current, &.{ .Space, .Tab }) and
        !self.expect(.peek, &.{ .Lparen, .Eof }))
    {
        self.nextToken();
    } else {
        self.nextRawToken();
    }

    if (!self.expect(.current, &.{.Lparen})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Lparen},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    const left_parn_loc = self.curr_tok.span;
    preventBug(&left_parn_loc);
    const file_name, const raw_filename = try self.parseFilepathHelper(left_parn_loc);
    defer file_name.deinit();

    var into_copy_filename = try ArrayList(u8).initCapacity(
        self.allocator,
        raw_filename.len + VESTI_LOCAL_DUMMY_DIR.len,
    );
    defer into_copy_filename.deinit();
    try into_copy_filename.writer().print("{s}/{s}", .{
        VESTI_LOCAL_DUMMY_DIR, raw_filename,
    });

    fs.cwd().copyFile(
        file_name.items,
        fs.cwd(),
        into_copy_filename.items,
        .{},
    ) catch {
        const io_diag = try diag.IODiagnostic.init(
            self.allocator,
            import_file_loc,
            "cannot copy from {s} into {s}",
            .{
                file_name.items,
                into_copy_filename.items,
            },
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return ParseError.ParseFailed;
    };

    return Stmt.NopStmt;
}

fn parseImportModule(self: *Self) ParseError!Stmt {
    const import_file_loc = self.curr_tok.span;
    if (!self.expect(.current, &.{.ImportModule})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.ImportModule},
                .obtained = self.currToktype(),
            } },
            .span = import_file_loc,
        } });
        return ParseError.ParseFailed;
    }
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();

    while (self.expect(.current, &.{ .Space, .Tab }) and
        !self.expect(.peek, &.{ .Lparen, .Eof }))
    {
        self.nextToken();
    } else {
        self.nextRawToken();
    }

    if (!self.expect(.current, &.{.Lparen})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Lparen},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    var mod_dir_path = try ArrayList(u8).initCapacity(self.allocator, 30);
    defer mod_dir_path.deinit();

    while (true) : (self.nextRawToken()) {
        std.debug.assert(self.expect(.peek, &.{
            .{ .RawChar = .{ .start = 0, .end = 0, .chr = 0 } },
        }));
        const chr = self.peek_tok.toktype.RawChar.chr;
        const chr_str = self.peek_tok.lit.in_text;

        if (chr == ')') {
            break;
        } else if (chr == 0) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        }
        try mod_dir_path.appendSlice(chr_str);
    }
    self.nextToken();

    const mod_dir_path_str = try mod_dir_path.toOwnedSlice();
    defer self.allocator.free(mod_dir_path_str);
    const config_path = try getConfigPath(self.allocator);
    defer self.allocator.free(config_path);

    try mod_dir_path.writer().print(
        "{s}/{s}",
        .{
            config_path,
            mem.trimLeft(u8, mem.trim(u8, mod_dir_path_str, " \t"), "/\\"),
        },
    );

    var mod_data_path = try ArrayList(u8).initCapacity(
        self.allocator,
        mod_dir_path.items.len + 15,
    );
    defer mod_data_path.deinit();
    try mod_data_path.writer().print("{s}/vesti.zon", .{mod_dir_path.items});

    var mod_zon_file = fs.cwd().openFile(mod_data_path.items, .{}) catch {
        const io_diag = try diag.IODiagnostic.init(
            self.allocator,
            import_file_loc,
            "cannot open file {s}",
            .{
                mod_data_path.items,
            },
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return ParseError.ParseFailed;
    };
    defer mod_zon_file.close();

    // what kind of such simple config file has 4MB size?
    const context = mod_zon_file.readToEndAllocOptions(
        self.allocator,
        4 * 1024 * 1024,
        null,
        @alignOf(u8),
        0,
    ) catch {
        const io_diag = try diag.IODiagnostic.init(
            self.allocator,
            import_file_loc,
            "cannot read context from {s}",
            .{
                mod_data_path.items,
            },
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return ParseError.ParseFailed;
    };
    defer self.allocator.free(context);
    const ves_module = try zon.parse.fromSlice(
        VestiModule,
        self.allocator,
        context,
        null,
        .{},
    );
    defer zon.parse.free(self.allocator, ves_module);

    for (ves_module.exports) |export_file| {
        var mod_filename = try ArrayList(u8).initCapacity(
            self.allocator,
            export_file.len + mod_dir_path.items.len,
        );
        defer mod_filename.deinit();
        try mod_filename.writer().print("{s}/{s}", .{
            mod_dir_path.items,
            export_file,
        });

        var into_copy_filename = try ArrayList(u8).initCapacity(
            self.allocator,
            export_file.len + VESTI_LOCAL_DUMMY_DIR.len,
        );
        defer into_copy_filename.deinit();
        try into_copy_filename.writer().print("{s}/{s}", .{
            VESTI_LOCAL_DUMMY_DIR, export_file,
        });

        fs.cwd().copyFile(
            mod_filename.items,
            fs.cwd(),
            into_copy_filename.items,
            .{},
        ) catch {
            const io_diag = try diag.IODiagnostic.init(
                self.allocator,
                import_file_loc,
                "cannot copy from {s} into {s}",
                .{
                    mod_filename.items,
                    into_copy_filename.items,
                },
            );
            self.diagnostic.initDiagInner(.{ .IOError = io_diag });
            return ParseError.ParseFailed;
        };
    }

    return Stmt.NopStmt;
}

fn parseImportVesti(self: *Self) ParseError!Stmt {
    const import_ves_loc = self.curr_tok.span;
    if (!self.expect(.current, &.{.ImportVesti})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.ImportVesti},
                .obtained = self.currToktype(),
            } },
            .span = import_ves_loc,
        } });
        return ParseError.ParseFailed;
    }
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();

    while (self.expect(.current, &.{ .Space, .Tab }) and
        !self.expect(.peek, &.{ .Lparen, .Eof }))
    {
        self.nextToken();
    } else {
        self.nextRawToken();
    }

    if (!self.expect(.current, &.{.Lparen})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Lparen},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    var file_path_str = try ArrayList(u8).initCapacity(self.allocator, 30);
    defer file_path_str.deinit();

    while (true) : (self.nextRawToken()) {
        std.debug.assert(self.expect(.peek, &.{
            .{ .RawChar = .{ .start = 0, .end = 0, .chr = 0 } },
        }));
        const chr = self.peek_tok.toktype.RawChar.chr;
        const chr_str = self.peek_tok.lit.in_text;

        if (chr == ')') {
            break;
        } else if (chr == 0) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = import_ves_loc,
            } });
            return ParseError.ParseFailed;
        }
        try file_path_str.appendSlice(chr_str);
    }
    self.nextToken();

    const real_filepath = self.file_dir.realpathAlloc(
        self.allocator,
        file_path_str.items,
    ) catch {
        const io_diag = try diag.IODiagnostic.init(
            self.allocator,
            import_ves_loc,
            "cannot obtain absolute path for {s}",
            .{
                file_path_str.items,
            },
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return ParseError.ParseFailed;
    };
    defer self.allocator.free(real_filepath);
    const filename = try vestiNameMangle(self.allocator, real_filepath);
    errdefer self.allocator.free(filename);

    return Stmt{ .ImportVesti = filename };
}

fn parseEnvironment(self: *Self, comptime is_real: bool) ParseError!Stmt {
    const begenv_location = self.curr_tok.span;
    const begin_env_tok: TokenType = if (is_real) .Useenv else .Begenv;

    var off_math_state = false;
    var add_newline = false;

    if (!self.expect(.current, &.{begin_env_tok})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{begin_env_tok},
                .obtained = self.currToktype(),
            } },
            .span = begenv_location,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();
    if (!is_real and self.expect(.current, &.{.Star})) {
        self.nextToken();
        add_newline = true;
    }
    self.eatWhitespaces(false);

    var name = blk: {
        const tmp = switch (self.currToktype()) {
            .Text => self.curr_tok.lit.in_text,
            .Eof => {
                if (is_real) {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{ .NameMissErr = .Useenv },
                        .span = begenv_location,
                    } });
                    return ParseError.ParseFailed;
                } else {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .EofErr,
                        .span = begenv_location,
                    } });
                    return ParseError.ParseFailed;
                }
            },
            else => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .NameMissErr = begin_env_tok },
                    .span = begenv_location,
                } });
                return ParseError.ParseFailed;
            },
        };
        break :blk try CowStr.init(.Owned, .{ self.allocator, tmp });
    };
    errdefer name.deinit();
    self.nextToken();

    if (ENV_MATH_IDENT.has(name.Owned.items)) {
        self.doc_state.math_mode = true;
        off_math_state = true;
    }

    while (self.expect(.current, &.{.Star})) : (self.nextToken()) {
        try name.append(self.allocator, "*");
    }
    self.eatWhitespaces(false);

    const args = try self.parseFunctionArgs(
        .Lparen,
        .Rparen,
        .Lsqbrace,
        .Rsqbrace,
    );
    errdefer args.deinit();

    if (!is_real) {
        if (off_math_state) {
            self.doc_state.math_mode = false;
        }

        if (!self.expect(.peek, &.{ .Newline, .Eof })) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .TokenExpected = .{
                    .expected = &.{ .Newline, .Eof },
                    .obtained = self.peekToktype(),
                } },
                .span = self.peek_tok.span,
            } });
            return ParseError.ParseFailed;
        }

        return Stmt{ .BeginPhantomEnviron = .{
            .name = name,
            .args = args,
            .add_newline = add_newline,
        } };
    }

    if (args.items.len > 0) {
        if (!self.expect(.current, &.{.Rparen}) and
            !self.expect(.current, &.{.Rsqbrace}))
        {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .TokenExpected = .{
                    .expected = &.{ .Rparen, .Rsqbrace },
                    .obtained = self.currToktype(),
                } },
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        }
        self.nextToken();
        self.eatWhitespaces(false);
    }

    if (!self.expect(.current, &.{.Lbrace})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Lbrace},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    var inner = try self.parseBrace(false);
    errdefer inner.deinit();

    if (off_math_state) {
        self.doc_state.math_mode = false;
    }

    return Stmt{ .Environment = .{
        .name = name,
        .args = args,
        .inner = inner.Braced.inner,
    } };
}

fn parseEndPhantomEnvironment(self: *Self) ParseError!Stmt {
    const endenv_location = self.curr_tok.span;
    if (!self.expect(.current, &.{.Endenv})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Endenv},
                .obtained = self.currToktype(),
            } },
            .span = endenv_location,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();
    self.eatWhitespaces(false);

    var name = blk: {
        const tmp = switch (self.currToktype()) {
            .Text => self.curr_tok.lit.in_text,
            .Eof => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .EofErr,
                    .span = endenv_location,
                } });
                return ParseError.ParseFailed;
            },
            else => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .NameMissErr = .Endenv },
                    .span = endenv_location,
                } });
                return ParseError.ParseFailed;
            },
        };
        break :blk try CowStr.init(.Owned, .{ self.allocator, tmp });
    };
    errdefer name.deinit();
    self.nextToken();

    while (self.expect(.current, &.{.Star})) : (self.nextToken()) {
        try name.append(self.allocator, "*");
    }
    self.eatWhitespaces(false);

    if (!self.expect(.current, &.{ .Newline, .Eof })) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{ .Newline, .Eof },
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    return Stmt{ .EndPhantomEnviron = name };
}

fn parseLuaCode(self: *Self) ParseError!Stmt {
    const codeblock_loc = self.curr_tok.span;
    if (!self.expect(.current, &.{.LuaCode})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.LuaCode},
                .obtained = self.currToktype(),
            } },
            .span = codeblock_loc,
        } });
        return ParseError.ParseFailed;
    }
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();

    while (self.expect(.current, &.{ .Space, .Tab }) and
        !self.expect(.peek, &.{ .Lbrace, .Eof }))
    {
        self.nextToken();
    } else {
        self.nextRawToken();
    }

    if (!self.expect(.current, &.{.Lbrace})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Lbrace},
                .obtained = self.currToktype(),
            } },
            .span = codeblock_loc,
        } });
        return ParseError.ParseFailed;
    }

    std.debug.assert(self.expect(.peek, &.{
        .{ .RawChar = .{ .start = 0, .end = 0, .chr = 0 } },
    }));
    const start = self.peek_tok.toktype.RawChar.start;

    var bracket_open: usize = 0;
    var is_escaped = false;
    var pass_counting_bracket = false;
    var maybe_multiline_string = false;
    while (true) : (self.nextRawToken()) {
        std.debug.assert(self.expect(.peek, &.{
            .{ .RawChar = .{ .start = 0, .end = 0, .chr = 0 } },
        }));
        const chr = self.peek_tok.toktype.RawChar.chr;

        switch (chr) {
            '{' => if (!pass_counting_bracket) {
                bracket_open += 1;
            },
            '}' => {
                if (!pass_counting_bracket) {
                    if (bracket_open == 0) break;
                    bracket_open -= 1;
                }
            },
            '[' => {
                if (maybe_multiline_string) {
                    pass_counting_bracket = true;
                    maybe_multiline_string = false;
                } else if (!is_escaped) {
                    maybe_multiline_string = true;
                }
            },
            ']' => {
                if (maybe_multiline_string) {
                    pass_counting_bracket = false;
                    maybe_multiline_string = false;
                } else if (!is_escaped) {
                    maybe_multiline_string = true;
                }
            },
            '=' => if (maybe_multiline_string) {
                maybe_multiline_string = true;
            },
            '\\' => is_escaped = true,
            '\'', '"' => {
                if (!is_escaped) {
                    pass_counting_bracket = !pass_counting_bracket;
                }
                is_escaped = false;
            },
            0 => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .EofErr,
                    .span = codeblock_loc,
                } });
                return ParseError.ParseFailed;
            },
            else => {
                is_escaped = false;
                if (maybe_multiline_string) maybe_multiline_string = false;
            },
        }
    }
    const end = self.peek_tok.toktype.RawChar.start;
    self.nextToken();

    var code_import: ?ArrayList([]const u8) = null;
    errdefer {
        if (code_import) |imports| imports.deinit();
    }
    if (self.expect(.peek, &.{.Lsqbrace})) {
        code_import = try ArrayList([]const u8).initCapacity(
            self.allocator,
            10,
        );

        self.nextToken(); // skip '}' token
        self.nextToken(); // skip '[' token

        while (true) : (self.nextToken()) {
            self.eatWhitespaces(true);
            if (self.expect(.current, &.{.Rsqbrace})) break;
            if (!self.expect(.current, &.{.Text})) {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .TokenExpected = .{
                        .expected = &.{.Text},
                        .obtained = self.currToktype(),
                    } },
                    .span = self.curr_tok.span,
                } });
                return ParseError.ParseFailed;
            }

            try code_import.?.append(self.curr_tok.lit.in_text);
            self.nextToken();
            self.eatWhitespaces(true);

            switch (self.currToktype()) {
                .Comma => continue,
                .Rsqbrace => break,
                else => {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{ .TokenExpected = .{
                            .expected = &.{ .Comma, .Rsqbrace },
                            .obtained = self.currToktype(),
                        } },
                        .span = self.curr_tok.span,
                    } });
                    return ParseError.ParseFailed;
                },
            }
        }
    }

    var code_export: ?[]const u8 = null;
    if (self.expect(.peek, &.{.Less})) {
        self.nextToken(); // skip '}' or ']' token

        const codeblock_tag_loc = self.curr_tok.span;
        self.nextToken(); // skip '<' token

        if (!self.expect(.current, &.{.Text})) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .TokenExpected = .{
                    .expected = &.{.Text},
                    .obtained = self.currToktype(),
                } },
                .span = codeblock_tag_loc,
            } });
            return ParseError.ParseFailed;
        }
        code_export = self.curr_tok.lit.in_text;
        self.nextToken();

        if (!self.expect(.current, &.{.Great})) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .TokenExpected = .{
                    .expected = &.{.Great},
                    .obtained = self.currToktype(),
                } },
                .span = codeblock_tag_loc,
            } });
            return ParseError.ParseFailed;
        }
    }

    return Stmt{
        .LuaCode = .{
            .code_span = codeblock_loc,
            .code_import = code_import,
            .code_export = code_export,
            .code = self.lexer.source[start..end],
        },
    };
}

fn parseMathMode(self: *Self) ParseError!Stmt {
    const mathmode_block_loc = self.curr_tok.span;
    if (!self.expect(.current, &.{.MathMode})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.MathMode},
                .obtained = self.currToktype(),
            } },
            .span = mathmode_block_loc,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();
    self.eatWhitespaces(false);

    if (!self.expect(.current, &.{.Lbrace})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Lbrace},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.doc_state.math_mode = true;
    var inner = try self.parseBrace(false);
    errdefer inner.deinit();
    self.doc_state.math_mode = false;

    inner.Braced.unwrap_brace = true;
    return inner;
}

fn parseFunctionArgs(
    self: *Self,
    comptime open: TokenType,
    comptime closed: TokenType,
    comptime optional_open: TokenType,
    comptime optional_closed: TokenType,
) ParseError!ArrayList(ast.Arg) {
    var args = try ArrayList(ast.Arg).initCapacity(self.allocator, 10);
    errdefer {
        for (args.items) |arg| arg.deinit();
        args.deinit();
    }

    if (self.expect(.current, &.{ open, optional_open, .Star })) {
        while (true) : (self.nextToken()) {
            switch (self.currToktype()) {
                open => try self.parseFunctionArgsCore(
                    &args,
                    open,
                    closed,
                    .MainArg,
                ),
                optional_open => try self.parseFunctionArgsCore(
                    &args,
                    optional_open,
                    optional_closed,
                    .Optional,
                ),
                .Star => {
                    try args.append(.{
                        .needed = .StarArg,
                        .ctx = ArrayList(Stmt).init(self.allocator),
                    });
                },
                else => unreachable,
            }

            if (!self.expect(.peek, &.{ open, optional_open, .Star })) break;
        }
    }

    return args;
}

fn parseFunctionArgsCore(
    self: *Self,
    args: *ArrayList(ast.Arg),
    comptime open: TokenType,
    comptime closed: TokenType,
    arg_need: ast.ArgNeed,
) ParseError!void {
    const open_brace_location = self.curr_tok.span;
    if (!self.expect(.current, &.{open})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{open},
                .obtained = self.currToktype(),
            } },
            .span = open_brace_location,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();

    var tmp = try ArrayList(Stmt).initCapacity(self.allocator, 20);
    errdefer {
        for (tmp.items) |stmt| stmt.deinit();
        tmp.deinit();
    }

    while (switch (self.currToktype()) {
        closed => false,
        .Eof => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = open_brace_location,
            } });
            return ParseError.ParseFailed;
        },
        else => true,
    }) : (self.nextToken()) {
        const stmt = try self.parseStatement();
        errdefer stmt.deinit();
        try tmp.append(stmt);
    }

    if (!self.expect(.current, &.{closed})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{closed},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    try args.append(.{ .needed = arg_need, .ctx = tmp });
}

fn getConfigPath(allocator: Allocator) ParseError![]const u8 {
    var output = try ArrayList(u8).initCapacity(allocator, 30);
    errdefer output.deinit();

    switch (builtin.os.tag) {
        .linux, .macos => {
            try output.appendSlice(std.posix.getenv("HOME").?);
            try output.appendSlice("/.config/vesti");
        },
        .windows => {
            const appdata_location = try process.getEnvVarOwned(
                allocator,
                "APPDATA",
            );
            defer allocator.free(appdata_location);
            try output.appendSlice(appdata_location);
            try output.appendSlice("\\vesti");
        },
        else => @compileError("only linux, macos and windows are supported"),
    }

    return try output.toOwnedSlice();
}

test "test vesti parser" {
    _ = @import("./tests/docclass.zig");
    _ = @import("./tests/importpkg.zig");
    _ = @import("./tests/math_stmts.zig");
    _ = @import("./tests/environments.zig");
}

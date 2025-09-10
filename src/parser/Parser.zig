const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ast = @import("ast.zig");
const diag = @import("../diagnostic.zig");
const fs = std.fs;
const mem = std.mem;
const path = fs.path;
const process = std.process;
const unicode = std.unicode;
const ziglyph = @import("ziglyph");
const zon = std.zon;

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

const assert = std.debug.assert;
const getConfigPath = @import("../config.zig").getConfigPath;
const vestiNameMangle = @import("../Compile.zig").vestiNameMangle;

const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;

allocator: Allocator,
lexer: Lexer,
curr_tok: Token,
peek_tok: Token,
doc_state: DocState,
diagnostic: *diag.Diagnostic,
file_dir: *fs.Dir,
allow_pycode: bool,
engine: ?*LatexEngine,

const Self = @This();

pub const LatexEngine = enum(u8) { // it also uses in c
    latex,
    pdflatex,
    xelatex,
    lualatex,
    tectonic,

    pub fn toStr(self: @This()) []const u8 {
        return switch (self) {
            .latex => "latex",
            .pdflatex => "pdflatex",
            .xelatex => "xelatex",
            .lualatex => "lualatex",
            .tectonic => "tectonic",
        };
    }
};

const ENV_MATH_IDENT = std.StaticStringMap(void).initComptime(.{
    .{"equation"},
    .{"align"},
    .{"array"},
    .{"eqnarray"},
    .{"gather"},
    .{"multline"},
});
const COMPILE_TYPE = std.StaticStringMap(LatexEngine).initComptime(.{
    .{ "plain", LatexEngine.latex },
    .{ "pdf", LatexEngine.pdflatex },
    .{ "xe", LatexEngine.xelatex },
    .{ "lua", LatexEngine.lualatex },
    .{ "tect", LatexEngine.tectonic },
});

pub const ParseError = Allocator.Error ||
    process.GetEnvVarOwnedError ||
    Io.Writer.Error ||
    error{ CodepointTooLarge, Utf8CannotEncodeSurrogateHalf } ||
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
    allow_pycode: bool,
    engine: ?*LatexEngine,
) !Self {
    var self: Self = undefined;

    self.allocator = allocator;
    self.lexer = try Lexer.init(source);
    self.curr_tok = self.lexer.next();
    self.peek_tok = self.lexer.next();
    self.doc_state = DocState{};
    self.diagnostic = diagnostic;
    self.file_dir = file_dir;
    self.allow_pycode = allow_pycode;
    self.engine = engine;

    return self;
}

pub fn parse(self: *Self) ParseError!ArrayList(Stmt) {
    var stmts = try ArrayList(Stmt).initCapacity(self.allocator, 100);
    errdefer {
        for (stmts.items) |*stmt| stmt.deinit(self.allocator);
        stmts.deinit(self.allocator);
    }

    // lexer.lex_finished means that peek_tok is the "last" token from lexer
    while (!self.lexer.lex_finished) : (self.nextToken()) {
        var stmt = try self.parseStatement();
        errdefer stmt.deinit(self.allocator);
        try stmts.append(self.allocator, stmt);
    } else {
        // so we need one more step to exhaust peek_tok
        var stmt = try self.parseStatement();
        errdefer stmt.deinit(self.allocator);
        try stmts.append(self.allocator, stmt);
        if (self.doc_state.doc_start and !self.doc_state.prevent_end_doc)
            try stmts.append(self.allocator, Stmt.DocumentEnd);
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
        .DefineFunction => try self.parseDefineFunction(),
        // TODO: implement `defenv`
        .DefineEnv => {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{
                    .VestiInternal = "`defenv` is not implemented yet",
                },
                .span = self.curr_tok.span,
            } });
            return ParseError.ParseFailed;
        },
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
        .CompileType => try self.parseCompileType(),
        .PyCode => if (self.allow_pycode)
            try self.parsePyCode()
        else {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .DisallowPycode,
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
        .FntParam => self.parseDefunParam(),
        else => self.parseLiteral(),
    };
}

fn parseLiteral(self: *Self) Stmt {
    return if (self.doc_state.math_mode)
        Stmt{ .MathLit = self.curr_tok.lit.in_math }
    else
        Stmt{ .TextLit = self.curr_tok.lit.in_text };
}

// this special statement is needed when parsing the body of `defun` to exchange
// its name into appropriate latex's one
fn parseDefunParam(self: *Self) Stmt {
    return Stmt{ .DefunParamLit = .{
        .span = self.curr_tok.span,
        .value = CowStr.init(.Borrowed, .{self.curr_tok.lit.in_text}),
    } };
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

    var name = try self.takeName();
    errdefer name.deinit(self.allocator);
    self.eatWhitespaces(false);

    var options = switch (self.currToktype()) {
        .Eof, .Newline => null,
        else => try self.parseOptions(),
    };
    errdefer {
        if (options) |*options_| {
            for (options_.items) |*option| option.deinit(self.allocator);
            options_.deinit(self.allocator);
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

    var name = try self.takeName();
    errdefer name.deinit(self.allocator);
    self.eatWhitespaces(false);

    var options = switch (self.currToktype()) {
        .Lparen => try self.parseOptions(),
        else => null,
    };
    errdefer {
        if (options) |*options_| {
            for (options_.items) |*option| option.deinit(self.allocator);
            options_.deinit(self.allocator);
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
        for (output.items) |*pkg| pkg.deinit(self.allocator);
        output.deinit(self.allocator);
    }

    var name = CowStr.init(.Empty, .{});
    errdefer name.deinit(self.allocator);
    var options: ?ArrayList(CowStr) = null;
    errdefer {
        if (options) |*o| {
            for (o.items) |*s| s.deinit(self.allocator);
            o.deinit(self.allocator);
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
                try output.append(self.allocator, .{
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
        for (output.items) |*expr| expr.deinit(self.allocator);
        output.deinit(self.allocator);
    }

    var tmp = CowStr.init(.Empty, .{});
    errdefer tmp.deinit(self.allocator);

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
                    try output.append(self.allocator, tmp);
                    tmp = CowStr.init(.Empty, .{});
                }
            },
            .Space, .Tab, .Newline => continue,
            else => try tmp.append(self.allocator, self.curr_tok.lit.in_text),
        }
    } else {
        if (tmp != .Empty) {
            try output.append(self.allocator, tmp);
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
    errdefer output.deinit(self.allocator);
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
        for (ctx.items) |*stmt| stmt.deinit(self.allocator);
        ctx.deinit(self.allocator);
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
        var stmt = try self.parseStatement();
        errdefer stmt.deinit(self.allocator);
        try ctx.append(self.allocator, stmt);
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
        .inner = ctx,
    } };
}

fn parseTextInMath(self: *Self, comptime add_front_space: bool) ParseError!Stmt {
    var add_back_space = false;
    var inner = try ArrayList(Stmt).initCapacity(self.allocator, 20);
    errdefer {
        for (inner.items) |*stmt| stmt.deinit(self.allocator);
        inner.deinit(self.allocator);
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
        var stmt = try self.parseStatement();
        errdefer stmt.deinit(self.allocator);
        try inner.append(self.allocator, stmt);
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
        for (numerator.items) |*stmt| stmt.deinit(self.allocator);
        numerator.deinit(self.allocator);
    }
    var denominator: ArrayList(Stmt) = if (frac_enable)
        try ArrayList(Stmt).initCapacity(self.allocator, 10)
    else
        undefined; // we do not use this part if `frac_enable` is false.
    errdefer {
        if (frac_enable) {
            for (denominator.items) |*stmt| stmt.deinit(self.allocator);
            denominator.deinit(self.allocator);
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
            var denominator_stmt = try self.parseStatement();
            errdefer denominator_stmt.deinit(self.allocator);
            try denominator.append(self.allocator, denominator_stmt);
        } else {
            var numerator_stmt = try self.parseStatement();
            errdefer numerator_stmt.deinit(self.allocator);
            try numerator.append(self.allocator, numerator_stmt);
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
        if (frac_enable) denominator.deinit(self.allocator);
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
    errdefer file_path_str.deinit(self.allocator);

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
            try file_path_str.appendSlice(self.allocator, chr_str);
        }
        parse_very_first_chr = true;
        self.nextRawToken();
    }
    self.nextToken();

    const file_path_str_raw = try file_path_str.toOwnedSlice(self.allocator);
    defer self.allocator.free(file_path_str_raw);
    if (inside_config_dir) {
        const config_path = try getConfigPath(self.allocator);
        defer self.allocator.free(config_path);
        try file_path_str.print(
            self.allocator,
            "{s}/{s}",
            .{ config_path, mem.trim(u8, file_path_str_raw, " \t") },
        );
    } else if (path.isAbsolute(file_path_str_raw)) {
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

    return .{ file_path_str, fs.path.basename(file_path_str.items) };
}

// TODO: This special function is needed because of following zig compiler bug:
// - https://github.com/ziglang/zig/issues/5973
// - https://github.com/ziglang/zig/issues/24324 [closed]
// After these are resolved, remove this function
inline fn preventBug(s: *const volatile Span) void {
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
    var file_name_str, _ = try self.parseFilepathHelper(left_parn_loc);
    defer file_name_str.deinit(self.allocator);

    const filepath_diff = path.relative(
        self.allocator,
        VESTI_DUMMY_DIR,
        file_name_str.items,
    ) catch {
        const io_diag = try diag.IODiagnostic.init(
            self.allocator,
            import_file_loc,
            "cannot get the relative path from {s} to {s}",
            .{
                VESTI_DUMMY_DIR,
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
            .FilePath = .fromOwnedSlice(filepath_diff_win),
        };
    } else Stmt{
        .FilePath = .fromOwnedSlice(filepath_diff),
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
    var file_name, const raw_filename = try self.parseFilepathHelper(left_parn_loc);
    defer file_name.deinit(self.allocator);

    var into_copy_filename = try ArrayList(u8).initCapacity(
        self.allocator,
        raw_filename.len + VESTI_DUMMY_DIR.len,
    );
    defer into_copy_filename.deinit(self.allocator);
    try into_copy_filename.print(self.allocator, "{s}/{s}", .{
        VESTI_DUMMY_DIR, raw_filename,
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
    defer mod_dir_path.deinit(self.allocator);

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
        try mod_dir_path.appendSlice(self.allocator, chr_str);
    }
    self.nextToken();

    const mod_dir_path_str = try mod_dir_path.toOwnedSlice(self.allocator);
    defer self.allocator.free(mod_dir_path_str);
    const config_path = try getConfigPath(self.allocator);
    defer self.allocator.free(config_path);

    try mod_dir_path.print(
        self.allocator,
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
    defer mod_data_path.deinit(self.allocator);
    try mod_data_path.print(self.allocator, "{s}/vesti.zon", .{mod_dir_path.items});

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

    var buf: [1024]u8 = undefined;
    var mod_zon_file_reader = mod_zon_file.reader(&buf);

    // what kind of such simple config file has 4MB size?
    const context = mod_zon_file_reader.interface.allocRemainingAlignedSentinel(
        self.allocator,
        .limited(4 * 1024 * 1024),
        .of(u8),
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
    const ves_module = try zon.parse.fromSliceAlloc(
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
        defer mod_filename.deinit(self.allocator);
        try mod_filename.print(
            self.allocator,
            "{s}/{s}",
            .{ mod_dir_path.items, export_file },
        );

        var into_copy_filename = try ArrayList(u8).initCapacity(
            self.allocator,
            export_file.len + VESTI_DUMMY_DIR.len,
        );
        defer into_copy_filename.deinit(self.allocator);
        try into_copy_filename.print(
            self.allocator,
            "{s}/{s}",
            .{ VESTI_DUMMY_DIR, export_file },
        );

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
    defer file_path_str.deinit(self.allocator);

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
        try file_path_str.appendSlice(self.allocator, chr_str);
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
    errdefer name.deinit(self.allocator);
    self.nextToken();

    if (ENV_MATH_IDENT.has(name.Owned.items)) {
        self.doc_state.math_mode = true;
        off_math_state = true;
    }

    while (self.expect(.current, &.{.Star})) : (self.nextToken()) {
        try name.append(self.allocator, "*");
    }
    self.eatWhitespaces(false);

    var args = try self.parseFunctionArgs(
        .Lparen,
        .Rparen,
        .Lsqbrace,
        .Rsqbrace,
    );
    errdefer args.deinit(self.allocator);

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
        self.eatWhitespaces(true);
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
    errdefer name.deinit(self.allocator);
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

// TODO: support nested defun with single sharp parameters
fn parseDefineFunction(self: *Self) ParseError!Stmt {
    const defun_location = self.curr_tok.span;
    var defun_kind: ast.DefunKind = .{};

    if (!self.expect(.current, &.{.DefineFunction})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.DefineFunction},
                .obtained = self.currToktype(),
            } },
            .span = defun_location,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();
    self.eatWhitespaces(false);

    // parsing defun attributes
    if (self.expect(.current, &.{.Lsqbrace})) {
        const kind_brace_location = self.curr_tok.span;
        self.nextToken();
        const kind_location = self.curr_tok.span;
        const kind_str = switch (self.currToktype()) {
            .Text => self.curr_tok.lit.in_text,
            .Eof => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .EofErr,
                    .span = kind_location,
                } });
                return ParseError.ParseFailed;
            },
            else => |toktype| {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .TokenExpected = .{
                        .expected = &.{.Text},
                        .obtained = toktype,
                    } },
                    .span = kind_location,
                } });
                return ParseError.ParseFailed;
            },
        };
        self.nextToken();

        if (!defun_kind.parseDefunKind(kind_str)) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .InvalidDefunKind = kind_str },
                .span = kind_location,
            } });
            return ParseError.ParseFailed;
        }

        if (!self.expect(.current, &.{.Rsqbrace})) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .TokenExpected = .{
                    .expected = &.{.Rsqbrace},
                    .obtained = self.currToktype(),
                } },
                .span = kind_brace_location,
            } });
            return ParseError.ParseFailed;
        }
        self.nextToken();
    }
    self.eatWhitespaces(false);

    const name = blk: {
        const tmp = switch (self.currToktype()) {
            .Text => self.curr_tok.lit.in_text,
            .Eof => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .EofErr,
                    .span = defun_location,
                } });
                return ParseError.ParseFailed;
            },
            else => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .NameMissErr = .DefineFunction },
                    .span = defun_location,
                } });
                return ParseError.ParseFailed;
            },
        };
        break :blk try CowStr.init(.Owned, .{ self.allocator, tmp });
    };
    self.nextToken();
    self.eatWhitespaces(false);

    var out_stmt = Stmt{ .DefineFunction = .{
        .name = name,
        .kind = defun_kind,
        .inner = .empty,
    } };
    errdefer out_stmt.deinit(self.allocator); // this deallocates `name`

    // parsing defun parameter string
    if (self.expect(.current, &.{.Lparen})) {
        self.nextToken(); // eat `(`

        var param_toks = try ArrayList(Token).initCapacity(self.allocator, 20);
        defer param_toks.deinit(self.allocator);
        var param_str = Io.Writer.Allocating.init(self.allocator);
        defer param_str.deinit();

        while (!self.expect(.current, &.{ .Rparen, .Eof })) : (self.nextToken()) {
            try param_toks.append(self.allocator, self.curr_tok);
        } else if (self.expect(.current, &.{.Eof})) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = defun_location,
            } });
            return ParseError.ParseFailed;
        }
        assert(self.expect(.current, &.{.Rparen}));

        var param_idx: usize = 0;
        for (param_toks.items) |param_tok| {
            switch (param_tok.toktype) {
                .FntParam => if (param_idx >= 9) {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .DefunParamOverflow,
                        .span = defun_location,
                    } });
                    return ParseError.ParseFailed;
                } else {
                    @branchHint(.likely);
                    out_stmt.DefineFunction.params[param_idx] = CowStr.init(
                        .Borrowed,
                        .{param_tok.lit.in_text},
                    );
                    // latex parameter start from 1
                    try param_str.writer.print("#{d}", .{param_idx + 1});
                    param_idx += 1;
                },
                // treat every tokens inside param_str as a text
                else => try param_str.writer.writeAll(param_tok.lit.in_text),
            }
        }

        out_stmt.DefineFunction.param_str = .fromOwnedSlice(try param_str.toOwnedSlice());
        self.nextToken(); // eat `)`
    }
    self.eatWhitespaces(true);

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

    const body_location = self.curr_tok.span;
    var inner = try self.parseBrace(false);
    errdefer inner.deinit(self.allocator);

    // change each defun params to corresponding value
    try changeDefunParamName(
        self.allocator,
        self.diagnostic,
        inner.Braced.inner.items,
        &out_stmt.DefineFunction.params,
        body_location,
    );

    out_stmt.DefineFunction.inner = inner.Braced.inner;
    return out_stmt;
}

fn changeDefunParamName(
    allocator: Allocator,
    diagnostic: *diag.Diagnostic,
    stmts: []Stmt,
    params_table: *const [9]CowStr,
    span: Span,
) !void {
    for (stmts) |*stmt| {
        switch (stmt.*) {
            .DefunParamLit => |*val| {
                for (params_table, 1..) |param, idx| {
                    if (mem.eql(u8, param.toStr(), val.value.toStr())) {
                        val.value.deinit(allocator);
                        val.value = try .initPrint(allocator, "#{d}", .{idx});
                        break;
                    }
                } else {
                    const value = try allocator.dupe(u8, val.value.toStr());
                    errdefer allocator.free(value);

                    diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{
                            .InvalidDefunParam = .fromOwnedSlice(value),
                        },
                        .span = span,
                    } });
                    return ParseError.ParseFailed;
                }
            },
            inline .MathCtx,
            .Braced,
            .PlainTextInMath,
            => |*val| try changeDefunParamName(
                allocator,
                diagnostic,
                val.inner.items,
                params_table,
                span,
            ),
            .Fraction => |*val| {
                try changeDefunParamName(
                    allocator,
                    diagnostic,
                    val.numerator.items,
                    params_table,
                    span,
                );
                try changeDefunParamName(
                    allocator,
                    diagnostic,
                    val.denominator.items,
                    params_table,
                    span,
                );
            },
            .Environment => {
                diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .EnvInsideDefun,
                    .span = span,
                } });
                return ParseError.ParseFailed;
            },
            .DefineFunction => {
                diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .VestiInternal = 
                    \\nested `defun` not supported yet.
                    \\This is not a bug at this moment
                },
                    .span = span,
                } });
                return ParseError.ParseFailed;
            },
            else => {},
        }
    }
}

fn parsePyCode(self: *Self) ParseError!Stmt {
    const codeblock_loc = self.curr_tok.span;
    if (!self.expect(.current, &.{.PyCode})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.PyCode},
                .obtained = self.currToktype(),
            } },
            .span = codeblock_loc,
        } });
        return ParseError.ParseFailed;
    }
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();

    while (self.expect(.current, &.{ .Space, .Tab }) and
        !self.expect(.peek, &.{ .Text, .Eof }))
    {
        self.nextToken();
    } else {
        self.nextRawToken();
    }

    if (!self.expect(.current, &.{.Text})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Text},
                .obtained = self.currToktype(),
            } },
            .span = codeblock_loc,
        } });
        return ParseError.ParseFailed;
    }

    // check that peek tokentype is RawChar
    std.debug.assert(self.expect(.peek, &.{.{ .RawChar = .{} }}));

    // code_export text also works as a <BRACKET> of the pycode block
    const code_export = self.curr_tok.lit.in_text;
    const start = self.peekToktype().RawChar.start;

    var end_text = try ArrayList(u8).initCapacity(self.allocator, code_export.len);
    var buf: [4]u8 = @splat(0);
    defer end_text.deinit(self.allocator);
    while (true) : (self.nextRawToken()) {
        if (self.expect(.peek, &.{.Eof})) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = codeblock_loc,
            } });
            return ParseError.ParseFailed;
        }

        // check that peek tokentype is RawChar
        std.debug.assert(self.expect(.peek, &.{.{ .RawChar = .{} }}));
        const chr = self.peekToktype().RawChar.chr;

        if (!ziglyph.isAlphabetic(chr) and !ziglyph.isDecimal(chr)) {
            end_text.clearRetainingCapacity();
            continue;
        }

        if (end_text.items.len == 0 and ziglyph.isDecimal(chr)) continue;

        const len = try unicode.utf8Encode(chr, &buf);
        try end_text.appendSlice(self.allocator, buf[0..len]);

        if (mem.eql(u8, code_export, end_text.items)) break;
    }
    const end = self.peek_tok.toktype.RawChar.end -| end_text.items.len;
    self.nextToken();
    if (!self.expect(.peek, &.{ .Space, .Newline, .Eof })) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{ .Space, .Newline, .Eof },
                .obtained = self.peekToktype(),
            } },
            .span = self.peek_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    while (self.peekToktype() == .Space) {
        self.nextToken();
    }

    var pycode = try ArrayList(u8).initCapacity(self.allocator, 50);
    errdefer pycode.deinit(self.allocator);
    var it = mem.tokenizeScalar(u8, self.lexer.source[start..end], '\n');

    // TODO: At this moment, both `//` and `\\` are allowed to start pycode
    // line. Later, I will choose either of them which fits more
    while (it.next()) |line| {
        const pos = mem.indexOfAny(u8, line, "/\\") orelse {
            const trim_line = mem.trim(u8, line, " \t\r\n");
            if (trim_line.len == 0) continue else {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .InvalidPycode,
                    .span = codeblock_loc,
                } });
                return ParseError.ParseFailed;
            }
        };
        if (!mem.eql(u8, line[pos .. pos + 2], "//") and
            !mem.eql(u8, line[pos .. pos + 2], "\\\\"))
        {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .InvalidPycode,
                .span = codeblock_loc,
            } });
            return ParseError.ParseFailed;
        }
        if (pos + 2 >= line.len) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .InvalidPycode,
                .span = codeblock_loc,
            } });
            return ParseError.ParseFailed;
        }
        try pycode.appendSlice(self.allocator, line[pos + 2 ..]);
        try pycode.append(self.allocator, '\n');
    }

    return Stmt{
        .PyCode = .{
            .code_span = codeblock_loc,
            .code = pycode,
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

fn parseCompileType(self: *Self) ParseError!Stmt {
    const comp_ty_loc = self.curr_tok.span;
    if (comp_ty_loc.start.row != 1) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .NotLocatedInVeryFirst = .CompileType },
            .span = comp_ty_loc,
        } });
        return ParseError.ParseFailed;
    }

    if (!self.expect(.current, &.{.CompileType})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.CompileType},
                .obtained = self.currToktype(),
            } },
            .span = comp_ty_loc,
        } });
        return ParseError.ParseFailed;
    }
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();

    while (!self.expect(.peek, &.{ .Lparen, .Eof })) {
        self.nextToken();
    } else {
        self.nextToken();
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

    self.nextToken();
    self.eatWhitespaces(true);
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
    const engine = COMPILE_TYPE.get(self.curr_tok.lit.in_text) orelse {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .InvalidLatexEngine = self.curr_tok.lit.in_text },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    };

    self.nextToken();
    self.eatWhitespaces(true);
    if (!self.expect(.current, &.{.Rparen})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Rparen},
                .obtained = self.currToktype(),
            } },
            .span = comp_ty_loc,
        } });
        return ParseError.ParseFailed;
    }

    if (self.engine) |e| {
        e.* = engine;
    } else {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .DoubleUsed = .CompileType },
            .span = comp_ty_loc,
        } });
        return ParseError.ParseFailed;
    }

    // tells to parser that `compty` keyword is already used
    self.engine = null;
    return Stmt.NopStmt;
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
        for (args.items) |*arg| arg.deinit(self.allocator);
        args.deinit(self.allocator);
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
                    try args.append(self.allocator, .{
                        .needed = .StarArg,
                        .ctx = .{},
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
        for (tmp.items) |*stmt| stmt.deinit(self.allocator);
        tmp.deinit(self.allocator);
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
        var stmt = try self.parseStatement();
        errdefer stmt.deinit(self.allocator);
        try tmp.append(self.allocator, stmt);
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

    try args.append(self.allocator, .{ .needed = arg_need, .ctx = tmp });
}

test "test vesti parser" {
    _ = @import("tests/docclass.zig");
    _ = @import("tests/importpkg.zig");
    _ = @import("tests/math_stmts.zig");
    _ = @import("tests/environments.zig");
    _ = @import("tests/pycode.zig");
}

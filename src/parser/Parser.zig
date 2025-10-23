const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const diag = @import("../diagnostic.zig");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const path = fs.path;
const process = std.process;
const unicode = std.unicode;
const zon = std.zon;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const CowStr = @import("../CowStr.zig").CowStr;
const Io = std.Io;
const ParseErrKind = diag.ParseDiagnostic.ParseErrKind;
const Lexer = @import("../lexer/Lexer.zig");
const Literal = Token.Literal;
const Stmt = ast.Stmt;
const Span = @import("../location.zig").Span;
const Token = @import("../lexer/Token.zig");
const TokenType = Token.TokenType;

const assert = std.debug.assert;
const getConfigPath = @import("../Config.zig").getConfigPath;
const vestiNameMangle = @import("../compile.zig").vestiNameMangle;

const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;

allocator: Allocator,
lexer: Lexer,
curr_tok: Token,
peek_tok: Token,
prev_curr_tok: Token,
prev_peek_tok: Token,
already_rewinded: bool,
doc_state: DocState,
enum_depth: u8,
diagnostic: *diag.Diagnostic,
file_dir: *fs.Dir,
allow_luacode: bool,
current_engine: LatexEngine,
engine_ptr: ?*LatexEngine,

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
    Io.Writer.Error || Io.Reader.Error || error{ StreamTooLong, FailedOpenConfig } ||
    error{ CodepointTooLarge, Utf8CannotEncodeSurrogateHalf } ||
    error{ FailedGetModule, ParseFailed, ParseZon, NameMangle };

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
    engine: anytype,
) !Self {
    var self: Self = undefined;

    self.allocator = allocator;
    self.lexer = try Lexer.init(source);
    self.curr_tok = self.lexer.next();
    self.peek_tok = self.lexer.next();
    self.already_rewinded = false;
    self.doc_state = DocState{};
    self.enum_depth = 0;
    self.diagnostic = diagnostic;
    self.file_dir = file_dir;
    self.allow_luacode = allow_luacode;

    const typeinfo = @typeInfo(@TypeOf(engine));
    comptime assert(typeinfo == .@"struct");
    comptime assert(typeinfo.@"struct".is_tuple);

    self.engine_ptr = engine[0];
    if (@TypeOf(engine[0]) == *LatexEngine) {
        self.current_engine = engine[0].*;
    } else {
        self.current_engine = engine[1];
    }

    return self;
}

pub fn parse(self: *Self) ParseError!ArrayList(Stmt) {
    var stmts = try ArrayList(Stmt).initCapacity(self.allocator, 100);
    errdefer {
        for (stmts.items) |*stmt| stmt.deinit(self.allocator);
        stmts.deinit(self.allocator);
    }

    // lexer.lex_finished means that more_peek_tok is the "last" token from lexer
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
    self.prev_curr_tok = self.curr_tok;
    self.prev_peek_tok = self.peek_tok;
    self.already_rewinded = false;
    self.curr_tok = self.peek_tok;
    self.peek_tok = self.lexer.next();
}

inline fn nextRawToken(self: *Self) void {
    self.prev_curr_tok = self.curr_tok;
    self.prev_peek_tok = self.peek_tok;
    self.already_rewinded = false;
    self.curr_tok = self.peek_tok;
    self.peek_tok = self.lexer.nextRaw();
}

fn rewind(self: *Self) !void {
    if (self.already_rewinded) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .VestiInternal = "consecutive rewind function found." },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    self.curr_tok = self.prev_curr_tok;
    self.peek_tok = self.prev_peek_tok;
    self.already_rewinded = true;
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

// TODO: I think this function code is used everywhere else. Replace with
// this function and reduce the code (making this as inline function)
pub inline fn expectAndEat(
    self: *Self,
    token: TokenType,
) ParseError!Token {
    if (!self.expect(.current, &.{token})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{token},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    const curr_tok = self.curr_tok;
    self.nextToken();
    return curr_tok;
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
        .BuiltinFunction => |builtin_fnt| self.parseBuiltins(builtin_fnt),
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
        .DefineEnv => try self.parseDefineEnv(),
        .DoubleQuote => if (self.doc_state.math_mode)
            try self.parseTextInMath(false)
        else
            self.parseLiteral(),
        .RawSharp => if (self.doc_state.math_mode)
            try self.parseTextInMath(true)
        else
            self.parseLiteral(),
        .ImportVesti => try self.parseImportVesti(),
        .CopyFile => try self.parseCopyFile(),
        .ImportModule => try self.parseImportModule(),
        .CompileType => try self.parseCompileType(),
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
        Stmt{ .TextLit = CowStr.init(.Borrowed, .{self.curr_tok.lit.in_text}) };
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

fn parseBuiltins(self: *Self, builtin_fnt: []const u8) !Stmt {
    const builtin_location = self.curr_tok.span;

    // parsing function parameter attributes
    if (Token.isFunctionParam(builtin_fnt)) |fnt_param| {
        if (fnt_param % 10 == 0) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .InvalidDefunParam = fnt_param },
                .span = builtin_location,
            } });
            return ParseError.ParseFailed;
        }

        const nested = fnt_param / 10;
        const arg_num = fnt_param % 10; // it is in between 1 to 9
        return Stmt{ .DefunParamList = .{
            .nested = nested,
            .arg_num = arg_num,
            .span = builtin_location,
        } };
    }

    // parsing builtin functions
    inline for (comptime Token.VESTI_BUILTINS.keys()) |key| {
        const callback = @field(Self, "parseBuiltin_" ++ key);
        const ReturnType = @typeInfo(@TypeOf(callback)).@"fn".return_type.?;
        if (mem.eql(u8, key, builtin_fnt)) {
            if (ReturnType == Stmt) return callback(self) else return try callback(self);
        }
    }

    // this code runs if `attr` is an invalid attribute name
    self.diagnostic.initDiagInner(.{ .ParseError = .{
        .err_info = .{
            .InvalidBuiltin = try CowStr.init(.Owned, .{ self.allocator, builtin_fnt }),
        },
        .span = builtin_location,
    } });
    return ParseError.ParseFailed;
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
        assert(self.expect(.peek, &.{
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

    try @import("../ves_module.zig").downloadModule(
        self.allocator,
        self.diagnostic,
        mem.trimLeft(u8, mem.trim(u8, mod_dir_path_str, " \t"), "/\\"),
        import_file_loc,
    );

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
        assert(self.expect(.peek, &.{
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
    if (!is_real) {
        if (self.expect(.peek, &.{.Star}))
            self.nextToken()
        else if (self.expect(.peek, &.{ .Space, .Tab })) {
            self.nextToken();
            if (!self.expect(.peek, &.{ .Lparen, .Lsqbrace })) try self.rewind();
        }
    } else self.nextToken();

    // Disable `picture` LaTeX builtin environment. Use #picture instead.
    // The reason why I disable this is because the syntax of this is very different
    // from others.
    // reference: https://lab.uklee.pe.kr/tex-archive/info/latex2e-help-texinfo/latex2e.html#picture
    if (mem.eql(u8, name.Owned.items, "picture")) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .IllegalUseErr = "`picture` environment is illegal in vesti. Use #picture instead." },
            .span = begenv_location,
        } });
        return ParseError.ParseFailed;
    }

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
    errdefer {
        for (args.items) |*arg| arg.deinit(self.allocator);
        args.deinit(self.allocator);
    }

    if (!is_real) {
        if (off_math_state) {
            self.doc_state.math_mode = false;
        }

        // TODO: why is this code exists?
        //if (!self.expect(.peek, &.{ .Newline, .Eof })) {
        //    self.diagnostic.initDiagInner(.{ .ParseError = .{
        //        .err_info = .{ .TokenExpected = .{
        //            .expected = &.{ .Newline, .Eof },
        //            .obtained = self.peekToktype(),
        //        } },
        //        .span = self.peek_tok.span,
        //    } });
        //    return ParseError.ParseFailed;
        //}

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
    if (self.expect(.peek, &.{.Star})) self.nextToken();

    while (self.expect(.current, &.{.Star})) : (self.nextToken()) {
        try name.append(self.allocator, "*");
    }
    self.eatWhitespaces(false);

    // TODO: why is this code exists?
    //if (!self.expect(.current, &.{ .Newline, .Eof })) {
    //    self.diagnostic.initDiagInner(.{ .ParseError = .{
    //        .err_info = .{ .TokenExpected = .{
    //            .expected = &.{ .Newline, .Eof },
    //            .obtained = self.currToktype(),
    //        } },
    //        .span = self.curr_tok.span,
    //    } });
    //    return ParseError.ParseFailed;
    //}

    return Stmt{ .EndPhantomEnviron = name };
}

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
        var kind_str = try ArrayList(u8).initCapacity(self.allocator, 10);
        defer kind_str.deinit(self.allocator);

        while (!self.expect(.current, &.{ .Rsqbrace, .Eof })) : (self.nextToken()) {
            try kind_str.appendSlice(self.allocator, self.curr_tok.lit.in_text);
        }
        if (self.currToktype() == .Eof) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = kind_brace_location,
            } });
            return ParseError.ParseFailed;
        }

        if (!defun_kind.parseDefunKind(kind_str.items)) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{
                    .InvalidDefunKind = .fromOwnedSlice(
                        try kind_str.toOwnedSlice(self.allocator),
                    ),
                },
                .span = kind_brace_location,
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
                    .span = self.curr_tok.span,
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

        for (param_toks.items) |param_tok| {
            switch (param_tok.toktype) {
                .BuiltinFunction => |builtin_fnt| if (Token.isFunctionParam(builtin_fnt)) |fnt_param| {
                    if (fnt_param % 10 == 0) {
                        self.diagnostic.initDiagInner(.{ .ParseError = .{
                            .err_info = .{ .InvalidDefunParam = fnt_param },
                            .span = param_tok.span,
                        } });
                        return ParseError.ParseFailed;
                    }

                    const num_of_sharp = std.math.powi(usize, 2, fnt_param / 10) catch {
                        self.diagnostic.initDiagInner(.{ .ParseError = .{
                            .err_info = .{ .DefunParamOverflow = fnt_param / 10 },
                            .span = param_tok.span,
                        } });
                        return ParseError.ParseFailed;
                    };
                    const param = fnt_param % 10; // it is in between 1 to 9

                    for (0..num_of_sharp) |_| try param_str.writer.writeByte('#');
                    try param_str.writer.print("{d}", .{param});
                } else {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{ .WrongBuiltin = .{
                            .name = builtin_fnt,
                            .note = "this is not a valid function parameter",
                        } },
                        .span = param_tok.span,
                    } });
                    return ParseError.ParseFailed;
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

    var inner = try self.parseBrace(false);
    errdefer inner.deinit(self.allocator);

    out_stmt.DefineFunction.inner = inner.Braced.inner;
    return out_stmt;
}

fn parseDefineEnv(self: *Self) ParseError!Stmt {
    const defenv_location = self.curr_tok.span;
    var is_redefine = false;

    if (!self.expect(.current, &.{.DefineEnv})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.DefineEnv},
                .obtained = self.currToktype(),
            } },
            .span = defenv_location,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();

    if (self.expect(.current, &.{.Star})) {
        self.nextToken();
        is_redefine = true;
    }
    self.eatWhitespaces(false);

    var name = blk: {
        const tmp = switch (self.currToktype()) {
            .Text => self.curr_tok.lit.in_text,
            .Eof => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .EofErr,
                    .span = defenv_location,
                } });
                return ParseError.ParseFailed;
            },
            else => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .NameMissErr = .DefineFunction },
                    .span = defenv_location,
                } });
                return ParseError.ParseFailed;
            },
        };
        break :blk try CowStr.init(.Owned, .{ self.allocator, tmp });
    };
    errdefer name.deinit(self.allocator);
    self.nextToken();
    self.eatWhitespaces(false);

    // parsing defenv arguments
    const num_args = if (self.expect(.current, &.{.Lsqbrace})) blk: {
        const kind_brace_location = self.curr_tok.span;
        self.nextToken();
        const num_arg_location = self.curr_tok.span;
        const tmp = switch (self.currToktype()) {
            .Integer => fmt.parseInt(usize, self.curr_tok.lit.in_text, 10) catch {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{
                        .VestiInternal = "given text must be an integer. Lexer issue happen I suppose...",
                    },
                    .span = num_arg_location,
                } });
                return ParseError.ParseFailed;
            },
            .Eof => {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .EofErr,
                    .span = num_arg_location,
                } });
                return ParseError.ParseFailed;
            },
            else => |toktype| {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .TokenExpected = .{
                        .expected = &.{.Integer},
                        .obtained = toktype,
                    } },
                    .span = num_arg_location,
                } });
                return ParseError.ParseFailed;
            },
        };
        self.nextToken();

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
        break :blk tmp;
    } else 0;
    self.eatWhitespaces(false);

    var arg = if (num_args > 0 and self.expect(.current, &.{.Less})) blk: {
        const tmp = try self.parseParenthesisStmt(.Less, .Great);
        assert(self.expect(.current, &.{.Great}));
        self.nextToken();
        self.eatWhitespaces(false);

        break :blk tmp;
    } else null;
    errdefer if (arg) |*a| a.deinit(self.allocator);

    // parse begin body
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
    var inner_begin = try self.parseBrace(false);
    errdefer inner_begin.deinit(self.allocator);
    self.nextToken(); // eat `}`
    self.eatWhitespaces(true);

    // parse end body
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
    var inner_end = try self.parseBrace(false);
    errdefer inner_end.deinit(self.allocator);
    self.eatWhitespaces(true);

    return Stmt{
        .DefineEnv = .{
            .name = name,
            .is_redefine = is_redefine,
            .num_args = num_args,
            .default_arg = arg,
            .inner_begin = inner_begin.Braced.inner,
            .inner_end = inner_end.Braced.inner,
        },
    };
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
    const luacode_contents = self.curr_tok.lit.in_text;

    // coping luacode contents
    var luacode: ArrayList(u8) = .empty;
    errdefer luacode.deinit(self.allocator);
    try luacode.appendSlice(self.allocator, luacode_contents);

    var is_global = false;
    if (self.expect(.peek, &.{.Star})) {
        self.nextToken();
        is_global = true;
    }

    var code_import: ?ArrayList([]const u8) = null;
    errdefer {
        if (code_import) |*imports| imports.deinit(self.allocator);
    }
    if (self.expect(.peek, &.{.Lsqbrace})) {
        code_import = try ArrayList([]const u8).initCapacity(
            self.allocator,
            10,
        );
        self.nextToken(); // skip ':lu#' or '*' token
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

            try code_import.?.append(self.allocator, self.curr_tok.lit.in_text);
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
        self.nextToken(); // skip ':lu#' or ']' token

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
            .is_global = is_global,
            .code_import = code_import,
            .code_export = code_export,
            .code = luacode,
        },
    };
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

    if (self.engine_ptr) |e| {
        e.* = engine;
        self.current_engine = engine;
    } else {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .DoubleUsed = .CompileType },
            .span = comp_ty_loc,
        } });
        return ParseError.ParseFailed;
    }

    // tells to parser that `compty` keyword is already used
    self.engine_ptr = null;
    return Stmt.NopStmt;
}

// parse (<stmts>)
fn parseParenthesisStmt(
    self: *Self,
    comptime open: TokenType,
    comptime closed: TokenType,
) ParseError!ast.Arg {
    var args = try ArrayList(ast.Arg).initCapacity(self.allocator, 3);
    errdefer {
        for (args.items) |*arg| arg.deinit(self.allocator);
        args.deinit(self.allocator);
    }

    if (self.expect(.current, &.{open})) {
        try self.parseFunctionArgsCore(
            &args,
            open,
            closed,
            .MainArg,
        );
    }

    assert(args.items.len == 1);

    const output = args.items[0];
    args.deinit(self.allocator);

    return output;
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

    var nested: usize = 1;
    while (switch (self.currToktype()) {
        open => blk: {
            nested += 1;
            break :blk true;
        },
        closed => blk: {
            nested -= 1;
            break :blk nested > 0;
        },
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

// do not confuse with parseParenthesisStmt. - Almagest 10/24/2025
fn parseBuiltinsArguments(
    self: *Self,
    span: Span,
    comptime open: TokenType,
    comptime closed: TokenType,
    comptime ignore_newline: bool,
) ParseError!ArrayList(u8) {
    var inner = Io.Writer.Allocating.init(self.allocator);
    errdefer inner.deinit();

    if (!self.expect(.current, &.{open})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{open},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken(); // eat `open`

    var nested: usize = 1;
    while (switch (self.currToktype()) {
        open => blk: {
            nested += 1;
            break :blk true;
        },
        closed => blk: {
            nested -= 1;
            break :blk nested > 0;
        },
        else => true,
    }) : (self.nextToken()) {
        if (self.currToktype() == .Eof) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .EofErr,
                .span = span,
            } });
            return ParseError.ParseFailed;
        }
        try inner.writer.writeAll(self.curr_tok.lit.in_text);
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
    self.nextToken(); // eat `closed`
    self.eatWhitespaces(ignore_newline);

    return inner.toArrayList();
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
        assert(self.expect(.peek, &.{
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

// NOTE: This special function is needed because of following zig compiler bug:
// - https://github.com/ziglang/zig/issues/5973
// - https://github.com/ziglang/zig/issues/24324 [closed]
// After these are resolved, remove this function
inline fn preventBug(s: *const volatile Span) void {
    _ = s;
}

//          ╭─────────────────────────────────────────────────────────╮
//          │                   Parsing Builtins                      │
//          ╰─────────────────────────────────────────────────────────╯
// NOTE: All functions should have a name parseBuiltin_<builtin_name>
// where <builtin_name> can be found at Token.VESTI_BUILTINS.

fn parseBuiltin_nonstopmode(self: *Self) Stmt {
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
    return Stmt{ .TextLit = CowStr.init(.Borrowed, .{"\n\\nonstopmode\n"}) };
}

fn parseBuiltin_makeatletter(self: *Self) Stmt {
    self.lexer.make_at_letter = true;
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
    return Stmt{ .TextLit = CowStr.init(.Borrowed, .{"\n\\makeatletter\n"}) };
}

fn parseBuiltin_makeatother(self: *Self) Stmt {
    self.lexer.make_at_letter = false;
    if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
    return Stmt{ .TextLit = CowStr.init(.Borrowed, .{"\n\\makeatother\n"}) };
}

fn parseBuiltin_ltx3_on(self: *Self) ParseError!Stmt {
    self.lexer.is_latex3_on = true;
    if (self.doc_state.latex3_included) {
        if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
        return Stmt{ .TextLit = CowStr.init(.Borrowed, .{"\n\\ExplSyntaxOn\n"}) };
    } else {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{
                .WrongBuiltin = .{
                    .name = "ltx3_on",
                    .note = "must use `#ltx3_import` to use this keyword",
                },
            },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
}

fn parseBuiltin_ltx3_off(self: *Self) ParseError!Stmt {
    self.lexer.is_latex3_on = false;
    if (self.doc_state.latex3_included) {
        if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
        return Stmt{ .TextLit = CowStr.init(.Borrowed, .{"\n\\ExplSyntaxOff\n"}) };
    } else {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{
                .WrongBuiltin = .{
                    .name = "ltx3_off",
                    .note = "must use `#ltx3_import` to use this keyword",
                },
            },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
}

fn parseBuiltin_ltx3_import(self: *Self) ParseError!Stmt {
    if (self.isPremiere()) {
        self.doc_state.latex3_included = true;
        if (self.expect(.peek, &.{ .Space, .Tab })) self.nextToken();
        return Stmt{ .TextLit = CowStr.init(.Borrowed, .{"\n\\usepackage{expl3, xparse}\n"}) };
    } else {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .PremiereErr,
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
}

fn parseBuiltin_textmode(self: *Self) ParseError!Stmt {
    const textmode_block_loc = self.curr_tok.span;
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

    if (!self.doc_state.math_mode) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .TextmodeInText,
            .span = textmode_block_loc,
        } });
        return ParseError.ParseFailed;
    }

    self.doc_state.math_mode = false;
    var inner = try self.parseBrace(false);
    errdefer inner.deinit();
    self.doc_state.math_mode = true;

    inner.Braced.unwrap_brace = true;
    return inner;
}

fn parseBuiltin_mathmode(self: *Self) ParseError!Stmt {
    const mathmode_block_loc = self.curr_tok.span;
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

    if (self.doc_state.math_mode) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .MathmodeInMath,
            .span = mathmode_block_loc,
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

fn parseBuiltin_eq(self: *Self) ParseError!Stmt {
    const eq_block_loc = self.curr_tok.span;
    if (self.doc_state.math_mode) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "eq",
                .note = "`#eq` cannot be used inside math mode",
            } },
            .span = eq_block_loc,
        } });
        return ParseError.ParseFailed;
    }

    self.nextToken(); // eat `#eq`
    self.eatWhitespaces(false);

    var label = if (self.expect(.current, &.{.Lparen}))
        try self.parseBuiltinsArguments(
            eq_block_loc,
            .Lparen,
            .Rparen,
            true,
        )
    else
        null;
    errdefer if (label) |*l| l.deinit(self.allocator);

    self.doc_state.math_mode = true;
    var inner = try self.parseBrace(false);
    errdefer inner.deinit();
    self.doc_state.math_mode = false;

    return Stmt{ .MathCtx = .{
        .state = .Labeled,
        .inner = inner.Braced.inner,
        .label = label,
    } };
}

fn parseBuiltin_label(self: *Self) ParseError!Stmt {
    const label_block_loc = self.curr_tok.span;
    self.nextToken(); // eat `#label`
    self.eatWhitespaces(false);

    var label = try self.parseBuiltinsArguments(
        label_block_loc,
        .Lparen,
        .Rparen,
        true,
    );
    errdefer label.deinit(self.allocator);

    if (self.currToktype() != .Useenv) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "label",
                .note = "`#label` must be located before `useenv`",
            } },
            .span = label_block_loc,
        } });
        return ParseError.ParseFailed;
    }

    var env = try self.parseEnvironment(true);
    errdefer env.deinit();

    // add a label
    env.Environment.label = label;
    return env;
}

fn parseBuiltin_showfont(self: *Self) ParseError!Stmt {
    const showfont_loc = self.curr_tok.span;
    self.nextToken(); // eat `#showfont`
    self.eatWhitespaces(false);

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

    if (!self.expect(.current, &.{.Integer})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "showfont",
                .note = "only integer values are possible",
            } },
            .span = showfont_loc,
        } });
        return ParseError.ParseFailed;
    }
    const num = fmt.parseInt(u8, self.curr_tok.lit.in_text, 10) catch {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "showfont",
                .note = "integer should be in 0 to 255",
            } },
            .span = showfont_loc,
        } });
        return ParseError.ParseFailed;
    };
    self.nextToken();

    if (!self.expect(.current, &.{.Rparen})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Rparen},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    var output = try ArrayList(u8).initCapacity(self.allocator, 50);
    errdefer output.deinit(self.allocator);
    try output.print(
        self.allocator,
        " {{\\ttfamily\\expandafter\\meaning\\the\\textfont{d}}}",
        .{num},
    );

    return Stmt{ .TextLit = .fromArrayList(output) };
}

fn parseBuiltin_chardef(self: *Self) ParseError!Stmt {
    const chardef_loc = self.curr_tok.span;
    self.nextToken(); // eat `#chardef`
    self.eatWhitespaces(false);

    if (!self.expect(.current, &.{ .Text, .Integer })) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{ .Text, .Integer },
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    const unicode_codepoint = fmt.parseInt(usize, self.curr_tok.lit.in_text, 16) catch {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "chardef",
                .note = "hexdecimal number expected in the third argument",
            } },
            .span = chardef_loc,
        } });
        return ParseError.ParseFailed;
    };
    self.nextToken();
    self.eatWhitespaces(false);

    if (!self.expect(.current, &.{.LatexFunction})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.LatexFunction},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    const latex_function = self.curr_tok.lit.in_text;
    self.nextToken();
    self.eatWhitespaces(false);

    if (!self.expect(.current, &.{.Newline})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "chardef",
                .note = "this builtin must end with the newline",
            } },
            .span = chardef_loc,
        } });
        return ParseError.ParseFailed;
    }

    var output = try ArrayList(u8).initCapacity(self.allocator, 50);
    errdefer output.deinit(self.allocator);
    try output.print(
        self.allocator,
        "\\chardef{s}=\"{X}\n",
        .{
            latex_function,
            unicode_codepoint,
        },
    );

    return Stmt{ .TextLit = .fromArrayList(output) };
}

const MathClass = enum(u3) {
    ordinary = 0,
    largeop = 1,
    binary = 2,
    relation = 3,
    opening = 4,
    closing = 5,
    punct = 6,
    variable = 7,
};

fn parseBuiltin_mathchardef(self: *Self) ParseError!Stmt {
    const mchardef_loc = self.curr_tok.span;
    self.nextToken(); // eat `#mathchardef`
    self.eatWhitespaces(false);

    if (!self.expect(.current, &.{.Period})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Period},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    self.nextToken();

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
    const kind_txt = self.curr_tok.lit.in_text;
    const kind_txt_z = try self.allocator.allocSentinel(u8, kind_txt.len + 1, 0);
    defer self.allocator.free(kind_txt_z);

    kind_txt_z[0] = '.';
    @memcpy(kind_txt_z[1..], kind_txt);

    const math_class =
        zon.parse.fromSlice(MathClass, self.allocator, kind_txt_z, null, .{}) catch {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .WrongBuiltin = .{
                    .name = "mathchardef",
                    .note =
                    \\invalid math class was found. Here is the list of math class available:
                    \\.ordinary  .largeop  .binary  .relation
                    \\.opening   .closing  .punct   .variable
                    \\here, the prefix `.` is needed
                    ,
                } },
                .span = mchardef_loc,
            } });
            return ParseError.ParseFailed;
        };
    self.nextToken();
    self.eatWhitespaces(false);

    if (!self.expect(.current, &.{.Integer})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.Integer},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    const font_num = fmt.parseInt(u8, self.curr_tok.lit.in_text, 10) catch {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "mathchardef",
                .note = "integer should be in 0 to 255",
            } },
            .span = mchardef_loc,
        } });
        return ParseError.ParseFailed;
    };
    self.nextToken();
    self.eatWhitespaces(false);

    if (!self.expect(.current, &.{ .Text, .Integer })) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{ .Text, .Integer },
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }

    const unicode_codepoint = fmt.parseInt(usize, self.curr_tok.lit.in_text, 16) catch {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "mathchardef",
                .note = "hexdecimal number expected in the third argument",
            } },
            .span = mchardef_loc,
        } });
        return ParseError.ParseFailed;
    };
    self.nextToken();
    self.eatWhitespaces(false);

    if (!self.expect(.current, &.{.LatexFunction})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .TokenExpected = .{
                .expected = &.{.LatexFunction},
                .obtained = self.currToktype(),
            } },
            .span = self.curr_tok.span,
        } });
        return ParseError.ParseFailed;
    }
    const latex_function = self.curr_tok.lit.in_text;
    self.nextToken();
    self.eatWhitespaces(false);

    if (!self.expect(.current, &.{.Newline})) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "mathchardef",
                .note = "this builtin must end with the newline",
            } },
            .span = mchardef_loc,
        } });
        return ParseError.ParseFailed;
    }

    var output = try ArrayList(u8).initCapacity(self.allocator, 50);
    errdefer output.deinit(self.allocator);
    try output.print(
        self.allocator,
        "\\Umathchardef{s}={d} {d} \"{X}\n",
        .{
            latex_function,
            @intFromEnum(math_class),
            font_num,
            unicode_codepoint,
        },
    );

    return Stmt{ .TextLit = .fromArrayList(output) };
}

fn parseBuiltin_enum(self: *Self) ParseError!Stmt {
    const enum_loc = self.curr_tok.span;

    // TODO: without using `enumitem`, the maximum depth of enum is 4.
    if (self.enum_depth >= 5) {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "enum",
                .note = "`#enum` builtin cannot be nested more than four times",
            } },
            .span = enum_loc,
        } });
        return ParseError.ParseFailed;
    }

    // increment enum depth
    self.enum_depth += 1;

    self.nextToken(); // eat `#enum`
    self.eatWhitespaces(false);

    var label_kind = if (self.expect(.current, &.{.Lparen}))
        try self.parseBuiltinsArguments(
            enum_loc,
            .Lparen,
            .Rparen,
            true,
        )
    else
        null;
    defer if (label_kind) |*l| l.deinit(self.allocator);

    var inner = try self.parseBrace(false);
    errdefer inner.deinit(self.allocator);

    const env = Stmt{ .Environment = .{
        .name = CowStr.init(.Borrowed, .{"enumerate"}),
        .args = .empty,
        .inner = inner.Braced.inner,
    } };

    var output_inner = try ArrayList(Stmt).initCapacity(self.allocator, 5);
    errdefer output_inner.deinit(self.allocator);

    if (label_kind) |lk| {
        // TODO: indexOf -> findPos
        if (mem.indexOf(u8, lk.items, "**") != null) {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .WrongBuiltin = .{
                    .name = "enum",
                    .note = "consequtive `*` is not allowed",
                } },
                .span = enum_loc,
            } });
            return ParseError.ParseFailed;
        }

        var reset_label = Io.Writer.Allocating.init(self.allocator);
        errdefer reset_label.deinit();

        try reset_label.writer.print("\\renewcommand{{\\{s}}}{{", .{switch (self.enum_depth) {
            1 => "labelenumi",
            2 => "labelenumii",
            3 => "labelenumiii",
            4 => "labelenumiv",
            else => unreachable,
        }});

        var iter = mem.splitScalar(u8, lk.items, '*');
        while (iter.next()) |s| {
            try reset_label.writer.writeAll(s);
            if (iter.peek() == null) break;
            try reset_label.writer.print("{{{s}}}", .{switch (self.enum_depth) {
                1 => "enumi",
                2 => "enumii",
                3 => "enumiii",
                4 => "enumiv",
                else => unreachable,
            }});
        }
        try reset_label.writer.writeAll("}\n");

        try output_inner.append(
            self.allocator,
            Stmt{ .TextLit = .fromArrayList(reset_label.toArrayList()) },
        );
    }

    try output_inner.append(self.allocator, env);

    // back to the previous state of enum depth
    self.enum_depth -= 1;

    return Stmt{ .Braced = .{
        .unwrap_brace = true,
        .inner = output_inner,
    } };
}

fn parseBuiltin_get_filepath(self: *Self) ParseError!Stmt {
    const import_file_loc = self.curr_tok.span;
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

// Builtin which supports `picture` environment
// reference: https://lab.uklee.pe.kr/tex-archive/info/latex2e-help-texinfo/latex2e.html#picture
fn parseBuiltin_picture(self: *Self) ParseError!Stmt {
    const picture_block_loc = self.curr_tok.span;

    self.nextToken(); // eat `#picture`
    self.eatWhitespaces(false);

    var unit_length = if (self.expect(.current, &.{.Lsqbrace}))
        try self.parseBuiltinsArguments(
            picture_block_loc,
            .Lsqbrace,
            .Rsqbrace,
            false,
        )
    else
        null;
    errdefer if (unit_length) |*ul| ul.deinit(self.allocator);

    _ = try self.expectAndEat(.Lparen); // eat (

    const width_tok_loc = self.curr_tok.span;
    preventBug(&width_tok_loc);
    const width_token = try self.expectAndEat(.Integer);
    const width = fmt.parseInt(usize, width_token.lit.in_text, 10) catch {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "picture",
                .note = "integer should be nonnegative",
            } },
            .span = width_tok_loc,
        } });
        return ParseError.ParseFailed;
    };

    _ = try self.expectAndEat(.Comma); // eat ,
    self.eatWhitespaces(false);

    const height_tok_loc = self.curr_tok.span;
    preventBug(&height_tok_loc);
    const height_token = try self.expectAndEat(.Integer);
    const height = fmt.parseInt(usize, height_token.lit.in_text, 10) catch {
        self.diagnostic.initDiagInner(.{ .ParseError = .{
            .err_info = .{ .WrongBuiltin = .{
                .name = "picture",
                .note = "integer should be nonnegative",
            } },
            .span = height_tok_loc,
        } });
        return ParseError.ParseFailed;
    };
    _ = try self.expectAndEat(.Rparen); // eat )
    self.eatWhitespaces(false);

    var xoffset: ?usize = null;
    var yoffset: ?usize = null;
    if (self.expect(.current, &.{.Lparen})) {
        _ = try self.expectAndEat(.Lparen); // eat (

        const xoffset_tok_loc = self.curr_tok.span;
        preventBug(&xoffset_tok_loc);
        const xoffset_token = try self.expectAndEat(.Integer);
        xoffset = fmt.parseInt(usize, xoffset_token.lit.in_text, 10) catch {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .WrongBuiltin = .{
                    .name = "picture",
                    .note = "integer should be nonnegative",
                } },
                .span = xoffset_tok_loc,
            } });
            return ParseError.ParseFailed;
        };

        _ = try self.expectAndEat(.Comma); // eat ,
        self.eatWhitespaces(false);

        const yoffset_tok_loc = self.curr_tok.span;
        preventBug(&yoffset_tok_loc);
        const yoffset_token = try self.expectAndEat(.Integer);
        yoffset = fmt.parseInt(usize, yoffset_token.lit.in_text, 10) catch {
            self.diagnostic.initDiagInner(.{ .ParseError = .{
                .err_info = .{ .WrongBuiltin = .{
                    .name = "picture",
                    .note = "integer should be nonnegative",
                } },
                .span = yoffset_tok_loc,
            } });
            return ParseError.ParseFailed;
        };

        _ = try self.expectAndEat(.Rparen); // eat )
    }
    self.eatWhitespaces(true);

    var inner = try self.parseBrace(false);
    errdefer inner.deinit();

    return Stmt{ .PictureEnvironment = .{
        .width = width,
        .height = height,
        .xoffset = xoffset,
        .yoffset = yoffset,
        .unit_length = unit_length,
        .inner = inner.Braced.inner,
    } };
}

test "test vesti parser" {
    _ = @import("tests/docclass.zig");
    _ = @import("tests/importpkg.zig");
    _ = @import("tests/math_stmts.zig");
    _ = @import("tests/environments.zig");
    _ = @import("tests/luacode.zig");
}

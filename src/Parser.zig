const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;

const ast = @import("ast.zig");
const location = @import("location.zig");
const token = @import("token.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Lexer = @import("Lexer.zig");
const ErrorInfo = @import("error_info.zig").ErrorInfo;

pub const Parser = @This();
const Self = @This();

// Parse Failed Signal
const ParseError = std.mem.Allocator.Error || ast.GenerateAstError || error{
    ParseFailed,
    CannotGenerateName,
};

// Parser Parameters
allocator: Allocator,
source: Lexer,
peek_token: token.Token,
peek2_token: token.Token,
error_info: ?ErrorInfo,
doc_state: DocState,
// END Parameters

const env_math_ident = [5][]const u8{
    "equation",
    "align",
    "array",
    "eqnarray",
    "gather",
};

// A bitfield to deal the state of the parser
const DocState = packed struct {
    doc_start: bool,
    prevent_end_doc: bool,
    parsing_define: bool,
};

pub fn init(source: []const u8, allocator: Allocator) Self {
    var output = Self{
        .allocator = allocator,
        .source = Lexer.new(source),
        .peek_token = undefined,
        .peek2_token = undefined,
        .error_info = null,
        .doc_state = @bitCast(DocState, @as(u3, 0)),
    };
    _ = output.nextToken();
    _ = output.nextToken();

    return output;
}

// inline functions
inline fn nextToken(self: *Self) token.Token {
    const output = self.peek_token;
    self.peek_token = self.peek2_token;
    self.peek2_token = self.source.next();

    return output;
}

inline fn peekTokenSpan(self: *const Self) location.Span {
    return self.peek_token.span;
}

inline fn getPeekToktype(self: *const Self) token.Type {
    return self.peek_token.toktype;
}

inline fn peekToktypeIs(self: *const Self, comptime toktype: token.Type) bool {
    return self.getPeekToktype() == toktype;
}

inline fn peek2TokenSpan(self: *const Self) location.Span {
    return self.peek2_token.span;
}

inline fn getPeek2Toktype(self: *const Self) token.Type {
    return self.peek2_token.toktype;
}

inline fn peek2ToktypeIs(self: *const Self, comptime toktype: token.Type) bool {
    return self.getPeek2Toktype() == toktype;
}

inline fn isEof(self: *const Self) bool {
    return self.peekToktypeIs(.eof);
}

inline fn eatWhitespaces(self: *Self, comptime newline_handle: bool) void {
    while (switch (self.peek_token.toktype) {
        .space, .tab => true,
        .newline => newline_handle,
        else => false,
    }) {
        _ = self.nextToken();
    }
}

inline fn isPremiere(self: *const Self) bool {
    return !self.doc_state.doc_start and !self.doc_state.parsing_define;
}

inline fn expectPeek(
    self: *Self,
    expected: []const token.Type,
    span: location.Span,
) ParseError!void {
    const got = self.peek_token.toktype;
    var is_expected = false;

    for (expected) |expected_toktype| {
        if (got == expected_toktype) {
            is_expected = true;
            break;
        }
    }

    if (!is_expected) {
        self.error_info = ErrorInfo{
            .kind = .{ .type_mismatch = .{ .expected = expected, .got = got } },
            .span = span,
        };
        return error.ParseFailed;
    } else {
        _ = self.nextToken();
    }
}

// Main Parsing part
pub fn parse(self: *Self) ParseError!ast.Latex {
    var output = ast.Latex.init(self.allocator);
    errdefer output.deinit();

    while (!self.isEof()) {
        if (self.peekToktypeIs(.nop)) {
            continue;
        }
        try output.append(try self.parseStatement());
    }

    if (!self.isPremiere()) {
        try output.append(.document_end);
    }

    return output;
}

fn parseStatement(self: *Self) ParseError!ast.Statement {
    return switch (self.getPeekToktype()) {
        // keywords
        .docclass => try self.parseDocclass(),
        .import => try self.parsePackages(),
        .start_doc => blk: {
            if (self.isPremiere()) {
                self.doc_state.doc_start = true;
                _ = self.nextToken();
                self.eatWhitespaces(true);
                break :blk .document_start;
            } else {
                break :blk try self.parseMainText();
            }
        },
        .begenv => try self.parseEnvironment(true),
        .endenv => blk: {
            self.error_info = ErrorInfo{
                .kind = .{ .is_not_opened = .{
                    .open = &[_]token.Type{
                        .begenv,
                        .defenv,
                        .redefenv,
                    },
                    .close = .endenv,
                } },
                .span = self.peekTokenSpan(),
            };
            break :blk error.ParseFailed;
        },
        .phantom_begenv => try self.parseEnvironment(false),
        .phantom_endenv => try self.parseEndPhantomEnvironment(),
        .mtxt => try self.parseTextInMath(),
        .etxt => blk: {
            self.error_info = ErrorInfo{
                .kind = .{ .is_not_opened = .{
                    .open = &[_]token.Type{
                        .mtxt,
                    },
                    .close = .etxt,
                } },
                .span = self.peekTokenSpan(),
            };
            break :blk error.ParseFailed;
        },
        .nodocclass => blk: {
            self.doc_state.prevent_end_doc = true;
            self.doc_state.doc_start = true;

            const curr_span = self.nextToken().span;
            try self.expectPeek(&[_]token.Type{.newline}, curr_span);
            break :blk self.parseStatement();
        },
        .function_def,
        .long_function_def,
        .outer_function_def,
        .long_outer_function_def,
        .e_function_def,
        .e_long_function_def,
        .e_outer_function_def,
        .e_long_outer_function_def,
        .g_function_def,
        .g_long_function_def,
        .g_outer_function_def,
        .g_long_outer_function_def,
        .x_function_def,
        .x_long_function_def,
        .x_outer_function_def,
        .x_long_outer_function_def,
        => try self.parseFunctionDefinition(),
        .end_function_def => blk: {
            self.error_info = ErrorInfo{
                .kind = .{ .is_not_opened = .{
                    .open = &[_]token.Type{
                        .function_def,
                        .long_function_def,
                        .outer_function_def,
                        .long_outer_function_def,
                        .e_function_def,
                        .e_long_function_def,
                        .e_outer_function_def,
                        .e_long_outer_function_def,
                        .g_function_def,
                        .g_long_function_def,
                        .g_outer_function_def,
                        .g_long_outer_function_def,
                        .x_function_def,
                        .x_long_function_def,
                        .x_outer_function_def,
                        .x_long_outer_function_def,
                    },
                    .close = .end_function_def,
                } },
                .span = self.peekTokenSpan(),
            };
            break :blk error.ParseFailed;
        },
        .defenv, .redefenv => try self.parseEnvironmentDefinition(),
        .ends_with => blk: {
            self.error_info = ErrorInfo{
                .kind = .{ .is_not_opened = .{
                    .open = &[_]token.Type{
                        .defenv,
                        .redefenv,
                    },
                    .close = .ends_with,
                } },
                .span = self.peekTokenSpan(),
            };
            break :blk error.ParseFailed;
        },

        // identifiers
        .latex_function => try self.parseLatexFunction(),
        .raw_latex => try self.parseRawLatex(),
        .integer => try self.parseInteger(),
        .float => try self.parseFloat(),

        // math related tokens
        .text_math_start => self.parseTextMathStmt(),
        .display_math_start => self.parseDisplayMathStmt(),
        .superscript, .subscript => blk: {
            if (!self.source.math_start and !self.doc_state.parsing_define) {
                self.error_info = ErrorInfo{
                    .kind = .{ .illegal_used = self.getPeekToktype() },
                    .span = self.peekTokenSpan(),
                };
                break :blk error.ParseFailed;
            } else {
                break :blk try self.parseMainText();
            }
        },
        .text_math_end => blk: {
            self.error_info = ErrorInfo{
                .kind = .{ .is_not_opened = .{
                    .open = &[_]token.Type{
                        .text_math_start,
                    },
                    .close = .text_math_end,
                } },
                .span = self.peekTokenSpan(),
            };
            break :blk error.ParseFailed;
        },
        .display_math_end => blk: {
            self.error_info = ErrorInfo{
                .kind = .{ .is_not_opened = .{
                    .open = &[_]token.Type{
                        .display_math_start,
                    },
                    .close = .display_math_end,
                } },
                .span = self.peekTokenSpan(),
            };
            break :blk error.ParseFailed;
        },

        .illegal => blk: {
            self.error_info = ErrorInfo{
                .kind = .illegal_token_found,
                .span = self.peekTokenSpan(),
            };
            break :blk error.ParseFailed;
        },

        else => try self.parseMainText(),
    };
}

fn parseInteger(self: *Self) ParseError!ast.Statement {
    const curr_token = self.nextToken();
    const int = fmt.parseInt(i64, curr_token.literal, 10) catch {
        self.error_info = ErrorInfo{
            .kind = .parse_int_failed,
            .span = self.peekTokenSpan(),
        };
        return error.ParseFailed;
    };

    return ast.Statement{ .integer = int };
}

fn parseFloat(self: *Self) ParseError!ast.Statement {
    const curr_token = self.nextToken();
    const float = fmt.parseFloat(f64, curr_token.literal) catch {
        self.error_info = ErrorInfo{
            .kind = .parse_float_failed,
            .span = self.peekTokenSpan(),
        };
        return error.ParseFailed;
    };

    return ast.Statement{ .float = float };
}

fn parseRawLatex(self: *Self) ParseError!ast.Statement {
    const curr_token = self.nextToken();

    return ast.Statement{ .raw_latex = curr_token.literal };
}

fn parseMainText(self: *Self) ParseError!ast.Statement {
    if (self.isEof()) {
        self.error_info = ErrorInfo{
            .kind = .eof_found,
            .span = self.peekTokenSpan(),
        };
        return error.ParseFailed;
    }

    return ast.Statement{ .main_text = self.nextToken().literal };
}

fn parseTextMathStmt(self: *Self) ParseError!ast.Statement {
    const start_span = self.peekTokenSpan();
    try self.expectPeek(&[_]token.Type{.text_math_start}, self.peekTokenSpan());

    var stmt_lst = ArrayList(ast.Statement).init(self.allocator);
    errdefer {
        for (stmt_lst.items) |stmt| {
            stmt.deinit();
        }
        stmt_lst.deinit();
    }

    while (!self.peekToktypeIs(.text_math_end)) {
        const stmt = self.parseStatement() catch {
            switch (self.error_info.?.kind) {
                .eof_found => {
                    self.error_info.? = ErrorInfo{
                        .kind = .{ .is_not_closed = .{
                            .open = .text_math_start,
                            .close = .text_math_end,
                        } },
                        .span = start_span,
                    };
                },
                else => {},
            }
            return error.ParseFailed;
        };
        errdefer stmt.deinit();
        try stmt_lst.append(stmt);
    }

    try self.expectPeek(&[_]token.Type{.text_math_end}, self.peekTokenSpan());

    return ast.Statement{ .math_text = .{
        .state = .text_math,
        .text = .{ .stmts = stmt_lst },
    } };
}

fn parseDisplayMathStmt(self: *Self) ParseError!ast.Statement {
    const start_span = self.peekTokenSpan();
    try self.expectPeek(&[_]token.Type{.display_math_start}, self.peekTokenSpan());

    var stmt_lst = ArrayList(ast.Statement).init(self.allocator);
    errdefer {
        for (stmt_lst.items) |stmt| {
            stmt.deinit();
        }
        stmt_lst.deinit();
    }

    while (!self.peekToktypeIs(.display_math_end)) {
        const stmt = self.parseStatement() catch {
            switch (self.error_info.?.kind) {
                .eof_found => {
                    self.error_info.? = ErrorInfo{
                        .kind = .{ .is_not_closed = .{
                            .open = .display_math_start,
                            .close = .display_math_end,
                        } },
                        .span = start_span,
                    };
                },
                else => {},
            }
            return error.ParseFailed;
        };
        errdefer stmt.deinit();
        try stmt_lst.append(stmt);
    }

    try self.expectPeek(&[_]token.Type{.display_math_end}, self.peekTokenSpan());

    return ast.Statement{ .math_text = .{
        .state = .display_math,
        .text = .{ .stmts = stmt_lst },
    } };
}

fn parseTextInMath(self: *Self) ParseError!ast.Statement {
    var text = ast.Latex.init(self.allocator);
    errdefer text.deinit();
    var trim = ast.TrimWhitespace{
        .start = true,
        .end = true,
        .mid = null,
    };
    try self.expectPeek(&[_]token.Type{.mtxt}, self.peekTokenSpan());

    if (self.peekToktypeIs(.star)) {
        trim.start = false;
        _ = self.nextToken();
    }
    self.eatWhitespaces(false);

    while (!self.peekToktypeIs(.etxt)) {
        if (self.isEof()) {
            self.error_info = ErrorInfo{
                .kind = .eof_found,
                .span = self.peekTokenSpan(),
            };
            return error.ParseFailed;
        }
        var stmt = try self.parseStatement();
        errdefer stmt.deinit();
        try text.append(stmt);
    }

    try self.expectPeek(&[_]token.Type{.etxt}, self.peekTokenSpan());
    if (self.peekToktypeIs(.star)) {
        trim.end = false;
        _ = self.nextToken();
    }

    return ast.Statement{ .plain_text_in_math = .{
        .trim = trim,
        .text = text,
    } };
}

fn parseLatexFunction(self: *Self) ParseError!ast.Statement {
    const name =
        switch (self.getPeekToktype()) {
        .eof => {
            self.error_info = ErrorInfo{
                .kind = .eof_found,
                .span = self.peekTokenSpan(),
            };
            return error.ParseFailed;
        },
        .latex_function => self.nextToken().literal,
        else => {
            self.error_info = ErrorInfo{
                .kind = .{ .type_mismatch = .{
                    .expected = &[_]token.Type{.latex_function},
                    .got = self.getPeekToktype(),
                } },
                .span = self.peekTokenSpan(),
            };
            return error.ParseFailed;
        },
    };

    var has_space = false;
    if (self.peekToktypeIs(.space)) {
        has_space = true;
        self.eatWhitespaces(false);
    }

    var args = ArrayList(ast.Argument).init(self.allocator);
    errdefer {
        for (args.items) |arg| {
            arg.deinit();
        }
        args.deinit();
    }

    try self.parseFunctionArgs(
        &args,
        .left_brace,
        .right_brace,
        .left_square_brace,
        .right_square_brace,
    );
    const args_len = args.items.len;

    return ast.Statement{
        .latex_function = .{
            .name = name,
            .args = args,
            .has_space = args_len == 0 and has_space,
        },
    };
}

fn parseDocclass(self: *Self) ParseError!ast.Statement {
    var output_stmt: ast.Statement = undefined;

    if (self.isPremiere()) {
        try self.expectPeek(&[_]token.Type{.docclass}, self.peekTokenSpan());
        self.eatWhitespaces(false);

        const name = try self.takeName();
        errdefer name.deinit();
        self.eatWhitespaces(false);

        if (self.peekToktypeIs(.left_paren)) {
            output_stmt = .{
                .document_class = ast.Package.init(self.allocator, true),
            };
            errdefer output_stmt.deinit();
            try self.parseCommaArgs(&output_stmt.document_class.options.?);
        } else {
            output_stmt = .{
                .document_class = ast.Package.init(self.allocator, false),
            };
            self.eatWhitespaces(false);
        }

        output_stmt.document_class.name = name;
        if (self.peekToktypeIs(.newline)) {
            _ = self.nextToken();
        }
    } else {
        output_stmt = try self.parseMainText();
    }

    return output_stmt;
}

fn parsePackages(self: *Self) ParseError!ast.Statement {
    var output_stmt: ast.Statement = undefined;

    if (self.isPremiere()) {
        try self.expectPeek(&[_]token.Type{.import}, self.peekTokenSpan());
        self.eatWhitespaces(false);

        if (self.peekToktypeIs(.left_brace)) {
            const pkgs = try self.parseMultiplePackages();
            return ast.Statement{ .use_packages = pkgs };
        }

        output_stmt = .{
            .use_packages = ArrayList(ast.Package).init(self.allocator),
        };
        errdefer output_stmt.deinit();

        var name = try self.takeName();
        defer name.deinit();
        self.eatWhitespaces(false);

        var pkg = blk: {
            if (self.peekToktypeIs(.left_paren)) {
                var tmp = ast.Package.init(self.allocator, true);
                errdefer tmp.deinit();
                try self.parseCommaArgs(&tmp.options.?);
                break :blk tmp;
            } else {
                break :blk ast.Package.init(self.allocator, false);
            }
        };
        errdefer pkg.deinit();
        pkg.name = try name.clone();

        try output_stmt.use_packages.append(pkg);
        if (self.peekToktypeIs(.newline)) {
            _ = self.nextToken();
        }
    } else {
        output_stmt = try self.parseMainText();
    }

    return output_stmt;
}

fn parseMultiplePackages(self: *Self) ParseError!ArrayList(ast.Package) {
    var packages = ArrayList(ast.Package).init(self.allocator);
    errdefer packages.deinit();

    try self.expectPeek(&[_]token.Type{.left_brace}, self.peekTokenSpan());
    self.eatWhitespaces(true);

    while (!self.peekToktypeIs(.right_brace)) {
        var name = try self.takeName();
        defer name.deinit();
        self.eatWhitespaces(false);

        var pkg = blk: {
            if (self.peekToktypeIs(.left_paren)) {
                var tmp = ast.Package.init(self.allocator, true);
                errdefer tmp.deinit();
                try self.parseCommaArgs(&tmp.options.?);
                break :blk tmp;
            } else {
                break :blk ast.Package.init(self.allocator, false);
            }
        };
        errdefer pkg.deinit();
        pkg.name = try name.clone();

        switch (self.getPeekToktype()) {
            .newline => self.eatWhitespaces(true),
            .text, .raw_latex => {},
            .right_brace => {
                try packages.append(pkg);
                break;
            },
            .eof => {
                self.error_info = ErrorInfo{
                    .kind = .eof_found,
                    .span = self.peekTokenSpan(),
                };
                return error.ParseFailed;
            },
            else => {
                self.error_info = ErrorInfo{
                    .kind = .{ .type_mismatch = .{
                        .expected = &[_]token.Type{
                            .newline,
                            .right_brace,
                            .text,
                            .raw_latex,
                        },
                        .got = self.getPeekToktype(),
                    } },
                    .span = self.peekTokenSpan(),
                };
                return error.ParseFailed;
            },
        }
        try packages.append(pkg);
    }

    try self.expectPeek(&[_]token.Type{.right_brace}, self.peekTokenSpan());
    self.eatWhitespaces(false);
    if (self.peekToktypeIs(.newline)) {
        _ = self.nextToken();
    }

    return packages;
}

fn parseEndPhantomEnvironment(self: *Self) ParseError!ast.Statement {
    const endenv_span = self.peekTokenSpan();

    try self.expectPeek(&[_]token.Type{.phantom_endenv}, self.peekTokenSpan());
    self.eatWhitespaces(false);

    var name = ArrayList(u8).init(self.allocator);
    errdefer name.deinit();

    try name.appendSlice(blk: {
        switch (self.getPeekToktype()) {
            .text => break :blk self.nextToken().literal,
            .eof => {
                self.error_info = ErrorInfo{
                    .kind = .eof_found,
                    .span = endenv_span,
                };
                return error.ParseFailed;
            },
            else => {
                self.error_info = ErrorInfo{
                    .kind = .{ .name_miss = .phantom_endenv },
                    .span = endenv_span,
                };
                return error.ParseFailed;
            },
        }
    });

    while (self.peekToktypeIs(.star)) {
        try self.expectPeek(&[_]token.Type{.star}, self.peekTokenSpan());
        try name.append('*');
    }
    self.eatWhitespaces(false);

    return ast.Statement{ .phantom_end_environment = name };
}

fn parseEnvironment(self: *Self, comptime is_real: bool) ParseError!ast.Statement {
    const begenv_span = self.peekTokenSpan();
    var off_math_state = false;

    try self.expectPeek(
        &[_]token.Type{if (is_real) .begenv else .phantom_begenv},
        self.peekTokenSpan(),
    );
    self.eatWhitespaces(false);

    var name = ArrayList(u8).init(self.allocator);
    errdefer name.deinit();

    try name.appendSlice(blk: {
        switch (self.getPeekToktype()) {
            .text => break :blk self.nextToken().literal,
            .eof => {
                self.error_info = ErrorInfo{
                    .kind = if (is_real) .{ .is_not_closed = .{
                        .open = .begenv,
                        .close = .endenv,
                    } } else .eof_found,
                    .span = begenv_span,
                };
                return error.ParseFailed;
            },
            else => {
                self.error_info = ErrorInfo{
                    .kind = .{ .name_miss = if (is_real) .begenv else .phantom_begenv },
                    .span = begenv_span,
                };
                return error.ParseFailed;
            },
        }
    });

    // If name is math related one, then math mode will be turned on
    inline for (env_math_ident) |math_ident| {
        if (mem.eql(u8, math_ident, name.items)) {
            self.source.math_start = true;
            off_math_state = true;
            break;
        }
    }

    while (self.peekToktypeIs(.star)) {
        try self.expectPeek(&[_]token.Type{.star}, self.peekTokenSpan());
        try name.append('*');
    }
    self.eatWhitespaces(false);

    var args = ArrayList(ast.Argument).init(self.allocator);
    errdefer {
        for (args.items) |arg| {
            arg.deinit();
        }
        args.deinit();
    }
    try self.parseFunctionArgs(
        &args,
        .left_paren,
        .right_paren,
        .left_square_brace,
        .right_square_brace,
    );

    var text: ast.Latex = undefined;

    if (is_real) {
        text = ast.Latex.init(self.allocator);
        errdefer text.deinit();

        while (!self.peekToktypeIs(.endenv)) {
            if (self.peekToktypeIs(.eof)) {
                self.error_info = ErrorInfo{
                    .kind = .{ .is_not_closed = .{
                        .open = .begenv,
                        .close = .endenv,
                    } },
                    .span = begenv_span,
                };
                return error.ParseFailed;
            }
            const stmt = try self.parseStatement();
            errdefer stmt.deinit();
            try text.append(stmt);
        }

        try self.expectPeek(&[_]token.Type{.endenv}, self.peekTokenSpan());
    }

    // If name is math related one, then math mode will be turn off
    if (off_math_state) {
        self.source.math_start = false;
    }
    if (self.peekToktypeIs(.newline)) {
        _ = self.nextToken();
    }

    return if (is_real) ast.Statement{ .environment = .{
        .name = name,
        .args = args,
        .text = text,
    } } else ast.Statement{ .phantom_begin_environment = .{
        .name = name,
        .args = args,
    } };
}

fn parseFunctionDefinition(self: *Self) ParseError!ast.Statement {
    const begin_function_def_span = self.peekTokenSpan();
    var trim = ast.TrimWhitespace{
        .start = true,
        .end = true,
        .mid = null,
    };

    var style: ast.FunctionStyle = undefined;
    var beg_toktype: token.Type = undefined;

    switch (self.getPeekToktype()) {
        .eof => {
            self.error_info = ErrorInfo{
                .kind = .eof_found,
                .span = begin_function_def_span,
            };
            return error.ParseFailed;
        },
        else => |toktype| {
            // TODO: change error state properly
            style = ast.FunctionStyle.from_toktype(toktype) orelse {
                self.error_info = ErrorInfo{
                    .kind = .eof_found,
                    .span = begin_function_def_span,
                };
                return error.ParseFailed;
            };
            beg_toktype = toktype;
        },
    }
    try self.expectPeek(&[_]token.Type{beg_toktype}, self.peekTokenSpan());

    if (self.peekToktypeIs(.star)) {
        try self.expectPeek(&[_]token.Type{.star}, self.peekTokenSpan());
        trim.start = false;
    }
    self.eatWhitespaces(false);

    if (self.peekToktypeIs(.eof)) {
        self.error_info = ErrorInfo{
            .kind = .{ .is_not_closed = .{
                .open = beg_toktype,
                .close = .end_function_def,
            } },
            .span = begin_function_def_span,
        };
        return error.ParseFailed;
    }

    var name = ArrayList(u8).init(self.allocator);
    errdefer name.deinit();

    while (self.peekToktypeIs(.text) or self.peekToktypeIs(.argument_splitter)) {
        try name.appendSlice(switch (self.getPeekToktype()) {
            .eof => {
                self.error_info = ErrorInfo{
                    .kind = .eof_found,
                    .span = self.peekTokenSpan(),
                };
                return error.ParseFailed;
            },
            .text => self.nextToken().literal,
            .argument_splitter => blk: {
                _ = self.nextToken();
                break :blk "@";
            },
            else => {
                self.error_info = ErrorInfo{
                    .kind = .{ .type_mismatch = .{
                        .expected = &[_]token.Type{
                            .text,
                            .argument_splitter,
                        },
                        .got = self.getPeekToktype(),
                    } },
                    .span = self.peekTokenSpan(),
                };
                return error.ParseFailed;
            },
        });
    }
    self.eatWhitespaces(false);

    const args = try self.parseFunctionDefinitionArgument();
    errdefer args.deinit();

    const body = try self.parseFunctionDefinitionBody(&[_]token.Type{
        .function_def,
        .long_function_def,
        .outer_function_def,
        .long_outer_function_def,
        .e_function_def,
        .e_long_function_def,
        .e_outer_function_def,
        .e_long_outer_function_def,
        .g_function_def,
        .g_long_function_def,
        .g_outer_function_def,
        .g_long_outer_function_def,
        .x_function_def,
        .x_long_function_def,
        .x_outer_function_def,
        .x_long_outer_function_def,
    }, .end_function_def, beg_toktype, begin_function_def_span);
    errdefer body.deinit();

    if (self.peekToktypeIs(.star)) {
        try self.expectPeek(&[_]token.Type{.star}, self.peekTokenSpan());
        trim.end = false;
    }
    if (self.peekToktypeIs(.newline)) {
        _ = self.nextToken();
    }

    return ast.Statement{ .function_define = .{
        .style = style,
        .name = name,
        .args = args,
        .trim = trim,
        .body = body,
    } };
}

fn parseEnvironmentDefinition(self: *Self) ParseError!ast.Statement {
    const begin_env_def_span = self.peekTokenSpan();
    var trim = ast.TrimWhitespace{
        .start = true,
        .end = true,
        .mid = true,
    };

    var is_redefine: bool = undefined;
    var beg_toktype: token.Type = undefined;

    switch (self.getPeekToktype()) {
        .eof => {
            self.error_info = ErrorInfo{
                .kind = .eof_found,
                .span = begin_env_def_span,
            };
            return error.ParseFailed;
        },
        .defenv => {
            is_redefine = false;
            beg_toktype = .defenv;
        },
        .redefenv => {
            is_redefine = true;
            beg_toktype = .redefenv;
        },
        else => |got| {
            self.error_info = ErrorInfo{
                .kind = .{ .type_mismatch = .{
                    .expected = &[_]token.Type{ .defenv, .redefenv },
                    .got = got,
                } },
                .span = begin_env_def_span,
            };
            return error.ParseFailed;
        },
    }
    try self.expectPeek(&[_]token.Type{beg_toktype}, self.peekTokenSpan());

    if (self.peekToktypeIs(.star)) {
        try self.expectPeek(&[_]token.Type{.star}, self.peekTokenSpan());
        trim.start = false;
    }
    self.eatWhitespaces(false);

    if (self.isEof()) {
        self.error_info = ErrorInfo{
            .kind = .{ .is_not_closed = .{
                .open = beg_toktype,
                .close = .ends_with,
            } },
            .span = begin_env_def_span,
        };
        return error.ParseFailed;
    }

    var name = ArrayList(u8).init(self.allocator);
    errdefer name.deinit();

    while (true) {
        try name.appendSlice(switch (self.getPeekToktype()) {
            .text, .argument_splitter => self.nextToken().literal,
            .space, .tab, .newline, .left_square_brace => break,
            .eof => {
                self.error_info = ErrorInfo{
                    .kind = .eof_found,
                    .span = begin_env_def_span,
                };
                return error.ParseFailed;
            },
            else => {
                self.error_info = ErrorInfo{
                    .kind = .{ .name_miss = beg_toktype },
                    .span = begin_env_def_span,
                };
                return error.ParseFailed;
            },
        });
    }
    self.eatWhitespaces(false);

    var args_num: u8 = undefined;
    var optional_arg: ?ast.Latex = undefined;
    if (self.peekToktypeIs(.left_square_brace)) {
        try self.expectPeek(&[_]token.Type{.left_square_brace}, self.peekTokenSpan());

        args_num = switch (self.getPeekToktype()) {
            .integer => fmt.parseInt(u8, self.nextToken().literal, 10) catch {
                self.error_info = ErrorInfo{
                    .kind = .parse_int_failed,
                    .span = self.peekTokenSpan(),
                };
                return error.ParseFailed;
            },
            .eof => {
                self.error_info = ErrorInfo{
                    .kind = .eof_found,
                    .span = begin_env_def_span,
                };
                return error.ParseFailed;
            },
            else => |got| {
                self.error_info = ErrorInfo{
                    .kind = .{ .type_mismatch = .{
                        .expected = &[_]token.Type{.integer},
                        .got = got,
                    } },
                    .span = self.peekTokenSpan(),
                };
                return error.ParseFailed;
            },
        };

        optional_arg = switch (self.getPeekToktype()) {
            .comma => blk: {
                try self.expectPeek(&[_]token.Type{.comma}, self.peekTokenSpan());
                if (self.peekToktypeIs(.space)) {
                    _ = self.nextToken();
                }

                var tmp_inner = ast.Latex.init(self.allocator);
                errdefer tmp_inner.deinit();

                while (!self.peekToktypeIs(.right_square_brace)) {
                    if (self.isEof()) {
                        self.error_info = ErrorInfo{
                            .kind = .eof_found,
                            .span = begin_env_def_span,
                        };
                        return error.ParseFailed;
                    }
                    try tmp_inner.append(try self.parseStatement());
                }
                try self.expectPeek(&[_]token.Type{.right_square_brace}, self.peekTokenSpan());

                break :blk tmp_inner;
            },
            .right_square_brace => blk: {
                try self.expectPeek(&[_]token.Type{.right_square_brace}, self.peekTokenSpan());
                break :blk null;
            },
            .eof => {
                self.error_info = ErrorInfo{
                    .kind = .eof_found,
                    .span = begin_env_def_span,
                };
                return error.ParseFailed;
            },
            else => |got| {
                self.error_info = ErrorInfo{
                    .kind = .{ .type_mismatch = .{
                        .expected = &[_]token.Type{ .right_square_brace, .comma },
                        .got = got,
                    } },
                    .span = self.peekTokenSpan(),
                };
                return error.ParseFailed;
            },
        };
    } else {
        args_num = 0;
        optional_arg = null;
    }

    var begin_part = ast.Latex.init(self.allocator);
    errdefer begin_part.deinit();

    while (true) {
        switch (self.getPeekToktype()) {
            .defenv, .redefenv => {
                const defenv_stmt = try self.parseEnvironmentDefinition();
                errdefer defenv_stmt.deinit();
                try begin_part.append(defenv_stmt);
            },
            .ends_with => break,
            .endenv, .eof => {
                self.error_info = ErrorInfo{
                    .kind = .{
                        .is_not_closed = .{
                            .open = beg_toktype,
                            .close = .ends_with,
                        },
                    },
                    .span = begin_env_def_span,
                };
                return error.ParseFailed;
            },
            else => {
                self.doc_state.parsing_define = true;
                const stmt = try self.parseStatement();
                errdefer stmt.deinit();
                try begin_part.append(stmt);
                self.doc_state.parsing_define = false;
            },
        }
    }
    const mid_env_def_span = self.peekTokenSpan();
    try self.expectPeek(&[_]token.Type{.ends_with}, self.peekTokenSpan());

    if (self.peekToktypeIs(.star)) {
        try self.expectPeek(&[_]token.Type{.star}, self.peekTokenSpan());
        trim.mid = false;
    }

    var end_part = ast.Latex.init(self.allocator);
    errdefer end_part.deinit();

    while (true) {
        switch (self.getPeekToktype()) {
            .defenv, .redefenv => {
                const defenv_stmt = try self.parseEnvironmentDefinition();
                errdefer defenv_stmt.deinit();
                try begin_part.append(defenv_stmt);
            },
            .endenv => break,
            .ends_with, .eof => {
                self.error_info = ErrorInfo{
                    .kind = .{
                        .is_not_closed = .{
                            .open = .ends_with,
                            .close = .endenv,
                        },
                    },
                    .span = mid_env_def_span,
                };
                return error.ParseFailed;
            },
            else => {
                self.doc_state.parsing_define = true;
                const stmt = try self.parseStatement();
                errdefer stmt.deinit();
                try end_part.append(stmt);
                self.doc_state.parsing_define = false;
            },
        }
    }
    try self.expectPeek(&[_]token.Type{.endenv}, self.peekTokenSpan());

    if (self.peekToktypeIs(.star)) {
        try self.expectPeek(&[_]token.Type{.star}, self.peekTokenSpan());
        trim.end = false;
    }
    if (self.peekToktypeIs(.newline)) {
        _ = self.nextToken();
    }

    return ast.Statement{ .environment_define = .{
        .is_redefine = is_redefine,
        .name = name,
        .args_num = args_num,
        .optional_arg = optional_arg,
        .trim = trim,
        .begin_part = begin_part,
        .end_part = end_part,
    } };
}

fn takeName(self: *Self) ParseError!ArrayList(u8) {
    var output = ArrayList(u8).init(self.allocator);
    errdefer output.deinit();

    while (self.getPeekToktype().canPkgName()) {
        switch (self.getPeekToktype()) {
            .text, .minus, .integer => {
                output.appendSlice(self.nextToken().literal) catch return error.CannotGenerateName;
            },
            else => {
                self.error_info = ErrorInfo{
                    .kind = .{ .type_mismatch = .{
                        .expected = &[_]token.Type{ .text, .minus, .integer },
                        .got = self.peek_token.toktype,
                    } },
                    .span = self.peekTokenSpan(),
                };
                return error.ParseFailed;
            },
        }
    }

    return output;
}

fn parseFunctionDefinitionArgument(self: *Self) ParseError!ArrayList(u8) {
    const open_brace_span = self.peekTokenSpan();
    var output = ArrayList(u8).init(self.allocator);
    errdefer output.deinit();

    var parenthesis_level: isize = 0;
    var is_first_token = true;

    try self.expectPeek(&[_]token.Type{.left_paren}, open_brace_span);
    while (!self.peekToktypeIs(.eof) and parenthesis_level >= 0) {
        switch (self.getPeekToktype()) {
            .left_paren => parenthesis_level += 1,
            .right_paren => {
                parenthesis_level -= 1;
                if (parenthesis_level < 0) {
                    break;
                }
            },
            .eof => {
                self.error_info = ErrorInfo{
                    .kind = .bracket_number_mismatched,
                    .span = open_brace_span,
                };
                return error.ParseFailed;
            },
            else => {},
        }

        if (is_first_token and blk: {
            const toktype = self.getPeekToktype();
            break :blk toktype == .text or toktype.isKeyword();
        }) {
            try output.append(' ');
        }
        is_first_token = false;

        try output.appendSlice(self.nextToken().literal);
    }
    try self.expectPeek(&[_]token.Type{.right_paren}, open_brace_span);

    return output;
}

fn parseFunctionDefinitionBody(
    self: *Self,
    comptime beg_toktypes: []const token.Type,
    comptime end_toktype: token.Type,
    current_beg_toktype: token.Type,
    begin_span: location.Span,
) ParseError!ast.Latex {
    var body = ast.Latex.init(self.allocator);
    errdefer body.deinit();
    var def_level: isize = 0;

    while (!self.peekToktypeIs(end_toktype) and def_level >= 0) {
        switch (self.getPeekToktype()) {
            end_toktype => {
                def_level -= 1;
                if (def_level < 0) {
                    break;
                }
            },
            .eof => {
                self.error_info = ErrorInfo{
                    .kind = .{
                        .is_not_closed = .{
                            .open = current_beg_toktype,
                            .close = end_toktype,
                        },
                    },
                    .span = begin_span,
                };
                return error.ParseFailed;
            },
            else => |toktype| inline for (beg_toktypes) |beg_toktype| {
                if (beg_toktype == toktype) {
                    def_level += 1;
                    break;
                }
            },
        }

        self.doc_state.parsing_define = true;
        const stmt = try self.parseStatement();
        errdefer stmt.deinit();
        try body.append(stmt);
        self.doc_state.parsing_define = false;
    }
    try self.expectPeek(&[_]token.Type{end_toktype}, self.peekTokenSpan());

    return body;
}

fn parseCommaArgs(
    self: *Self,
    options: *ArrayList(ast.Latex),
) ParseError!void {
    const open_brace_span = self.peekTokenSpan();
    try self.expectPeek(&[_]token.Type{.left_paren}, open_brace_span);
    self.eatWhitespaces(true);

    while (!self.peekToktypeIs(.right_paren)) {
        if (self.isEof()) {
            self.error_info = ErrorInfo{
                .kind = .bracket_number_mismatched,
                .span = open_brace_span,
            };
            return error.ParseFailed;
        }
        self.eatWhitespaces(true);

        var tmp = ArrayList(ast.Statement).init(self.allocator);
        errdefer tmp.deinit();

        self.eatWhitespaces(true);
        while (!self.peekToktypeIs(.comma)) {
            switch (self.getPeekToktype()) {
                .right_paren => break,
                .eof => {
                    self.error_info = ErrorInfo{
                        .kind = .bracket_number_mismatched,
                        .span = open_brace_span,
                    };
                    return error.ParseFailed;
                },
                else => {
                    const stmt = try self.parseStatement();
                    errdefer stmt.deinit();
                    try tmp.append(stmt);
                },
            }
        }

        options.append(.{
            .stmts = ArrayList(ast.Statement).fromOwnedSlice(self.allocator, tmp.toOwnedSlice()),
        }) catch return error.ParseFailed;
        self.eatWhitespaces(true);

        if (self.peekToktypeIs(.right_paren)) {
            break;
        }

        try self.expectPeek(&[_]token.Type{.comma}, self.peekTokenSpan());
        self.eatWhitespaces(true);
    }

    try self.expectPeek(&[_]token.Type{.right_paren}, self.peekTokenSpan());
    self.eatWhitespaces(false);
}

fn parseFunctionArgs(
    self: *Self,
    args: *ArrayList(ast.Argument),
    comptime open: token.Type,
    comptime close: token.Type,
    comptime optional_open: token.Type,
    comptime optional_close: token.Type,
) ParseError!void {
    if (switch (self.getPeekToktype()) {
        open, optional_open, .star => true,
        else => false,
    }) {
        while (true) {
            switch (self.getPeekToktype()) {
                open => try self.parseFunctionArgsCore(
                    args,
                    open,
                    close,
                    .main_arg,
                ),
                optional_open => try self.parseFunctionArgsCore(
                    args,
                    optional_open,
                    optional_close,
                    .optional,
                ),
                .star => {
                    try self.expectPeek(&[_]token.Type{.star}, self.peekTokenSpan());
                    var arg = ast.Argument.init(self.allocator);
                    errdefer arg.deinit();
                    arg.arg_type = .star_arg;
                    try args.append(arg);
                },
                else => break,
            }

            if (self.peekToktypeIs(.eof) or self.peekToktypeIs(.newline)) {
                break;
            }
        }
    }
}

fn isArgSplitted(self: *Self) bool {
    return self.peekToktypeIs(.argument_splitter) or (self.peekToktypeIs(.space) and self.peek2ToktypeIs(.argument_splitter));
}

fn parseFunctionArgsCore(
    self: *Self,
    args: *ArrayList(ast.Argument),
    comptime open: token.Type,
    comptime close: token.Type,
    comptime arg_need: ast.ArgNeed,
) ParseError!void {
    const open_brace_span = self.peekTokenSpan();
    var nested: i32 = 0;
    try self.expectPeek(&[_]token.Type{open}, open_brace_span);

    while (true) {
        var stmt_lst = ArrayList(ast.Statement).init(self.allocator);
        errdefer {
            for (stmt_lst.items) |stmt| {
                stmt.deinit();
            }
            stmt_lst.deinit();
        }

        while ((!self.peekToktypeIs(close) or nested > 0) and !self.isArgSplitted()) {
            switch (self.getPeekToktype()) {
                .eof => {
                    self.error_info = ErrorInfo{
                        .kind = .bracket_number_mismatched,
                        .span = open_brace_span,
                    };
                    return error.ParseFailed;
                },
                open => nested += 1,
                close => nested -= 1,
                else => {},
            }

            const stmt = try self.parseStatement();
            errdefer stmt.deinit();
            try stmt_lst.append(stmt);
        }

        try args.append(.{
            .arg_type = arg_need,
            .inner = .{ .stmts = stmt_lst },
        });

        switch (self.getPeekToktype()) {
            .argument_splitter => try self.expectPeek(
                &[_]token.Type{.argument_splitter},
                self.peekTokenSpan(),
            ),
            .space => switch (self.getPeek2Toktype()) {
                .argument_splitter => {
                    try self.expectPeek(&[_]token.Type{.space}, self.peekTokenSpan());
                    try self.expectPeek(&[_]token.Type{.argument_splitter}, self.peekTokenSpan());
                },
                else => break,
            },
            else => break,
        }
        self.eatWhitespaces(true);
    }
    try self.expectPeek(&[_]token.Type{close}, self.peekTokenSpan());
}

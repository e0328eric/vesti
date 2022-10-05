const std = @import("std");
const ziglyph = @import("ziglyph");
const location = @import("location.zig");

const Token = @import("token.zig").Token;
const Type = @import("token.zig").Type;

fn isLatexFunctionIdent(chr: u21) bool {
    return chr == '@' or ziglyph.isAlphabetic(chr);
}

fn isOtherUnicode(chr: u21) bool {
    return ziglyph.isPrint(chr) and chr > 0xff and !ziglyph.isAlphaNum(chr);
}

pub const Lexer = @This();
const Self = @This();

// Lexer Fields
source: []const u8,
index: usize = 0,
location: location.Location,
math_start: bool = false,
// END Fields

const Chars = struct {
    chr0: ?u21,
    chr1: ?u21,
};

fn defaultLit(self: *const Self, start: usize) []const u8 {
    return self.source[start..self.index];
}

fn getChars(self: *Self, codepoint_len: *u3) Chars {
    var output: Chars = .{ .chr0 = null, .chr1 = null };
    if (self.index >= self.source.len) {
        return output;
    }
    codepoint_len.* = std.unicode.utf8ByteSequenceLength(self.source[self.index]) catch unreachable;
    output.chr0 = std.unicode.utf8Decode(self.source[self.index .. self.index + codepoint_len.*]) catch unreachable;
    if (self.index + codepoint_len.* >= self.source.len) {
        return output;
    }
    const next_codepoint_len = std.unicode.utf8ByteSequenceLength(self.source[self.index + codepoint_len.*]) catch unreachable;
    output.chr1 = std.unicode.utf8Decode(self.source[self.index + codepoint_len.* .. self.index + codepoint_len.* + next_codepoint_len]) catch unreachable;

    return output;
}

pub fn new(source: []const u8) Self {
    return .{ .source = source, .location = .{ .row = 1, .column = 1 } };
}

pub fn next(self: *Self) Token {
    var state: enum {
        start,
        minus,
        equal,
        slash,
        bang,
        less,
        great,
        percent,
        dollar,
        at,
        backslash,
        text,
        zero,
        integers,
        floats,
        etc_unicode,
        latex_function,
        line_comment,
        multi_line_comment,
        multi_line_comment_star,
        multi_line_comment_end,
        verbatim,
        verbatim_end,
    } = .start;

    var start_index = self.index;
    var start_location = self.location;
    var toktype: Type = .eof;
    var literal: []const u8 = "";

    var codepoint_len: u3 = undefined;
    while (self.index < self.source.len) : (self.index += codepoint_len) {
        const chars = self.getChars(&codepoint_len);
        const chr0 = chars.chr0.?;
        switch (state) {
            .start => switch (chr0) {
                ' ' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .space;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '\t' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .tab;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '\n' => {
                    self.index += 1;
                    self.location.newLine();
                    toktype = .newline;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '+' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .plus;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '*' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .star;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '.' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .period;
                    literal = self.defaultLit(start_index);
                    break;
                },
                ',' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .comma;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '?' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .question;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '&' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .ampersand;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '^' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .superscript;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '_' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .subscript;
                    literal = self.defaultLit(start_index);
                    break;
                },
                ';' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .semicolon;
                    literal = self.defaultLit(start_index);
                    break;
                },
                ':' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .colon;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '`' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .left_quote;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '\'' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .right_quote;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '"' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .double_quote;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '|' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .vert;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '~' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .tilde;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '(' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .left_paren;
                    literal = self.defaultLit(start_index);
                    break;
                },
                ')' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .right_paren;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '{' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .left_brace;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '}' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .right_brace;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '[' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .left_square_brace;
                    literal = self.defaultLit(start_index);
                    break;
                },
                ']' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .right_square_brace;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '#' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .function_param;
                    literal = self.defaultLit(start_index);
                    break;
                },
                '>' => {
                    self.location.moveRight(chr0);
                    state = .great;
                },
                '/' => {
                    self.location.moveRight(chr0);
                    state = .slash;
                },
                '!' => {
                    self.location.moveRight(chr0);
                    state = .bang;
                },
                '-' => {
                    self.location.moveRight(chr0);
                    state = .minus;
                },
                '=' => {
                    self.location.moveRight(chr0);
                    state = .equal;
                },
                '<' => {
                    self.location.moveRight(chr0);
                    state = .less;
                },
                '@' => {
                    self.location.moveRight(chr0);
                    state = .at;
                },
                '%' => {
                    self.location.moveRight(chr0);
                    state = .percent;
                },
                '$' => {
                    self.location.moveRight(chr0);
                    state = .dollar;
                },
                '\\' => {
                    self.location.moveRight(chr0);
                    state = .backslash;
                },
                '0' => {
                    self.location.moveRight(chr0);
                    state = .zero;
                },
                '1'...'9' => {
                    self.location.moveRight(chr0);
                    state = .integers;
                },
                else => if (ziglyph.isAlphaNum(chr0)) {
                    self.location.moveRight(chr0);
                    state = .text;
                } else if (isOtherUnicode(chr0)) {
                    self.location.moveRight(chr0);
                    state = .etc_unicode;
                } else {
                    self.index += 1;
                    toktype = .illegal;
                    literal = self.defaultLit(start_index);
                    break;
                },
            },
            .slash => switch (chr0) {
                '=' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .not_equal;
                    literal = "\\neq ";
                    break;
                },
                else => {
                    toktype = .slash;
                    literal = self.defaultLit(start_index);
                    break;
                },
            },
            .bang => switch (chr0) {
                '=' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .not_equal;
                    literal = "\\neq ";
                    break;
                },
                else => {
                    toktype = .bang;
                    literal = self.defaultLit(start_index);
                    break;
                },
            },
            .minus => switch (chr0) {
                '>' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .right_arrow;
                    literal = "\\to ";
                    break;
                },
                '0' => {
                    self.location.moveRight(chr0);
                    state = .zero;
                },
                '1'...'9' => {
                    self.location.moveRight(chr0);
                    state = .integers;
                },
                else => {
                    toktype = .minus;
                    literal = self.defaultLit(start_index);
                    break;
                },
            },
            .equal => switch (chr0) {
                '>' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .double_right_arrow;
                    literal = "\\Rightarrow ";
                    break;
                },
                else => {
                    toktype = .equal;
                    literal = self.defaultLit(start_index);
                    break;
                },
            },
            .great => switch (chr0) {
                '=' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .great_equal;
                    literal = "\\geq ";
                    break;
                },
                else => {
                    toktype = .great;
                    literal = self.defaultLit(start_index);
                    break;
                },
            },
            .less => switch (chr0) {
                '-' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .left_arrow;
                    literal = "\\leftarrow ";
                    break;
                },
                '=' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .less_equal;
                    literal = "\\leq ";
                    break;
                },
                else => {
                    toktype = .less;
                    literal = self.defaultLit(start_index);
                    break;
                },
            },
            .at => switch (chr0) {
                '!' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .at;
                    literal = "@";
                    break;
                },
                else => {
                    toktype = .argument_splitter;
                    literal = "@";
                    break;
                },
            },
            .percent => switch (chr0) {
                '!' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .latex_comment;
                    literal = "%";
                    break;
                },
                '-' => {
                    self.location.moveRight(chr0);
                    state = .verbatim;
                },
                '*' => {
                    self.location.moveRight(chr0);
                    state = .multi_line_comment;
                },
                '\n' => {
                    self.index += 1;
                    self.location.newLine();
                    toktype = .newline;
                    literal = "\n";
                    break;
                },
                else => {
                    self.location.moveRight(chr0);
                    state = .line_comment;
                },
            },
            .dollar => switch (chr0) {
                '!' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .raw_dollar;
                    literal = "$";
                    break;
                },
                '$' => if (self.math_start) {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .display_math_end;
                    literal = "\\]";
                    self.math_start = false;
                    break;
                } else {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .display_math_start;
                    literal = "\\[";
                    self.math_start = true;
                    break;
                },
                else => if (self.math_start) {
                    toktype = .text_math_end;
                    literal = "$";
                    self.math_start = false;
                    break;
                } else {
                    toktype = .text_math_start;
                    literal = "$";
                    self.math_start = true;
                    break;
                },
            },
            .backslash => switch (chr0) {
                '#' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .sharp;
                    literal = "\\#";
                    break;
                },
                '%' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .percent;
                    literal = "\\%";
                    break;
                },
                '$' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .dollar;
                    literal = "\\$";
                    break;
                },
                '(' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    self.math_start = true;
                    toktype = .text_math_start;
                    literal = "$";
                    break;
                },
                ')' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    self.math_start = false;
                    toktype = .text_math_end;
                    literal = "$";
                    break;
                },
                '[' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    self.math_start = true;
                    toktype = .display_math_start;
                    literal = "\\[";
                    break;
                },
                ']' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    self.math_start = false;
                    toktype = .display_math_end;
                    literal = "\\]";
                    break;
                },
                '{' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .math_left_brace;
                    literal = "\\{";
                    break;
                },
                '}' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .math_right_brace;
                    literal = "\\}";
                    break;
                },
                ' ' => if (self.math_start) {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .math_large_space;
                    literal = "\\;";
                    break;
                } else {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .force_space;
                    literal = "\\ ";
                    break;
                },
                '\\' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .backslash;
                    literal = "\\\\";
                    break;
                },
                else => if (isLatexFunctionIdent(chr0)) {
                    self.location.moveRight(chr0);
                    state = .latex_function;
                } else {
                    toktype = .short_backslash;
                    literal = "\\";
                    break;
                },
            },
            .text => if (!ziglyph.isAlphaNum(chr0)) {
                literal = self.defaultLit(start_index);
                toktype = Type.keywords.get(literal) orelse .text;
                break;
            } else {
                self.location.moveRight(chr0);
            },
            .zero => switch (chr0) {
                '0'...'9' => {
                    self.location.moveRight(chr0);
                    state = .text;
                },
                '.' => {
                    if (chars.chr1) |chr1| {
                        switch (chr1) {
                            '0'...'9' => {
                                self.location.moveRight(chr0);
                                state = .floats;
                            },
                            else => {
                                toktype = .integer;
                                literal = self.defaultLit(start_index);
                                break;
                            },
                        }
                    } else {
                        toktype = .integer;
                        literal = self.defaultLit(start_index);
                        break;
                    }
                },
                else => {
                    toktype = .integer;
                    literal = self.defaultLit(start_index);
                    break;
                },
            },
            .integers => {
                switch (chr0) {
                    '0'...'9' => self.location.moveRight(chr0),
                    '.' => {
                        if (chars.chr1) |chr1| {
                            switch (chr1) {
                                '0'...'9' => {
                                    self.location.moveRight(chr0);
                                    state = .floats;
                                },
                                else => {
                                    toktype = .integer;
                                    literal = self.defaultLit(start_index);
                                    break;
                                },
                            }
                        } else {
                            toktype = .integer;
                            literal = self.defaultLit(start_index);
                            break;
                        }
                    },
                    else => {
                        toktype = .integer;
                        literal = self.defaultLit(start_index);
                        break;
                    },
                }
            },
            .floats => {
                switch (chr0) {
                    '0'...'9' => self.location.moveRight(chr0),
                    else => {
                        toktype = .float;
                        literal = self.defaultLit(start_index);
                        break;
                    },
                }
            },
            .etc_unicode => if (!isOtherUnicode(chr0)) {
                toktype = .other_unicode_char;
                literal = self.defaultLit(start_index);
                break;
            },
            .latex_function => if (!isLatexFunctionIdent(chr0)) {
                toktype = .latex_function;
                literal = self.defaultLit(start_index);
                break;
            } else {
                self.location.moveRight(chr0);
            },
            .line_comment => switch (chr0) {
                '\n' => {
                    self.index += 1;
                    self.location.newLine();
                    toktype = .newline;
                    literal = "\n";
                    break;
                },
                '\r' => unreachable,
                else => self.location.moveRight(chr0),
            },
            .multi_line_comment => switch (chr0) {
                '*' => {
                    self.location.moveRight(chr0);
                    state = .multi_line_comment_star;
                },
                '\n' => self.location.newLine(),
                else => self.location.moveRight(chr0),
            },
            .multi_line_comment_star => switch (chr0) {
                '%' => {
                    self.location.moveRight(chr0);
                    state = .multi_line_comment_end;
                },
                '*' => self.location.moveRight(chr0),
                '\n' => {
                    self.location.newLine();
                    state = .multi_line_comment;
                },
                else => {
                    self.location.moveRight(chr0);
                    state = .multi_line_comment;
                },
            },
            .multi_line_comment_end => switch (chr0) {
                '\n' => {
                    self.index += 1;
                    self.location.newLine();
                    toktype = .newline;
                    literal = "\n";
                    break;
                },
                '\r' => unreachable,
                ' ' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .space;
                    literal = " ";
                    break;
                },
                '\t' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .tab;
                    literal = "\t";
                    break;
                },
                else => {
                    toktype = .nop;
                    literal = "";
                    break;
                },
            },
            .verbatim => switch (chr0) {
                '-' => {
                    self.location.moveRight(chr0);
                    state = .verbatim_end;
                },
                '\n' => self.location.newLine(),
                else => self.location.moveRight(chr0),
            },
            .verbatim_end => switch (chr0) {
                '%' => {
                    self.index += 1;
                    self.location.moveRight(chr0);
                    toktype = .raw_latex;
                    literal = self.source[start_index + 2 .. self.index - 2];
                    break;
                },
                '-' => self.location.moveRight(chr0),
                '\n' => {
                    self.location.newLine();
                    state = .verbatim;
                },
                else => {
                    self.location.moveRight(chr0);
                    state = .verbatim;
                },
            },
        }
    } else if (self.index >= self.source.len) {
        switch (state) {
            .start, .line_comment, .percent => {},
            .minus => {
                toktype = .minus;
                literal = "-";
            },
            .equal => {
                toktype = .equal;
                literal = "=";
            },
            .slash => {
                toktype = .slash;
                literal = "/";
            },
            .bang => {
                toktype = .bang;
                literal = "!";
            },
            .less => {
                toktype = .less;
                literal = "<";
            },
            .great => {
                toktype = .great;
                literal = ">";
            },
            .at => {
                toktype = .argument_splitter;
                literal = "";
            },
            .dollar => if (self.math_start) {
                toktype = .text_math_end;
                literal = "$";
            } else {
                toktype = .text_math_start;
                literal = "$";
            },
            .text => {
                literal = self.defaultLit(start_index);
                toktype = Type.keywords.get(literal) orelse .text;
            },
            .zero => {
                toktype = .integer;
                literal = self.defaultLit(start_index);
            },
            .integers => {
                toktype = .integer;
                literal = self.defaultLit(start_index);
            },
            .floats => {
                toktype = .float;
                literal = self.defaultLit(start_index);
            },
            .etc_unicode => {
                toktype = .other_unicode_char;
                literal = self.defaultLit(start_index);
            },
            .latex_function => {
                toktype = .latex_function;
                literal = self.defaultLit(start_index);
            },
            .multi_line_comment_end => {
                toktype = .newline;
                literal = "\n";
            },
            .backslash,
            .multi_line_comment,
            .multi_line_comment_star,
            .verbatim,
            .verbatim_end,
            => toktype = .illegal,
        }
    }

    return .{
        .toktype = toktype,
        .literal = literal,
        .span = .{ .start = start_location, .end = self.location },
    };
}

const std = @import("std");
const ziglyph = @import("ziglyph");
const unicode = std.unicode;
const fmt = std.fmt;
const mem = std.mem;

const assert = std.debug.assert;

const Allocator = mem.Allocator;
const Location = @import("../location.zig").Location;
const Span = @import("../location.zig").Span;
const Token = @import("Token.zig");
const TokenType = Token.TokenType;

source: []const u8,
chr0_idx: usize,
chr1_idx: usize,
chr2_idx: usize,
location: Location,
make_at_letter: bool,
is_latex3_on: bool,
lex_finished: bool,

const Self = @This();

pub fn init(source: []const u8) !Self {
    var self: Self = undefined;

    self.source = source;
    self.chr0_idx = 0;
    self.chr1_idx = 0;
    self.chr2_idx = 0;
    self.location = Location{};
    self.make_at_letter = false;
    self.is_latex3_on = false;
    self.lex_finished = false;

    self.nextChar(2);
    self.location = Location{};

    return self;
}

fn nextChar(self: *Self, comptime amount: usize) void {
    comptime assert(amount >= 1 and amount <= 3);

    comptime var i = 0;
    inline while (i < amount) : (i += 1) {
        const chr = self.getChar(.current);
        if (self.chr0_idx >= self.source.len) {
            self.lex_finished = true;
            return;
        } else if (self.chr1_idx >= self.source.len) {
            const chr0_len = unicode.utf8ByteSequenceLength(self.source[self.chr0_idx]) catch
                @panic("given vesti file is not encoded into UTF-8");
            self.chr0_idx += chr0_len;
        } else if (self.chr2_idx >= self.source.len) {
            const chr1_len = unicode.utf8ByteSequenceLength(self.source[self.chr1_idx]) catch
                @panic("given vesti file is not encoded into UTF-8");
            self.chr0_idx = self.chr1_idx;
            self.chr1_idx += chr1_len;
        } else {
            @branchHint(.likely);
            const chr2_len = unicode.utf8ByteSequenceLength(self.source[self.chr2_idx]) catch
                @panic("given vesti file is not encoded into UTF-8");
            self.chr0_idx = self.chr1_idx;
            self.chr1_idx = self.chr2_idx;
            self.chr2_idx += chr2_len;
        }

        self.location.move(chr);
    }
}

const GetCharType = enum(u2) {
    current,
    peek1,
    peek2,
};

fn getChar(self: Self, comptime get_char_t: GetCharType) u21 {
    const field_idx = switch (get_char_t) {
        .current => "0",
        .peek1 => "1",
        .peek2 => "2",
    };

    const start = @field(self, "chr" ++ field_idx ++ "_idx");
    if (start >= self.source.len) return 0;

    const len = unicode.utf8ByteSequenceLength(self.source[start]) catch
        @panic("given vesti file is not encoded into UTF-8");

    const output = switch (len) {
        1 => self.source[start],
        2 => unicode.utf8Decode2(self.source[start..][0..2].*) catch unreachable,
        3 => unicode.utf8Decode3(self.source[start..][0..3].*) catch unreachable,
        4 => unicode.utf8Decode4(self.source[start..][0..4].*) catch unreachable,
        else => unreachable,
    };
    return output;
}

const TokenizeState = enum {
    start,
    comment,
    multiline_comment,
    verbatim,
    line_verbatim,
    fnt_param,
    latex_function,
    text,
    integer,
    float,
    o_chr,
    percent_chr,
    backslash_chr,
    sharp_chr,
    less_chr,
};

pub fn nextRaw(self: *Self) Token {
    var token: Token = undefined;

    const start_location = self.location;
    const chr = self.getChar(.current);
    const start = self.chr0_idx;
    const len =
        unicode.utf8CodepointSequenceLength(self.getChar(.current)) catch unreachable;

    self.nextChar(1);
    token.init(
        self.source[start .. start + len],
        null,
        .{ .RawChar = .{ .start = start, .end = start + len, .chr = chr } },
        start_location,
        self.location,
    );

    return token;
}

pub fn next(self: *Self) Token {
    var token: Token = undefined;
    var start_location = self.location;
    var start_chr0_idx = self.chr0_idx;

    if (self.lex_finished) {
        self.str2Token("\x00", &token, start_location);
        return token;
    }

    tokenize: switch (TokenizeState.start) {
        .start => switch (self.getChar(.current)) {
            // why windows' EOL is \r\n?
            '\r' => {
                if (self.getChar(.peek1) == '\n') {
                    self.nextChar(2);
                } else {
                    self.nextChar(1);
                }
                self.str2Token("\n", &token, start_location);
                break :tokenize;
            },
            '%' => {
                self.nextChar(1);
                continue :tokenize .percent_chr;
            },
            'o' => {
                start_chr0_idx = self.chr0_idx;
                self.nextChar(1);
                continue :tokenize .o_chr;
            },
            '-' => switch (self.getChar(.peek1)) {
                '-' => if (self.getChar(.peek2) == '>') {
                    self.nextChar(3);
                    self.str2Token("-->", &token, start_location);
                    break :tokenize;
                } else {
                    self.nextChar(2);
                    self.str2Token("--", &token, start_location);
                    break :tokenize;
                },
                '>' => {
                    self.nextChar(2);
                    self.str2Token("->", &token, start_location);
                    break :tokenize;
                },
                '.' => {
                    start_chr0_idx = self.chr0_idx;
                    self.nextChar(1);
                    continue :tokenize .float;
                },
                else => |chr| if (ziglyph.isDecimal(chr)) {
                    start_chr0_idx = self.chr0_idx;
                    self.nextChar(1);
                    continue :tokenize .integer;
                } else {
                    self.nextChar(1);
                    self.str2Token("-", &token, start_location);
                    break :tokenize;
                },
            },
            '!' => if (self.getChar(.peek1) == '=') {
                self.nextChar(2);
                self.str2Token("!=", &token, start_location);
                break :tokenize;
            } else {
                self.nextChar(1);
                self.str2Token("!", &token, start_location);
                break :tokenize;
            },
            '/' => switch (self.getChar(.peek1)) {
                '=' => {
                    self.nextChar(2);
                    self.str2Token("!=", &token, start_location);
                    break :tokenize;
                },
                '/' => {
                    self.nextChar(2);
                    self.str2Token("//", &token, start_location);
                    break :tokenize;
                },
                else => {
                    self.nextChar(1);
                    self.str2Token("/", &token, start_location);
                    break :tokenize;
                },
            },
            '$' => switch (self.getChar(.peek1)) {
                '!' => {
                    self.nextChar(2);
                    self.str2Token("$!", &token, start_location);
                    break :tokenize;
                },
                '$' => {
                    self.nextChar(2);
                    self.str2Token("$$", &token, start_location);
                    break :tokenize;
                },
                else => {
                    self.nextChar(1);
                    self.str2Token("$", &token, start_location);
                    break :tokenize;
                },
            },
            '.' => if (self.getChar(.peek1) == '.' and
                self.getChar(.peek2) == '.')
            {
                self.nextChar(3);
                self.str2Token("...", &token, start_location);
                break :tokenize;
            } else if (ziglyph.isDecimal(self.getChar(.peek1))) {
                start_chr0_idx = self.chr0_idx;
                self.nextChar(1);
                continue :tokenize .float;
            } else {
                self.nextChar(1);
                self.str2Token(".", &token, start_location);
                break :tokenize;
            },
            '|' => if (self.getChar(.peek1) == '|') {
                self.nextChar(2);
                self.str2Token("||", &token, start_location);
                break :tokenize;
            } else if (self.getChar(.peek1) == '-' and
                self.getChar(.peek2) == '>')
            {
                self.nextChar(3);
                self.str2Token("|->", &token, start_location);
                break :tokenize;
            } else {
                self.nextChar(1);
                self.str2Token("|", &token, start_location);
                break :tokenize;
            },
            '=' => switch (self.getChar(.peek1)) {
                '=' => if (self.getChar(.peek2) == '>') {
                    self.nextChar(3);
                    self.str2Token("==>", &token, start_location);
                    break :tokenize;
                } else {
                    self.nextChar(2);
                    self.str2Token("==", &token, start_location);
                    break :tokenize;
                },
                '>' => {
                    self.nextChar(2);
                    self.str2Token("=>", &token, start_location);
                    break :tokenize;
                },
                else => {
                    self.nextChar(1);
                    self.str2Token("=", &token, start_location);
                    break :tokenize;
                },
            },
            '>' => switch (self.getChar(.peek1)) {
                '=' => {
                    self.nextChar(2);
                    self.str2Token(">=", &token, start_location);
                    break :tokenize;
                },
                '}' => {
                    self.nextChar(2);
                    self.str2Token(">}", &token, start_location);
                    break :tokenize;
                },
                else => {
                    self.nextChar(1);
                    self.str2Token(">", &token, start_location);
                    break :tokenize;
                },
            },
            '{' => if (self.getChar(.peek1) == '<') {
                self.nextChar(2);
                self.str2Token("{<", &token, start_location);
                break :tokenize;
            } else {
                self.nextChar(1);
                self.str2Token("{", &token, start_location);
                break :tokenize;
            },
            '\\' => {
                start_chr0_idx = self.chr0_idx;
                self.nextChar(1);
                continue :tokenize .backslash_chr;
            },
            '#' => {
                start_chr0_idx = self.chr0_idx;
                self.nextChar(1);
                continue :tokenize .sharp_chr;
            },
            '<' => {
                self.nextChar(1);
                continue :tokenize .less_chr;
            },
            inline 0,
            '\n',
            '\t',
            ' ',
            '+',
            '*',
            '?',
            '@',
            '^',
            '_',
            '&',
            ',',
            ':',
            ';',
            '~',
            '`',
            '\'',
            '"',
            '}',
            '[',
            ']',
            '(',
            ')',
            => |chr| {
                self.nextChar(1);
                self.str2Token(&[1]u8{@intCast(chr)}, &token, start_location);
                break :tokenize;
            },
            else => |chr| if (ziglyph.isDecimal(chr)) {
                start_chr0_idx = self.chr0_idx;
                self.nextChar(1);
                continue :tokenize .integer;
            } else if (ziglyph.isAlphabetic(chr)) {
                start_chr0_idx = self.chr0_idx;
                self.nextChar(1);
                continue :tokenize .text;
            } else {
                self.nextChar(1);
                var buf: [4]u8 = @splat(0);
                const codepoint_len = unicode.utf8Encode(chr, &buf) catch {
                    token.init("<???>", null, .Illegal, start_location, self.location);
                    break :tokenize;
                };
                token.init(
                    buf[0..codepoint_len],
                    null,
                    .OtherChar,
                    start_location,
                    self.location,
                );
                break :tokenize;
            },
        },
        .o_chr => if (self.getChar(.current) == 'o' and
            !ziglyph.isAlphabetic(self.getChar(.peek1)))
        {
            self.nextChar(1);
            self.str2Token("oo", &token, start_location);
            break :tokenize;
        } else continue :tokenize .text,
        .percent_chr => switch (self.getChar(.current)) {
            '*' => {
                self.nextChar(1);
                continue :tokenize .multiline_comment;
            },
            '#' => {
                self.nextChar(1);
                start_chr0_idx = self.chr0_idx;
                continue :tokenize .line_verbatim;
            },
            '-' => if (self.getChar(.peek1) == '#') {
                self.nextChar(2);
                self.str2Token("%-#", &token, start_location);
                break :tokenize;
            } else {
                self.nextChar(1);
                start_chr0_idx = self.chr0_idx;
                continue :tokenize .verbatim;
            },
            '!' => {
                self.nextChar(1);
                self.str2Token("%!", &token, start_location);
                break :tokenize;
            },
            else => {
                self.nextChar(1);
                continue :tokenize .comment;
            },
        },
        .sharp_chr => if (ziglyph.isAlphabetic(self.getChar(.current)) or
            ziglyph.isDecimal(self.getChar(.current)))
        {
            self.nextChar(1);
            continue :tokenize .fnt_param;
        } else {
            self.str2Token("#", &token, start_location);
            break :tokenize;
        },
        .backslash_chr => switch (self.getChar(.current)) {
            '\\' => {
                self.nextChar(1);
                self.str2Token("\\\\", &token, start_location);
                break :tokenize;
            },
            '#' => {
                self.nextChar(1);
                self.str2Token("\\#", &token, start_location);
                break :tokenize;
            },
            '$' => {
                self.nextChar(1);
                self.str2Token("\\$", &token, start_location);
                break :tokenize;
            },
            '%' => {
                self.nextChar(1);
                self.str2Token("\\%", &token, start_location);
                break :tokenize;
            },
            '[' => {
                self.nextChar(1);
                self.str2Token("\\[", &token, start_location);
                break :tokenize;
            },
            ']' => {
                self.nextChar(1);
                self.str2Token("\\]", &token, start_location);
                break :tokenize;
            },
            '{' => {
                self.nextChar(1);
                self.str2Token("\\{", &token, start_location);
                break :tokenize;
            },
            '}' => {
                self.nextChar(1);
                self.str2Token("\\}", &token, start_location);
                break :tokenize;
            },
            ',' => {
                self.nextChar(1);
                self.str2Token("\\,", &token, start_location);
                break :tokenize;
            },
            ';' => {
                self.nextChar(1);
                self.str2Token("\\;", &token, start_location);
                break :tokenize;
            },
            ' ' => {
                self.nextChar(1);
                self.str2Token("\\ ", &token, start_location);
                break :tokenize;
            },
            else => |chr| if (isVestiIdentChar(
                chr,
                self.make_at_letter,
                self.is_latex3_on,
            )) {
                self.nextChar(1);
                continue :tokenize .latex_function;
            } else {
                self.str2Token("\\", &token, start_location);
                break :tokenize;
            },
        },
        .less_chr => switch (self.getChar(.current)) {
            '=' => switch (self.getChar(.peek1)) {
                '=' => if (self.getChar(.peek2) == '>') {
                    self.nextChar(3);
                    self.str2Token("<==>", &token, start_location);
                    break :tokenize;
                } else {
                    self.nextChar(2);
                    self.str2Token("<==", &token, start_location);
                    break :tokenize;
                },
                '>' => {
                    self.nextChar(2);
                    self.str2Token("<=>", &token, start_location);
                    break :tokenize;
                },
                else => {
                    self.nextChar(1);
                    self.str2Token("<=", &token, start_location);
                    break :tokenize;
                },
            },
            '-' => switch (self.getChar(.peek1)) {
                '-' => if (self.getChar(.peek2) == '>') {
                    self.nextChar(3);
                    self.str2Token("<-->", &token, start_location);
                    break :tokenize;
                } else {
                    self.nextChar(2);
                    self.str2Token("<--", &token, start_location);
                    break :tokenize;
                },
                '>' => {
                    self.nextChar(2);
                    self.str2Token("<->", &token, start_location);
                    break :tokenize;
                },
                else => {
                    self.nextChar(1);
                    self.str2Token("<-", &token, start_location);
                    break :tokenize;
                },
            },
            else => {
                self.str2Token("<", &token, start_location);
                break :tokenize;
            },
        },
        .text => if (ziglyph.isAlphabetic(self.getChar(.current)) or
            ziglyph.isDecimal(self.getChar(.current)))
        {
            self.nextChar(1);
            continue :tokenize .text;
        } else {
            const lexed_text = self.source[start_chr0_idx..self.chr0_idx];
            if (Token.VESTI_KEYWORDS.get(lexed_text)) |toktype| {
                switch (toktype) {
                    .MakeAtLetter => self.make_at_letter = true,
                    .MakeAtOther => self.make_at_letter = false,
                    .Latex3On => self.is_latex3_on = true,
                    .Latex3Off => self.is_latex3_on = false,
                    else => {},
                }
                token.init(lexed_text, null, toktype, start_location, self.location);
            } else {
                token.init(lexed_text, null, .Text, start_location, self.location);
            }
            break :tokenize;
        },
        .fnt_param => if (ziglyph.isAlphabetic(self.getChar(.current)) or
            ziglyph.isDecimal(self.getChar(.current)))
        {
            self.nextChar(1);
            continue :tokenize .fnt_param;
        } else {
            token.init(
                self.source[start_chr0_idx..self.chr0_idx],
                null,
                .FntParam,
                start_location,
                self.location,
            );
            break :tokenize;
        },
        .latex_function => if (isVestiIdentChar(
            self.getChar(.current),
            self.make_at_letter,
            self.is_latex3_on,
        )) {
            self.nextChar(1);
            continue :tokenize .latex_function;
        } else {
            const toktype: TokenType = if (self.make_at_letter)
                .MakeAtLetterFnt
            else if (self.is_latex3_on)
                .Latex3Fnt
            else
                .LatexFunction;
            token.init(
                self.source[start_chr0_idx..self.chr0_idx],
                null,
                toktype,
                start_location,
                self.location,
            );
            break :tokenize;
        },
        .integer => if (ziglyph.isDecimal(self.getChar(.current))) {
            self.nextChar(1);
            continue :tokenize .integer;
        } else if (self.getChar(.current) == '.') {
            self.nextChar(1);
            continue :tokenize .float;
        } else {
            token.init(
                self.source[start_chr0_idx..self.chr0_idx],
                null,
                .Integer,
                start_location,
                self.location,
            );
            break :tokenize;
        },
        .float => if (ziglyph.isDecimal(self.getChar(.current))) {
            self.nextChar(1);
            continue :tokenize .float;
        } else {
            token.init(
                self.source[start_chr0_idx..self.chr0_idx],
                null,
                .Float,
                start_location,
                self.location,
            );
            break :tokenize;
        },
        .comment => switch (self.getChar(.current)) {
            '\n', 0 => {
                self.nextChar(1);
                start_location = self.location;
                continue :tokenize .start;
            },
            else => {
                self.nextChar(1);
                continue :tokenize .comment;
            },
        },
        .multiline_comment => if (self.getChar(.current) == '*' and
            self.getChar(.peek1) == '%')
        {
            self.nextChar(2);
            start_location = self.location;
            continue :tokenize .start;
        } else if (self.getChar(.current) == 0) {
            self.nextChar(1);
            continue :tokenize .start;
        } else {
            self.nextChar(1);
            continue :tokenize .multiline_comment;
        },
        .verbatim => if (self.getChar(.current) == '-' and
            self.getChar(.peek1) == '%')
        {
            token.init(
                self.source[start_chr0_idx..self.chr0_idx],
                null,
                .RawLatex,
                start_location,
                self.location,
            );
            self.nextChar(2);
            break :tokenize;
        } else if (self.getChar(.current) == 0) {
            token.init(
                self.source[start_chr0_idx..self.chr0_idx],
                null,
                .Illegal,
                start_location,
                self.location,
            );
            self.nextChar(1);
            break :tokenize;
        } else {
            self.nextChar(1);
            continue :tokenize .verbatim;
        },
        .line_verbatim => switch (self.getChar(.current)) {
            '\n' => {
                self.nextChar(1);
                token.init(
                    self.source[start_chr0_idx..self.chr0_idx],
                    null,
                    .RawLatex,
                    start_location,
                    self.location,
                );
                break :tokenize;
            },
            0 => {
                token.init(
                    self.source[start_chr0_idx..self.chr0_idx],
                    null,
                    .Illegal,
                    start_location,
                    self.location,
                );
                self.nextChar(1);
                break :tokenize;
            },
            else => {
                self.nextChar(1);
                continue :tokenize .line_verbatim;
            },
        },
    }

    return token;
}

const STR_TOKEN_TABLE = std.StaticStringMap(struct {
    []const u8,
    ?[]const u8,
    TokenType,
}).initComptime(.{
    .{ "\x00", .{ "", null, .Eof } },
    .{ "\n", .{ "\n", null, .Newline } },
    .{ "\t", .{ "\t", null, .Tab } },
    .{ " ", .{ " ", null, .Space } },
    .{ "+", .{ "+", null, .Plus } },
    .{ "-", .{ "-", null, .Minus } },
    .{ "*", .{ "*", null, .Star } },
    .{ "/", .{ "/", null, .Slash } },
    .{ "//", .{ "//", null, .FracDefiner } },
    .{ "=", .{ "=", null, .Equal } },
    .{ "==", .{ "==", null, .EqEq } },
    .{ "<", .{ "<", null, .Less } },
    .{ ">", .{ ">", null, .Great } },
    .{ "<=", .{ "<=", "\\leq ", .LessEq } },
    .{ ">=", .{ ">=", "\\geq ", .GreatEq } },
    .{ "/=", .{ "/=", "\\neq ", .NotEqual } },
    .{ "!=", .{ "!=", "\\neq ", .NotEqual } },
    .{ "<-", .{ "<-", "\\leftarrow ", .LeftArrow } },
    .{ "->", .{ "->", "\\rightarrow ", .RightArrow } },
    .{ "=>", .{ "=>", "\\Rightarrow ", .DoubleRightArrow } },
    .{ "<--", .{ "<--", "\\longleftarrow ", .LongLeftArrow } },
    .{ "-->", .{ "-->", "\\longrightarrow ", .LongRightArrow } },
    .{ "<==", .{ "<==", "\\Longleftarrow ", .LongDoubleLeftArrow } },
    .{ "==>", .{ "==>", "\\Longrightarrow ", .LongDoubleRightArrow } },
    .{ "<->", .{ "<->", "\\leftrightarrow ", .LeftRightArrow } },
    .{ "<=>", .{ "<=>", "\\Leftrightarrow ", .DoubleLeftRightArrow } },
    .{ "<-->", .{ "<-->", "\\longleftrightarrow ", .LongLeftRightArrow } },
    .{ "<==>", .{ "<==>", "\\Longleftrightarrow ", .LongDoubleLeftRightArrow } },
    .{ "|->", .{ "|->", "\\mapsto ", .MapsTo } },
    .{ "{", .{ "{", null, .Lbrace } },
    .{ "}", .{ "}", null, .Rbrace } },
    .{ "[", .{ "[", null, .Lsqbrace } },
    .{ "]", .{ "]", null, .Rsqbrace } },
    .{ "(", .{ "(", null, .Lparen } },
    .{ ")", .{ ")", null, .Rparen } },
    .{ "{<", .{ "{>", "\\langle ", .Langle } },
    .{ ">}", .{ ">}", "\\rangle ", .Rangle } },
    .{ "\\{", .{ "\\{", null, .MathLbrace } },
    .{ "\\}", .{ "\\}", null, .MathRbrace } },
    .{ "$", .{ "$", null, .InlineMathSwitch } },
    .{ "$$", .{ "$$", null, .DisplayMathSwitch } },
    .{ "\\[", .{ "\\[", null, .DisplayMathStart } },
    .{ "\\]", .{ "\\]", null, .DisplayMathEnd } },
    .{ "\\,", .{ "\\,", null, .MathSmallSpace } },
    .{ "\\;", .{ "\\;", null, .MathLargeSpace } },
    .{ "\\ ", .{ "\\ ", "\\;", .MathLargeSpace } },
    .{ "\\", .{ "\\", null, .ShortBackSlash } },
    .{ "\\\\", .{ "\\\\", null, .BackSlash } },
    .{ "@", .{ "@", null, .At } },
    .{ "^", .{ "^", null, .Superscript } },
    .{ "_", .{ "_", null, .Subscript } },
    .{ "!", .{ "!", null, .Bang } },
    .{ "?", .{ "?", null, .Question } },
    .{ "%!", .{ "%", null, .LatexComment } },
    .{ "\\%", .{ "\\%", null, .TextPercent } },
    .{ "#", .{ "#", null, .RawSharp } },
    .{ "\\#", .{ "\\#", null, .TextSharp } },
    .{ "$!", .{ "$", null, .RawDollar } },
    .{ "\\$", .{ "\\$", null, .TextDollar } },
    .{ ":", .{ ":", null, .Colon } },
    .{ ";", .{ ";", null, .Semicolon } },
    .{ ".", .{ ".", null, .Period } },
    .{ ",", .{ ",", null, .Comma } },
    .{ "--", .{ "--", "\\setminus ", .SetMinus } },
    .{ "|", .{ "|", null, .Vert } },
    .{ "||", .{ "||", "\\|", .Norm } },
    .{ "&", .{ "&", null, .Ampersand } },
    .{ "~", .{ "~", null, .Tilde } },
    .{ "`", .{ "`", null, .LeftQuote } },
    .{ "'", .{ "'", null, .RightQuote } },
    .{ "\"", .{ "\"", null, .DoubleQuote } },
    .{ "...", .{ "...", "\\cdots ", .CenterDots } },
    .{ "oo", .{ "oo", "\\infty ", .InfinitySym } },
    .{ "%-#", .{ "", "", TokenType{ .Deprecated = .{ .valid_in_text = false, .instead = "%#" } } } },
});

fn str2Token(self: Self, comptime str: []const u8, token: *Token, loc: Location) void {
    const info = comptime STR_TOKEN_TABLE.get(str) orelse @compileError(std.fmt.comptimePrint(
        "String `{s}` is not supported",
        .{str},
    ));
    token.init(info[0], info[1], info[2], loc, self.location);
}

fn isVestiIdentChar(
    chr: u21,
    subscript_as_letter: bool,
    is_latex3: bool,
) bool {
    return ((chr >= 'A' and chr <= 'Z') or (chr >= 'a' and chr <= 'z')) or
        (subscript_as_letter and chr == '_') or
        (is_latex3 and (chr == '_' or chr == ':'));
}

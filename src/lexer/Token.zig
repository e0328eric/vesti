const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;

const Location = @import("../location.zig").Location;
const Span = @import("../location.zig").Span;

toktype: TokenType,
lit: Literal,
span: Span,

const Self = @This();

pub const Literal = struct {
    in_text: []const u8,
    in_math: []const u8,

    const Self = @This();
};

pub const TokenType = union(enum(u8)) {
    // EOF character
    Eof = 0,

    // Whitespace
    Space,
    Tab,
    Newline,
    MathSmallSpace, // \,
    MathLargeSpace, // \;

    // Identifiers
    Integer,
    Float,
    Text,
    LatexFunction,
    MakeAtLetterFnt,
    Latex3Fnt,
    RawLatex,
    OtherChar,
    RawChar: u21,

    // Keywords
    __begin_keywords, // NOTE: this is a meta token type, not the actual one.
    Docclass,
    ImportPkg,
    ImportVesti,
    ImportFile,
    ImportModule,
    ImportLatex3,
    GetFilePath,
    StartDoc,
    Useenv,
    Begenv,
    Endenv,
    MakeAtLetter,
    MakeAtOther,
    Latex3On,
    Latex3Off,
    NonStopMode,
    __end_keywords, // NOTE: this is a meta token type, not in actual usage

    // Symbols
    Plus, // +
    Minus, // -
    SetMinus, // --
    Star, // *
    Slash, // /
    FracDefiner, // //
    Equal, // =
    EqEq, // ==
    NotEqual, // /= or !=
    Less, // <
    Great, // >
    LessEq, // <=
    GreatEq, // >=
    LeftArrow, // <-
    RightArrow, // ->
    LeftRightArrow, // <->
    LongLeftArrow, // <--
    LongRightArrow, // -->
    LongLeftRightArrow, // <-->
    DoubleLeftArrow, // =<
    DoubleRightArrow, // =>
    DoubleLeftRightArrow, // <=>
    LongDoubleLeftArrow, // <==
    LongDoubleRightArrow, // ==>
    LongDoubleLeftRightArrow, // <==>
    MapsTo, // |->
    Bang, // !
    Question, // ?
    LatexComment, // %!
    TextPercent, // \%
    RawPercent, // %
    TextSharp, // \#
    RawSharp, // #
    TextDollar, // \$
    RawDollar, // $!
    At, // @
    Superscript, // ^
    Subscript, // _
    Ampersand, // &
    BackSlash, // \\
    ShortBackSlash, // \
    Vert, // |
    Norm, // ||
    Period, // .
    Comma, // ,
    Colon, // :
    Semicolon, // ;
    Tilde, // ~
    LeftQuote, // `
    RightQuote, // '
    DoubleQuote, // "
    CenterDots, // ...
    InfinitySym, // oo

    // Delimiters
    Lbrace, // {
    Rbrace, // }
    Lparen, // (
    Rparen, // )
    Lsqbrace, // [
    Rsqbrace, // ]
    Langle, // {<
    Rangle, // >}
    MathLbrace, // \{
    MathRbrace, // \}
    InlineMathSwitch, // $
    DisplayMathSwitch, // $$
    DisplayMathStart, // \[
    DisplayMathEnd, // \]

    // error token
    Illegal,
    Deprecated: struct {
        valid_in_text: bool,
        instead: []const u8,
    },
};

pub const VESTI_KEYWORDS = std.StaticStringMap(TokenType).initComptime(.{
    .{ "docclass", TokenType.Docclass },
    .{ "importpkg", TokenType.ImportPkg },
    .{ "importves", TokenType.ImportVesti },
    .{ "importmod", TokenType.ImportModule },
    .{ "importfile", TokenType.ImportFile },
    .{ "useltx3", TokenType.ImportLatex3 },
    .{ "getfp", TokenType.GetFilePath },
    .{ "getfilepath", TokenType.GetFilePath }, // TODO: deprecate
    .{ "startdoc", TokenType.StartDoc },
    .{ "useenv", TokenType.Useenv },
    .{ "begenv", TokenType.Begenv },
    .{ "endenv", TokenType.Endenv },
    .{ "makeatletter", TokenType.MakeAtLetter },
    .{ "makeatother", TokenType.MakeAtOther },
    .{ "ltx3on", TokenType.Latex3On },
    .{ "ltx3off", TokenType.Latex3Off },
    .{ "nonstopmode", TokenType.NonStopMode },
    .{ "defenv", TokenType{ .Deprecated = .{ .valid_in_text = false, .instead = "" } } },
    .{ "redefenv", TokenType{ .Deprecated = .{ .valid_in_text = false, .instead = "" } } },
    .{ "endswith", TokenType{ .Deprecated = .{ .valid_in_text = false, .instead = "" } } },
    .{ "defun", TokenType{ .Deprecated = .{ .valid_in_text = false, .instead = "" } } },
    .{ "pycode", TokenType{ .Deprecated = .{ .valid_in_text = true, .instead = "" } } },
    .{ "mainvesfile", TokenType{ .Deprecated = .{ .valid_in_text = false, .instead = "" } } },
    .{ "importltx3", TokenType{ .Deprecated = .{ .valid_in_text = false, .instead = "useltx3" } } },
    .{ "enddef", TokenType{ .Deprecated = .{ .valid_in_text = true, .instead = "}" } } },
    .{ "import", TokenType{ .Deprecated = .{ .valid_in_text = true, .instead = "importpkg" } } },
    .{ "endswith", TokenType{ .Deprecated = .{ .valid_in_text = false, .instead = "" } } },
    .{ "pbegenv", TokenType{ .Deprecated = .{ .valid_in_text = false, .instead = "begenv" } } },
    .{ "pendenv", TokenType{ .Deprecated = .{ .valid_in_text = false, .instead = "endenv" } } },
});

pub fn init(
    self: *Self,
    in_text: []const u8,
    maybe_in_math: ?[]const u8,
    toktype: TokenType,
    start: Location,
    end: Location,
) void {
    const in_math = maybe_in_math orelse in_text;

    self.* = Self{
        .lit = .{ .in_text = in_text, .in_math = in_math },
        .toktype = toktype,
        .span = .{ .start = start, .end = end },
    };
}

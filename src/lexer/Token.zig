const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;

pub const Literal = struct {
    in_text: []const u8,
    in_math: []const u8,

    const Self = @This();
};

pub const FunctionDefKind = packed struct {
    long: bool = false,
    outer: bool = false,
    expand: bool = false,
    global: bool = false,
};

pub const TokenType = union(enum(u8)) {
    // EOF character
    Eof = 0,

    // Whitespace
    Space,
    Space2, // /_ where _ is a space
    Tab,
    Newline,
    MathSmallSpace, // \,
    MathLargeSpace, // \;

    // Identifiers
    Integer,
    Float,
    Text,
    LatexFunction,
    RawLatex,
    OtherChar,

    // Keywords
    __begin_keywords, // NOTE: this is a meta token type, not the actual one.
    Docclass,
    ImportPkg,
    ImportVesti,
    ImportFile,
    ImportLatex3,
    StartDoc,
    Defenv,
    Redefenv,
    EndsWith,
    Useenv,
    Begenv,
    Endenv,
    MakeAtLetter,
    MakeAtOther,
    Latex3On,
    Latex3Off,
    MainVestiFile,
    NonStopMode,
    FunctionDef: FunctionDefKind,
    __end_keywords, // NOTE: this is a meta token type, not the actual one.

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

    // Delimiters
    Lbrace, // {
    Rbrace, // }
    Lparen, // (
    Rparen, // )
    Lsqbrace, // [
    Rsqbrace, // ]
    Langle, // <{
    Rangle, // }>
    MathLbrace, // \{
    MathRbrace, // \}
    TextMathSwitch, // $
    InlineMathStart, // \[
    InlineMathEnd, // \]
    InlineMathSwitch, // $$

    // error token
    Deprecated: struct {
        valid_in_text: bool,
        instead: []const u8,
    },
};

const VESTI_KEYWORDS = std.StaticStringMap(TokenType).initComptime(.{
    .{ "docclass", TokenType.Docclass },
    .{ "importpkg", TokenType.Docclass },
    .{ "importves", TokenType.Docclass },
    .{ "importfile", TokenType.Docclass },
    .{ "importltx3", TokenType.Docclass },
    .{ "startdoc", TokenType.Docclass },
    .{ "defenv", TokenType.Docclass },
    .{ "redefenv", TokenType.Docclass },
    .{ "useenv", TokenType.Docclass },
    .{ "begenv", TokenType.Docclass },
    .{ "endenv", TokenType.Docclass },
    .{ "makeatletter", TokenType.Docclass },
    .{ "makeatother", TokenType.Docclass },
    .{ "ltx3on", TokenType.Docclass },
    .{ "ltx3off", TokenType.Docclass },
    .{ "mainvesfile", TokenType.Docclass },
    .{ "nonstopmode", TokenType.Docclass },
    .{ "defun", TokenType{ .FunctionDef = FunctionDefKind{} },
    .{ "ldefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "odefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "lodefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "edefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "ledefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "oedefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "loedefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "gdefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "lgdefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "ogdefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "logdefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "xdefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "lxdefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "oxdefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "loxdefun", TokenType.Deprecated{ .valid_in_text = false, .instead = "defun" } },
    .{ "import", TokenType.Deprecated{ .valid_in_text = true, .instead = "importpkg" } },
    .{ "endswith", TokenType.Deprecated{ .valid_in_text = false, .instead = "" } },
    .{ "pbegenv", TokenType.Deprecated{ .valid_in_text = false, .instead = "begenv" } },
    .{ "pendenv", TokenType.Deprecated{ .valid_in_text = false, .instead = "endenv" } },
    .{ "enddef", TokenType.Deprecated{ .valid_in_text = false, .instead = "}" } },
});

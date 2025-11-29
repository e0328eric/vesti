const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;

const Location = @import("../location.zig").Location;
const Span = @import("../location.zig").Span;

toktype: TokenType,
lit: Literal,
span: Span,

const Self = @This();

pub const invalid: Self = .{
    .toktype = .Illegal,
    .lit = .{
        .in_text = "",
        .in_math = "",
    },
    .span = .{},
};

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
    RawChar: struct {
        start: usize = 0,
        end: usize = 0,
        chr: u21 = 0,
    },
    BuiltinFunction: []const u8,
    LuaCode,

    // Keywords
    __begin_keywords, // NOTE: this is only used internally
    Docclass,
    ImportPkg,
    ImportVesti,
    CopyFile,
    ImportModule,
    StartDoc,
    Useenv,
    Begenv,
    Endenv,
    DefineFunction,
    DefineEnv,
    CompileType,
    __end_keywords, // NOTE: this is only used internally

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

    pub inline fn deprecated(valid_in_text: bool, instead: []const u8) @This() {
        comptime return .{ .Deprecated = .{
            .valid_in_text = valid_in_text,
            .instead = instead,
        } };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            // zig fmt: off
            .Eof =>                      try writer.writeAll("`<EOF>`"),
            .Space =>                    try writer.writeAll("`<space>`"),
            .Tab =>                      try writer.writeAll("`<tab>`"),
            .Newline =>                  try writer.writeAll("`<newline>`"),
            .MathSmallSpace =>           try writer.writeAll("`<mathsmallspace>`"),
            .MathLargeSpace =>           try writer.writeAll("`<mathlargespace>`"),
            .Integer =>                  try writer.writeAll("`<integer>`"),
            .Float =>                    try writer.writeAll("`<float>`"),
            .Text =>                     try writer.writeAll("`<text>`"),
            .LatexFunction =>            try writer.writeAll("`<ltxfnt>`"),
            .MakeAtLetterFnt =>          try writer.writeAll("`<makeatletterfnt>`"),
            .Latex3Fnt =>                try writer.writeAll("`<ltx3fnt>`"),
            .RawLatex =>                 try writer.writeAll("`<rawlatex>`"),
            .OtherChar =>                try writer.writeAll("`<otherchr>`"),
            .BuiltinFunction=> |val|     try writer.print("`<builtin #{s}>`", .{val}),
            .RawChar => |info|           try writer.print("`<rawchr `{u}`>`", .{info.chr}),
            .LuaCode =>                  try writer.writeAll("`<luacode>`"),
            .Docclass =>                 try writer.writeAll("`docclass`"),
            .ImportPkg =>                try writer.writeAll("`importpkg`"),
            .ImportVesti =>              try writer.writeAll("`importves`"),
            .CopyFile =>                 try writer.writeAll("`cpfile`"),
            .ImportModule =>             try writer.writeAll("`importmod`"),
            .StartDoc =>                 try writer.writeAll("`startdoc`"),
            .Useenv =>                   try writer.writeAll("`useenv`"),
            .Begenv =>                   try writer.writeAll("`begenv`"),
            .Endenv =>                   try writer.writeAll("`endenv`"),
            .CompileType =>              try writer.writeAll("`compty`"),
            .DefineFunction =>           try writer.writeAll("`defun`"),
            .DefineEnv =>                try writer.writeAll("`defenv`"),
            .Plus =>                     try writer.writeAll("`+`"),
            .Minus =>                    try writer.writeAll("`-`"),
            .SetMinus =>                 try writer.writeAll("`--`"),
            .Star =>                     try writer.writeAll("`*`"),
            .Slash =>                    try writer.writeAll("`/`"),
            .FracDefiner =>              try writer.writeAll("`//`"),
            .Equal =>                    try writer.writeAll("`=`"),
            .EqEq =>                     try writer.writeAll("`==`"),
            .NotEqual =>                 try writer.writeAll("`!=`"),
            .Less =>                     try writer.writeAll("`<`"),
            .Great =>                    try writer.writeAll("`>`"),
            .LessEq =>                   try writer.writeAll("`<=`"),
            .GreatEq =>                  try writer.writeAll("`>=`"),
            .LeftArrow =>                try writer.writeAll("`<-`"),
            .RightArrow =>               try writer.writeAll("`->`"),
            .LeftRightArrow =>           try writer.writeAll("`<->`"),
            .LongLeftArrow =>            try writer.writeAll("`<--`"),
            .LongRightArrow =>           try writer.writeAll("`-->`"),
            .LongLeftRightArrow =>       try writer.writeAll("`<-->`"),
            .DoubleRightArrow =>         try writer.writeAll("`=>`"),
            .DoubleLeftRightArrow =>     try writer.writeAll("`<=>`"),
            .LongDoubleLeftArrow =>      try writer.writeAll("`<==`"),
            .LongDoubleRightArrow =>     try writer.writeAll("`==>`"),
            .LongDoubleLeftRightArrow => try writer.writeAll("`<==>`"),
            .MapsTo =>                   try writer.writeAll("`|->`"),
            .Bang =>                     try writer.writeAll("`!`"),
            .Question =>                 try writer.writeAll("`?`"),
            .LatexComment =>             try writer.writeAll("`%!`"),
            .TextPercent =>              try writer.writeAll("`\\%`"),
            .RawPercent =>               try writer.writeAll("`%!`"),
            .TextSharp =>                try writer.writeAll("`\\#`"),
            .RawSharp =>                 try writer.writeAll("`#`"),
            .TextDollar =>               try writer.writeAll("`\\$`"),
            .RawDollar =>                try writer.writeAll("`$!`"),
            .At =>                       try writer.writeAll("`@`"),
            .Superscript =>              try writer.writeAll("`^`"),
            .Subscript =>                try writer.writeAll("`_`"),
            .Ampersand =>                try writer.writeAll("`&`"),
            .BackSlash =>                try writer.writeAll("`\\\\`"),
            .ShortBackSlash =>           try writer.writeAll("`\\`"),
            .Vert =>                     try writer.writeAll("`|`"),
            .Norm =>                     try writer.writeAll("`||`"),
            .Period =>                   try writer.writeAll("`.`"),
            .Comma =>                    try writer.writeAll("`,`"),
            .Colon =>                    try writer.writeAll("`:`"),
            .Semicolon =>                try writer.writeAll("`;`"),
            .Tilde =>                    try writer.writeAll("`~`"),
            .LeftQuote =>                try writer.writeAll("`'`"),
            .RightQuote =>               try writer.writeAll("```"),
            .DoubleQuote =>              try writer.writeAll("`\"`"),
            .CenterDots =>               try writer.writeAll("`...`"),
            .InfinitySym =>              try writer.writeAll("`oo`"),
            .Lbrace =>                   try writer.writeAll("`{`"),
            .Rbrace =>                   try writer.writeAll("`}`"),
            .Lparen =>                   try writer.writeAll("`(`"),
            .Rparen =>                   try writer.writeAll("`)`"),
            .Lsqbrace =>                 try writer.writeAll("`[`"),
            .Rsqbrace =>                 try writer.writeAll("`]`"),
            .Langle =>                   try writer.writeAll("`{<`"),
            .Rangle =>                   try writer.writeAll("`>}`"),
            .MathLbrace =>               try writer.writeAll("`\\{`"),
            .MathRbrace =>               try writer.writeAll("`\\}`"),
            .InlineMathSwitch =>         try writer.writeAll("`$`"),
            .DisplayMathSwitch =>        try writer.writeAll("`$$`"),
            .DisplayMathStart =>         try writer.writeAll("`\\[`"),
            .DisplayMathEnd =>           try writer.writeAll("`\\]`"),
            .Illegal =>                  try writer.writeAll("`<illegal>`"),
            .Deprecated =>               try writer.writeAll("`<deprecated>`"),
            .__begin_keywords, .__end_keywords => unreachable,
            // zig fmt: on
        }
    }
};

pub const VESTI_KEYWORDS = std.StaticStringMap(TokenType).initComptime(.{
    // zig fmt: off
    .{ "docclass",     TokenType.Docclass },
    .{ "importpkg",    TokenType.ImportPkg },
    .{ "importves",    TokenType.ImportVesti },
    .{ "importmod",    TokenType.ImportModule },
    .{ "cpfile",       TokenType.CopyFile },
    .{ "startdoc",     TokenType.StartDoc },
    .{ "useenv",       TokenType.Useenv },
    .{ "begenv",       TokenType.Begenv },
    .{ "endenv",       TokenType.Endenv },
    .{ "compty",       TokenType.CompileType },
    .{ "defun",        TokenType.DefineFunction },
    .{ "defenv",       TokenType.DefineEnv },
    // zig fmt: on
});

// #<only_numbers> are preserved as function parameters
// `val` should not contain `#` character
pub fn isFunctionParam(val: []const u8) ?usize {
    return fmt.parseInt(usize, val, 10) catch null;
}

pub const VESTI_BUILTINS = std.StaticStringMap(void).initComptime(.{
    // zig fmt: off
    .{ "at_off" },
    .{ "at_on" },
    .{ "chardef" },
    .{ "enum" },
    .{ "enum_counter" },
    .{ "eq" },
    .{ "get_filepath" },
    .{ "label" },
    .{ "ltx3_off" },
    .{ "ltx3_on" },
    .{ "mathchardef" },
    .{ "mathmode" },
    .{ "noltx3" },
    .{ "picture" },
    .{ "raw_tex" },
    .{ "showfont" },
    .{ "textmode" },
    // zig fmt: on
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

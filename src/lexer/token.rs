use std::borrow::Cow;

use crate::location::{Location, Span};

#[derive(Default, Debug, Clone)]
pub struct Literal<'s> {
    in_text: Cow<'s, str>,
    in_math: Cow<'s, str>,
}

impl<'s> Literal<'s> {
    #[inline]
    pub fn in_text(&self) -> &str {
        &self.in_text
    }

    #[inline]
    pub fn in_math(&self) -> &str {
        &self.in_math
    }
}

#[derive(Default, Debug, Clone)]
pub struct Token<'s> {
    toktype: TokenType<'s>,
    literal: Literal<'s>,
    span: Span,
}

impl<'s> Token<'s> {
    /// Build a token from its two literal forms and a span.
    pub fn new(
        toktype: TokenType<'s>,
        in_text: Cow<'s, str>,
        in_math: Cow<'s, str>,
        span: Span,
    ) -> Self {
        Self {
            toktype,
            literal: Literal { in_text, in_math },
            span,
        }
    }

    pub fn eof(start: Location, end: Location) -> Self {
        Self {
            toktype: TokenType::Eof,
            literal: Literal::default(),
            span: Span { start, end },
        }
    }

    #[inline]
    pub fn toktype(&self) -> TokenType<'s> {
        self.toktype
    }

    #[inline]
    pub fn literal(&self) -> &Literal<'s> {
        &self.literal
    }

    #[inline]
    pub fn in_text(&self) -> &str {
        &self.literal.in_text
    }

    #[inline]
    pub fn in_math(&self) -> &str {
        &self.literal.in_math
    }

    #[inline]
    pub fn span(&self) -> Span {
        self.span
    }

    /// Return the in_text literal with the source lifetime `'s`.
    ///
    /// Every literal the lexer and preprocessor produce is `Cow::Borrowed`
    /// (either source-backed or a `'static` synthetic), so this is sound. An
    /// `Owned` literal (not produced in practice) yields `""`.
    #[inline]
    pub fn in_text_src(&self) -> &'s str {
        match self.literal.in_text {
            Cow::Borrowed(s) => s,
            Cow::Owned(_) => "",
        }
    }

    /// Return the in_math literal with the source lifetime `'s` (see
    /// [`Token::in_text_src`]).
    #[inline]
    pub fn in_math_src(&self) -> &'s str {
        match self.literal.in_math {
            Cow::Borrowed(s) => s,
            Cow::Owned(_) => "",
        }
    }
}

#[repr(u8)]
#[derive(Default, Debug, Clone, Copy, PartialEq, PartialOrd)]
pub enum TokenType<'s> {
    // EOF character
    #[default]
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
    // The builtin name borrows from the source (without the leading `#`).
    BuiltinFunction(&'s str),
    LuaCodeStart,
    LuaCodeEnd,

    // Keywords
    #[allow(non_camel_case_types)]
    __begin_keywords, // NOTE: this is only used internally
    Docclass,
    ImportPkg,
    ImportVesti,
    ImportModule,
    StartDoc,
    Useenv,
    Begenv,
    Endenv,
    DefineFunction,
    DefineEnv,
    #[allow(non_camel_case_types)]
    __end_keywords, // NOTE: this is only used internally

    // Symbols
    Plus,                     // +
    Minus,                    // -
    SetMinus,                 // -!
    EnDash,                   // --!
    EmDash,                   // ---
    Star,                     // *
    Slash,                    // /
    FracDefiner,              // //
    Equal,                    // =
    EqEq,                     // ==
    NotEqual,                 // /= or !=
    Less,                     // <
    Great,                    // >
    LessEq,                   // <=
    GreatEq,                  // >=
    LeftArrow,                // <-
    RightArrow,               // ->
    LeftRightArrow,           // <->
    LongLeftArrow,            // <--
    LongRightArrow,           // -->
    LongLeftRightArrow,       // <-->
    DoubleRightArrow,         // =>
    DoubleLeftRightArrow,     // <=>
    LongDoubleLeftArrow,      // <==
    LongDoubleRightArrow,     // ==>
    LongDoubleLeftRightArrow, // <==>
    MapsTo,                   // |->
    Bang,                     // !
    Question,                 // ?
    LatexComment,             // %
    TextPercent,              // \%
    RawPercent,               // %
    TextSharp,                // \#
    RawSharp,                 // #
    TextDollar,               // \$
    RawDollar,                // $#
    At,                       // @
    Superscript,              // ^
    Subscript,                // _
    Ampersand,                // &
    BackSlash,                // \\
    ShortBackSlash,           // \
    Vert,                     // |
    Norm,                     // ||
    Period,                   // .
    Comma,                    // ,
    Colon,                    // :
    Semicolon,                // ;
    Tilde,                    // ~
    LeftQuote,                // `
    RightQuote,               // '
    DoubleQuote,              // "
    CenterDots,               // ...
    InfinitySym,              // oo

    // Delimiters
    Lbrace,            // {
    Rbrace,            // }
    Lparen,            // (
    Rparen,            // )
    Lsqbrace,          // [
    Rsqbrace,          // ]
    Langle,            // {<
    Rangle,            // >}
    MathLbrace,        // \{
    MathRbrace,        // \}
    InlineMathSwitch,  // $
    DisplayMathSwitch, // $$
    DisplayMathStart,  // \[
    DisplayMathEnd,    // \]

    // error token
    Illegal,
    Deprecated {
        valid_in_text: bool,
        instead: &'static str,
    },
}

impl<'s> TokenType<'s> {
    /// True for the (internal-only) keyword range markers excluded.
    #[inline]
    pub fn is_keyword(&self) -> bool {
        matches!(
            self,
            TokenType::Docclass
                | TokenType::ImportPkg
                | TokenType::ImportVesti
                | TokenType::ImportModule
                | TokenType::StartDoc
                | TokenType::Useenv
                | TokenType::Begenv
                | TokenType::Endenv
                | TokenType::DefineFunction
                | TokenType::DefineEnv
        )
    }
}

pub fn lookup_keyword(ident: &str) -> Option<TokenType<'static>> {
    Some(match ident {
        "docclass" => TokenType::Docclass,
        "importpkg" => TokenType::ImportPkg,
        "importves" => TokenType::ImportVesti,
        "importmod" => TokenType::ImportModule,
        "startdoc" => TokenType::StartDoc,
        "useenv" => TokenType::Useenv,
        "begenv" => TokenType::Begenv,
        "endenv" => TokenType::Endenv,
        "defun" => TokenType::DefineFunction,
        "defenv" => TokenType::DefineEnv,
        "compty" => TokenType::Deprecated {
            valid_in_text: false,
            instead: "#engine_type",
        },
        "cpfile" => TokenType::Deprecated {
            valid_in_text: false,
            instead: "#copy_file",
        },
        _ => return None,
    })
}

// `#<builtin>` names recognized by vesti
vesti_macros::builtin_set!(
    pub is_builtin, BUILTIN_NAMES, dispatch_builtin, parse_builtin,
    [
        "chardef",
        "copy_file",
        "engine_type",
        "enum",
        "enum_counter",
        "eq",
        "get_filepath",
        "label",
        "mathchardef",
        "mathmode",
        "picture",
        "raw_tex",
        "showfont",
        "textmode",
    ]
);

// `#<builtin>` names handled during preprocessing
vesti_macros::builtin_set!(
    pub is_preprocess_builtin, PREPROCESS_BUILTIN_NAMES, dispatch_preprocess_builtin, preprocess,
    [
        "at_on",
        "at_off",
        "def",
        "include",
        "ltx3_on",
        "ltx3_off",
        "noltx3",
        "undef",
    ]
);

/// `#<digits>` are preserved as function parameters. `val` must not contain `#`.
#[inline]
pub fn is_function_param(val: &str) -> Option<usize> {
    val.parse::<usize>().ok()
}

/// Whether `chr` may appear inside a vesti identifier / latex-function name.
///
/// * `subscript_as_letter` (a.k.a. `make_at_letter`) lets `@` act as a letter.
/// * `is_latex3` lets `_` and `:` act as letters (LaTeX3 naming convention).
#[inline]
pub fn is_vesti_ident_char(chr: char, subscript_as_letter: bool, is_latex3: bool) -> bool {
    chr.is_alphabetic()
        || (subscript_as_letter && chr == '@')
        || (is_latex3 && (chr == '_' || chr == ':'))
}

impl std::fmt::Display for TokenType<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s: &str = match self {
            TokenType::Eof => "`<EOF>`",
            TokenType::Space => "`<space>`",
            TokenType::Tab => "`<tab>`",
            TokenType::Newline => "`<newline>`",
            TokenType::MathSmallSpace => "`<mathsmallspace>`",
            TokenType::MathLargeSpace => "`<mathlargespace>`",
            TokenType::Integer => "`<integer>`",
            TokenType::Float => "`<float>`",
            TokenType::Text => "`<text>`",
            TokenType::LatexFunction => "`<ltxfnt>`",
            TokenType::MakeAtLetterFnt => "`<makeatletterfnt>`",
            TokenType::Latex3Fnt => "`<ltx3fnt>`",
            TokenType::RawLatex => "`<rawlatex>`",
            TokenType::OtherChar => "`<otherchr>`",
            TokenType::BuiltinFunction(val) => {
                return write!(f, "`<builtin #{val}>`");
            }
            TokenType::LuaCodeStart => "`<luacode_start>`",
            TokenType::LuaCodeEnd => "`<luacode_end>`",
            TokenType::Docclass => "`docclass`",
            TokenType::ImportPkg => "`importpkg`",
            TokenType::ImportVesti => "`importves`",
            TokenType::ImportModule => "`importmod`",
            TokenType::StartDoc => "`startdoc`",
            TokenType::Useenv => "`useenv`",
            TokenType::Begenv => "`begenv`",
            TokenType::Endenv => "`endenv`",
            TokenType::DefineFunction => "`defun`",
            TokenType::DefineEnv => "`defenv`",
            TokenType::Plus => "`+`",
            TokenType::Minus => "`-`",
            TokenType::SetMinus => "`-!`",
            TokenType::EnDash => "`--!`",
            TokenType::EmDash => "`---`",
            TokenType::Star => "`*`",
            TokenType::Slash => "`/`",
            TokenType::FracDefiner => "`//`",
            TokenType::Equal => "`=`",
            TokenType::EqEq => "`==`",
            TokenType::NotEqual => "`!=`",
            TokenType::Less => "`<`",
            TokenType::Great => "`>`",
            TokenType::LessEq => "`<=`",
            TokenType::GreatEq => "`>=`",
            TokenType::LeftArrow => "`<-`",
            TokenType::RightArrow => "`->`",
            TokenType::LeftRightArrow => "`<->`",
            TokenType::LongLeftArrow => "`<--`",
            TokenType::LongRightArrow => "`-->`",
            TokenType::LongLeftRightArrow => "`<-->`",
            TokenType::DoubleRightArrow => "`=>`",
            TokenType::DoubleLeftRightArrow => "`<=>`",
            TokenType::LongDoubleLeftArrow => "`<==`",
            TokenType::LongDoubleRightArrow => "`==>`",
            TokenType::LongDoubleLeftRightArrow => "`<==>`",
            TokenType::MapsTo => "`|->`",
            TokenType::Bang => "`!`",
            TokenType::Question => "`?`",
            TokenType::LatexComment => "`%`",
            TokenType::TextPercent => "`\\%`",
            TokenType::RawPercent => "`<rawpercent>`",
            TokenType::TextSharp => "`\\#`",
            TokenType::RawSharp => "`#`",
            TokenType::TextDollar => "`\\$`",
            TokenType::RawDollar => "`$!`",
            TokenType::At => "`@`",
            TokenType::Superscript => "`^`",
            TokenType::Subscript => "`_`",
            TokenType::Ampersand => "`&`",
            TokenType::BackSlash => "`\\\\`",
            TokenType::ShortBackSlash => "`\\`",
            TokenType::Vert => "`|`",
            TokenType::Norm => "`||`",
            TokenType::Period => "`.`",
            TokenType::Comma => "`,`",
            TokenType::Colon => "`:`",
            TokenType::Semicolon => "`;`",
            TokenType::Tilde => "`~`",
            TokenType::LeftQuote => "`'`",
            TokenType::RightQuote => "```",
            TokenType::DoubleQuote => "`\"`",
            TokenType::CenterDots => "`...`",
            TokenType::InfinitySym => "`oo`",
            TokenType::Lbrace => "`{`",
            TokenType::Rbrace => "`}`",
            TokenType::Lparen => "`(`",
            TokenType::Rparen => "`)`",
            TokenType::Lsqbrace => "`[`",
            TokenType::Rsqbrace => "`]`",
            TokenType::Langle => "`{<`",
            TokenType::Rangle => "`>}`",
            TokenType::MathLbrace => "`\\{`",
            TokenType::MathRbrace => "`\\}`",
            TokenType::InlineMathSwitch => "`$`",
            TokenType::DisplayMathSwitch => "`$$`",
            TokenType::DisplayMathStart => "`\\[`",
            TokenType::DisplayMathEnd => "`\\]`",
            TokenType::Illegal => "`<illegal>`",
            TokenType::Deprecated { .. } => "`<deprecated>`",
            TokenType::__begin_keywords | TokenType::__end_keywords => {
                unreachable!("internal keyword marker should never be formatted")
            }
        };
        f.write_str(s)
    }
}

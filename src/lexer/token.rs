use std::fmt::{self, Debug};
use std::ops::{BitAnd, BitOr};

use crate::location::{Location, Span};

#[derive(Default, Clone, Debug)]
pub struct Token {
    pub toktype: TokenType,
    pub literal: String,
    pub span: Span,
}

impl Token {
    #[inline]
    pub fn new(toktype: TokenType, literal: impl ToString, start: Location, end: Location) -> Self {
        Self {
            toktype,
            literal: literal.to_string(),
            span: Span { start, end },
        }
    }

    #[inline]
    pub fn eof(start: Location, end: Location) -> Self {
        Self {
            toktype: TokenType::Eof,
            literal: String::new(),
            span: Span { start, end },
        }
    }
}

#[repr(transparent)]
#[derive(Clone, Copy, PartialEq, PartialOrd, Default)]
pub struct FunctionDefKind(u8);

impl FunctionDefKind {
    pub const LONG: Self = Self(1 << 0);
    pub const OUTER: Self = Self(1 << 1);
    pub const EXPAND: Self = Self(1 << 2);
    pub const GLOBAL: Self = Self(1 << 3);

    const MAX_BOUND_EXCLUDE: u8 = 1 << 4;

    #[inline]
    pub fn has_property(self, rhs: Self) -> bool {
        self & rhs == rhs
    }
}

impl BitOr for FunctionDefKind {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

impl BitAnd for FunctionDefKind {
    type Output = Self;
    fn bitand(self, rhs: Self) -> Self::Output {
        Self(self.0 & rhs.0)
    }
}

impl Debug for FunctionDefKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.has_property(Self::LONG) {
            write!(f, "long")?;
        }

        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, PartialOrd, Default)]
pub enum TokenType {
    // default token
    #[default]
    Eof,

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
    VerbatimChar(char),

    // Keywords
    Docclass,
    ImportPkg,
    ImportVesti,
    ImportFile,
    ImportModule,
    ImportLatex3,
    FilePath,
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
    FunctionDef(FunctionDefKind),
    EndDefinition,

    // Symbols
    Plus,               // +
    Minus,              // -
    SetMinus,           // --
    Star,               // *
    Slash,              // /
    FracDefiner,        // //
    Equal,              // =
    NotEqual,           // /= or !=
    Less,               // <
    Great,              // >
    LessEq,             // <=
    GreatEq,            // >=
    LeftArrow,          // <-
    RightArrow,         // ->
    LeftRightArrow,     // <->
    LongLeftArrow,      // <--
    LongRightArrow,     // -->
    LongLeftRightArrow, // <-->
    // NOTE: The reason why there is no DoubleLeftArrow is that
    // symbolically, it is same with LessEq and it is already preserved.
    DoubleRightArrow,         // =>
    DoubleLeftRightArrow,     // <=>
    LongDoubleLeftArrow,      // <==
    LongDoubleRightArrow,     // ==>
    LongDoubleLeftRightArrow, // <==>
    MapsTo,                   // |->
    Bang,                     // !
    Question,                 // ?
    RawQuestion,              // \?
    RawDollar,                // %!
    Dollar,                   // \$
    Sharp,                    // \#
    FntParam,                 // #
    At,                       // @! or @
    Percent,                  // %
    LatexComment,             // \%
    HatAccent,                // \^
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
    RawLbrace,                // \(
    RawRbrace,                // \)
    CenterDots,               // ...
    InfinitySym,              // oo

    // Delimiters
    Lbrace,           // {
    Rbrace,           // }
    Lparen,           // (
    Rparen,           // )
    Lsqbrace,         // [
    Rsqbrace,         // ]
    Langle,           // <{
    Rangle,           // }>
    MathLbrace,       // \{
    MathRbrace,       // \}
    InlineMathStart,  // $
    InlineMathEnd,    // $
    DisplayMathStart, // $$ or \[
    DisplayMathEnd,   // $$ or \]
    MathTextStart,    // "
    MathTextEnd,      // "

    // error token
    Deprecated {
        valid_in_text: bool,
        instead: &'static str,
    },
}

impl TokenType {
    #[inline]
    pub fn is_keyword(&self) -> bool {
        Self::Docclass <= *self && *self <= Self::EndDefinition
    }

    #[inline]
    pub fn is_math_delimiter(&self) -> bool {
        matches!(
            self,
            Self::Lparen
                | Self::Lsqbrace
                | Self::Langle
                | Self::MathLbrace
                | Self::Vert
                | Self::Norm
                | Self::Rparen
                | Self::Rsqbrace
                | Self::Rangle
                | Self::MathRbrace
        )
    }

    #[inline]
    pub fn is_deprecated(&self) -> bool {
        matches!(self, Self::Deprecated { .. })
    }

    pub fn is_keyword_str(string: &str) -> Option<TokenType> {
        use FunctionDefKind as FDK;

        match string {
            "docclass" => Some(Self::Docclass),
            "importpkg" => Some(Self::ImportPkg),
            "importves" => Some(Self::ImportVesti),
            "importfile" => Some(Self::ImportFile),
            "importmod" => Some(Self::ImportModule),
            "importltx3" => Some(Self::ImportLatex3),
            "startdoc" => Some(Self::StartDoc),
            "defenv" => Some(Self::Defenv),
            "redefenv" => Some(Self::Redefenv),
            "endswith" => Some(Self::EndsWith),
            "useenv" => Some(Self::Useenv),
            "begenv" => Some(Self::Begenv),
            "endenv" => Some(Self::Endenv),
            "makeatletter" => Some(Self::MakeAtLetter),
            "makeatother" => Some(Self::MakeAtOther),
            "ltx3on" => Some(Self::Latex3On),
            "ltx3off" => Some(Self::Latex3Off),
            "mainvesfile" => Some(Self::MainVestiFile),
            "nonstopmode" => Some(Self::NonStopMode),
            "getfilepath" => Some(Self::FilePath),
            "defun" => Some(Self::FunctionDef(FunctionDefKind::default())),
            "ldefun" => Some(Self::FunctionDef(FDK::LONG)),
            "odefun" => Some(Self::FunctionDef(FDK::OUTER)),
            "lodefun" => Some(Self::FunctionDef(FDK::LONG | FDK::OUTER)),
            "edefun" => Some(Self::FunctionDef(FDK::EXPAND)),
            "ledefun" => Some(Self::FunctionDef(FDK::LONG | FDK::EXPAND)),
            "oedefun" => Some(Self::FunctionDef(FDK::OUTER | FDK::EXPAND)),
            "loedefun" => Some(Self::FunctionDef(FDK::LONG | FDK::OUTER | FDK::EXPAND)),
            "gdefun" => Some(Self::FunctionDef(FDK::GLOBAL)),
            "lgdefun" => Some(Self::FunctionDef(FDK::GLOBAL | FDK::LONG)),
            "ogdefun" => Some(Self::FunctionDef(FDK::GLOBAL | FDK::OUTER)),
            "logdefun" => Some(Self::FunctionDef(FDK::GLOBAL | FDK::LONG | FDK::OUTER)),
            "xdefun" => Some(Self::FunctionDef(FDK::GLOBAL | FDK::EXPAND)),
            "lxdefun" => Some(Self::FunctionDef(FDK::GLOBAL | FDK::EXPAND | FDK::LONG)),
            "oxdefun" => Some(Self::FunctionDef(FDK::GLOBAL | FDK::EXPAND | FDK::OUTER)),
            "loxdefun" => Some(Self::FunctionDef(
                FDK::GLOBAL | FDK::EXPAND | FDK::LONG | FDK::OUTER,
            )),
            "enddef" => Some(Self::EndDefinition),
            "import" => Some(Self::Deprecated {
                valid_in_text: true,
                instead: "importpkg",
            }), // NOTE: deprecated
            "pbegenv" => Some(Self::Deprecated {
                valid_in_text: false,
                instead: "begenv",
            }), // NOTE: deprecated
            "pendenv" => Some(Self::Deprecated {
                valid_in_text: false,
                instead: "endenv",
            }), // NOTE: deprecated
            _ => None,
        }
    }

    #[inline]
    pub fn get_definition_start_list() -> Vec<Self> {
        let mut output = vec![Self::Defenv, Self::Redefenv];

        for i in 0..FunctionDefKind::MAX_BOUND_EXCLUDE {
            output.push(Self::FunctionDef(FunctionDefKind(i)));
        }

        output
    }

    #[inline]
    pub fn can_pkg_name(&self) -> bool {
        *self == TokenType::Text || *self == TokenType::Minus || *self == TokenType::Integer
    }
}

pub fn is_latex_function_ident(chr: char, subscript_is_letter: bool, is_latex3: bool) -> bool {
    chr.is_alphabetic()
        || (subscript_is_letter && chr == '_')
        || (is_latex3 && (chr == '_' || chr == ':'))
}

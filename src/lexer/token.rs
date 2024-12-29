use std::fmt::Debug;

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
    PythonCode,
    GetFilePath,
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
    FunctionDef,
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
        match string {
            "docclass" => Some(Self::Docclass),
            "importpkg" => Some(Self::ImportPkg),
            "importves" => Some(Self::ImportVesti),
            "importfile" => Some(Self::ImportFile),
            "importmod" => Some(Self::ImportModule),
            "importltx3" => Some(Self::ImportLatex3),
            "pycode" => Some(Self::PythonCode),
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
            "getfilepath" => Some(Self::GetFilePath),
            "defun" => Some(Self::FunctionDef),
            "enddef" => Some(Self::EndDefinition),
            "import" => Some(Self::Deprecated {
                instead: "importpkg",
                valid_in_text: true,
            }),
            "pbegenv" => Some(Self::Deprecated {
                instead: "begenv",
                valid_in_text: false,
            }),
            "pendenv" => Some(Self::Deprecated {
                instead: "endenv",
                valid_in_text: false,
            }),
            "ldefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "odefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "lodefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "edefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "ledefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "oedefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "loedefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "gdefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "lgdefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "ogdefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "logdefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "xdefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "lxdefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "oxdefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            "loxdefun" => Some(Self::Deprecated {
                instead: "defun",
                valid_in_text: false,
            }),
            _ => None,
        }
    }

    #[inline]
    pub fn get_definition_start_list() -> Vec<Self> {
        vec![Self::Defenv, Self::Redefenv, Self::FunctionDef]
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

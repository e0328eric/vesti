// Copyright (c) 2022 Sungbae Jeong
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

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

    #[inline]
    pub fn illegal(start: Location, end: Location) -> Self {
        Self {
            toktype: TokenType::Illegal,
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
    BackslashSpace, // \_ where _ is a space
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

    // Keywords
    Docclass,
    LatexPkg,
    VestiMod,
    Verbatim,
    ModSynonym,
    StartDoc,
    DefEnv,
    RedefEnv,
    EndsWith,
    UseEnv,
    BeginEnv,
    EndEnv,
    Labeling,
    Mtxt,
    Etxt,
    FunctionDef,
    ExpandAttr,
    GlobalAttr,
    OuterAttr,
    LongAttr,
    EndDef,

    // Symbols
    Plus,           // +
    Minus,          // -
    Star,           // *
    Slash,          // /
    FracDefiner,    // //
    Equal,          // =
    NotEqual,       // /= or !=
    Less,           // <
    Great,          // >
    LessEq,         // <=
    GreatEq,        // >=
    LeftArrow,      // <-
    RightArrow,     // ->
    MapsTo,         // |->
    Norm,           // \|
    Bang,           // !
    Question,       // ?
    RawDollar,      // $!
    Dollar,         // $
    Sharp,          // \#
    FntParam,       // #
    At,             // @
    Percent,        // %
    LatexComment,   // \%
    Superscript,    // ^
    Subscript,      // _
    Ampersand,      // &
    BackSlash,      // \\
    ShortBackSlash, // \
    Vert,           // |
    Period,         // .
    Comma,          // ,
    Colon,          // :
    Semicolon,      // ;
    Tilde,          // ~
    LeftQuote,      // `
    RightQuote,     // '
    DoubleQuote,    // "

    // Delimiters
    LeftParen,        // (
    RightParen,       // )
    LeftBrace,        // {
    RightBrace,       // }
    LeftSquareBrace,  // [
    RightSquareBrace, // ]
    OptionalBrace,    // %[
    MathLeftBrace,    // \{
    MathRightBrace,   // \}
    TextMathStart,    // {{
    TextMathEnd,      // }}
    InlineMathStart,  // \[
    InlineMathEnd,    // \]

    // error token
    Illegal,
}

impl TokenType {
    #[inline]
    pub fn is_keyword(&self) -> bool {
        Self::Docclass <= *self && *self <= Self::EndDef
    }

    pub fn is_keyword_str(string: &str) -> Option<TokenType> {
        match string {
            "docclass" => Some(Self::Docclass),
            "ltxpkg" => Some(Self::LatexPkg),
            "vesmod" => Some(Self::VestiMod),
            "modverbtim" => Some(Self::Verbatim),
            "modat" => Some(Self::ModSynonym),
            "startdoc" => Some(Self::StartDoc),
            "defenv" => Some(Self::DefEnv),
            "redefenv" => Some(Self::RedefEnv),
            "endswith" => Some(Self::EndsWith),
            "useenv" => Some(Self::UseEnv),
            "begenv" => Some(Self::BeginEnv),
            "endenv" => Some(Self::EndEnv),
            "labeling" => Some(Self::Labeling),
            "mtxt" => Some(Self::Mtxt),
            "etxt" => Some(Self::Etxt),
            "defun" => Some(Self::FunctionDef),
            "expand" => Some(Self::ExpandAttr),
            "global" => Some(Self::GlobalAttr),
            "outer" => Some(Self::OuterAttr),
            "long" => Some(Self::LongAttr),
            "enddef" => Some(Self::EndDef),
            _ => None,
        }
    }

    #[inline]
    pub fn get_definition_start_list() -> Vec<Self> {
        vec![Self::DefEnv, Self::RedefEnv, Self::FunctionDef]
    }

    #[inline]
    pub fn can_pkg_name(&self) -> bool {
        *self == TokenType::Text || *self == TokenType::Minus || *self == TokenType::Integer
    }
}

#[inline]
pub fn is_latex_function_ident(chr: char) -> bool {
    chr == '@' || chr.is_alphabetic()
}

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

    // Keywords
    Docclass,
    Import,
    StartDoc,
    Defenv,
    Redefenv,
    EndsWith,
    Useenv,
    Begenv,
    Endenv,
    DocumentStartMode,
    NonStopMode,
    FunctionDef,
    LongFunctionDef,
    OuterFunctionDef,
    LongOuterFunctionDef,
    EFunctionDef,
    LongEFunctionDef,
    OuterEFunctionDef,
    LongOuterEFunctionDef,
    GFunctionDef,
    LongGFunctionDef,
    OuterGFunctionDef,
    LongOuterGFunctionDef,
    XFunctionDef,
    LongXFunctionDef,
    OuterXFunctionDef,
    LongOuterXFunctionDef,
    EndDefinition,

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
    Bang,           // !
    Question,       // ?
    RawDollar,      // $!
    Dollar,         // \$
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
    Lbrace,          // {
    Rbrace,          // }
    Lparen,          // (
    Rparen,          // )
    Lsqbrace,        // [
    Rsqbrace,        // ]
    Langle,          // <{
    Rangle,          // }>
    MathLbrace,      // \{
    MathRbrace,      // \}
    BigLparen,       // ({
    BigRparen,       // })
    BigLsqbrace,     // [{
    BigRsqbrace,     // }]
    BigLangle,       // <{{
    BigRangle,       // }}>
    BigMathLbrace,   // \{{
    BigMathRbrace,   // \}}
    OptionalBrace,   // %[
    TextMathStart,   // \( or {{
    TextMathEnd,     // \( or }}
    InlineMathStart, // \[
    InlineMathEnd,   // \]
    MathTextStart,
    MathTextEnd,

    // etc
    ArgSpliter,

    // error token
    Deprecated,
    Illegal,
}

impl TokenType {
    #[inline]
    pub fn is_keyword(&self) -> bool {
        Self::Docclass <= *self && *self <= Self::EndDefinition
    }

    pub fn is_keyword_str(string: &str) -> Option<TokenType> {
        match string {
            "docclass" => Some(Self::Docclass),
            "import" => Some(Self::Import),
            "startdoc" => Some(Self::StartDoc),
            "defenv" => Some(Self::Defenv),
            "redefenv" => Some(Self::Redefenv),
            "endswith" => Some(Self::EndsWith),
            "useenv" => Some(Self::Useenv),
            "begenv" => Some(Self::Begenv),
            "endenv" => Some(Self::Endenv),
            "docstartmode" => Some(Self::DocumentStartMode),
            "nonstopmode" => Some(Self::NonStopMode),
            "defun" => Some(Self::FunctionDef),
            "ldefun" => Some(Self::LongFunctionDef),
            "odefun" => Some(Self::OuterFunctionDef),
            "lodefun" => Some(Self::LongOuterFunctionDef),
            "edefun" => Some(Self::EFunctionDef),
            "ledefun" => Some(Self::LongEFunctionDef),
            "oedefun" => Some(Self::OuterEFunctionDef),
            "loedefun" => Some(Self::LongOuterEFunctionDef),
            "gdefun" => Some(Self::GFunctionDef),
            "lgdefun" => Some(Self::LongGFunctionDef),
            "ogdefun" => Some(Self::OuterGFunctionDef),
            "logdefun" => Some(Self::LongOuterGFunctionDef),
            "xdefun" => Some(Self::XFunctionDef),
            "lxdefun" => Some(Self::LongXFunctionDef),
            "oxdefun" => Some(Self::OuterXFunctionDef),
            "loxdefun" => Some(Self::LongOuterXFunctionDef),
            "enddef" => Some(Self::EndDefinition),
            "pbegenv" => Some(Self::Deprecated), //TODO: deprecated
            "pendenv" => Some(Self::Deprecated), //TODO: deprecated
            "mtxt" => Some(Self::Deprecated),    // TODO: deprecated
            "etxt" => Some(Self::Deprecated),    // TODO: deprecated
            "nodocclass" => Some(Self::Deprecated), // TODO: deprecated
            "nondocclass" => Some(Self::Deprecated), // TODO: deprecated
            _ => None,
        }
    }

    #[inline]
    pub fn get_definition_start_list() -> Vec<Self> {
        vec![
            Self::Defenv,
            Self::Redefenv,
            Self::FunctionDef,
            Self::LongFunctionDef,
            Self::OuterFunctionDef,
            Self::LongOuterFunctionDef,
            Self::EFunctionDef,
            Self::LongEFunctionDef,
            Self::OuterEFunctionDef,
            Self::LongOuterEFunctionDef,
            Self::GFunctionDef,
            Self::LongGFunctionDef,
            Self::OuterGFunctionDef,
            Self::LongOuterGFunctionDef,
            Self::XFunctionDef,
            Self::LongXFunctionDef,
            Self::OuterXFunctionDef,
            Self::LongOuterXFunctionDef,
        ]
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

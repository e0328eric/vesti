#[derive(Default, Clone, Debug)]
pub struct Token {
    pub toktype: TokenType,
    pub literal: String,
}

impl Token {
    pub fn new(toktype: TokenType, literal: impl ToString) -> Self {
        Self {
            toktype,
            literal: literal.to_string(),
        }
    }
}

#[derive(Clone, Copy, PartialEq, PartialOrd, Debug)]
pub enum TokenType {
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
    Begenv,
    Endenv,
    Mtxt,
    Etxt,
    DocumentStartMode,
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
    EndFunctionDef,

    // Symbols
    Plus,           // +
    Minus,          // -
    Star,           // *
    Slash,          // /
    Equal,          // =
    Less,           // <
    Great,          // >
    LessEq,         // <=
    GreatEq,        // >=
    LeftArrow,      // <-
    RightArrow,     // ->
    Bang,           // !
    Question,       // ?
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
    Lparen,   // (
    Rparen,   // )
    Lbrace,   // {
    Rbrace,   // }
    Lsqbrace, // [
    Rsqbrace, // ]
    // XXX: deprecate OptionalOpenBrace, // #[
    MathLbrace,      // \{
    MathRbrace,      // \}
    TextMathStart,   // \(
    TextMathEnd,     // \)
    InlineMathStart, // \[
    InlineMathEnd,   // \]

    // etc
    ArgSpliter,

    // error token
    Illegal,
}

impl Default for TokenType {
    fn default() -> Self {
        Self::Illegal
    }
}

impl TokenType {
    #[inline]
    pub fn is_keyword(&self) -> bool {
        Self::Docclass <= *self && *self <= Self::EndFunctionDef
    }

    // TODO: Deprecate 'docstartmode'
    pub fn is_keyword_str(string: &str) -> Option<TokenType> {
        match string {
            "docclass" => Some(Self::Docclass),
            "import" => Some(Self::Import),
            "startdoc" => Some(Self::StartDoc),
            "begenv" => Some(Self::Begenv),
            "endenv" => Some(Self::Endenv),
            "mtxt" => Some(Self::Mtxt),
            "etxt" => Some(Self::Etxt),
            "mst" => Some(Self::TextMathStart),
            "mnd" => Some(Self::TextMathEnd),
            "dmst" => Some(Self::InlineMathStart),
            "dmnd" => Some(Self::InlineMathEnd),
            "docstartmode" => Some(Self::DocumentStartMode),
            "nondocclass" => Some(Self::DocumentStartMode),
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
            "endfun" => Some(Self::EndFunctionDef),
            _ => None,
        }
    }

    #[inline]
    pub fn get_function_definition_start_list() -> Vec<Self> {
        vec![
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
    pub fn is_function_definition_start(&self) -> bool {
        Self::FunctionDef <= *self && *self <= Self::LongOuterXFunctionDef
    }

    #[inline]
    pub fn should_not_use_before_doc(self) -> bool {
        matches!(
            self,
            Self::Space2
                | Self::Begenv
                | Self::Endenv
                | Self::TextMathStart
                | Self::TextMathEnd
                | Self::InlineMathStart
                | Self::InlineMathEnd
        )
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

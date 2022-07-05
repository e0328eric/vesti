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
    Quote,          // '
    Quote2,         // `
    Doublequote,    // "

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

// TODO: Deprecate 'docstartmode'
pub fn is_keyword(string: &str) -> Option<TokenType> {
    match string {
        "docclass" => Some(TokenType::Docclass),
        "import" => Some(TokenType::Import),
        "startdoc" => Some(TokenType::StartDoc),
        "begenv" => Some(TokenType::Begenv),
        "endenv" => Some(TokenType::Endenv),
        "mtxt" => Some(TokenType::Mtxt),
        "etxt" => Some(TokenType::Etxt),
        "mst" => Some(TokenType::TextMathStart),
        "mnd" => Some(TokenType::TextMathEnd),
        "dmst" => Some(TokenType::InlineMathStart),
        "dmnd" => Some(TokenType::InlineMathEnd),
        "docstartmode" => Some(TokenType::DocumentStartMode),
        "nondocclass" => Some(TokenType::DocumentStartMode),
        _ => None,
    }
}

#[inline]
pub fn is_latex_function_ident(chr: char) -> bool {
    chr == '@' || chr.is_alphabetic()
}

impl TokenType {
    #[inline]
    pub fn should_not_use_before_doc(self) -> bool {
        self == TokenType::Space2
            || self == TokenType::Begenv
            || self == TokenType::Endenv
            || self == TokenType::TextMathStart
            || self == TokenType::TextMathEnd
            || self == TokenType::InlineMathStart
            || self == TokenType::InlineMathEnd
    }

    #[inline]
    pub fn can_pkg_name(&self) -> bool {
        *self == TokenType::Text || *self == TokenType::Minus || *self == TokenType::Integer
    }
}

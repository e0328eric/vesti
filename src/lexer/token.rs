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
    Newline2,       // #@
    MathSmallSpace, // \,
    MathLargeSpace, // \;

    // Identifiers
    Integer,
    Float,
    MainString,
    LatexFunction,
    RawLatex,

    // Keywords
    Docclass,
    Import,
    Document,
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
    Bang,           // !
    Question,       // ?
    Dollar,         // $
    Dollar2,        // $
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
    Lparen,            // (
    Rparen,            // )
    Lbrace,            // {
    Rbrace,            // }
    Lsqbrace,          // [
    Rsqbrace,          // ]
    OptionalOpenBrace, // #[
    MathLbrace,        // \{
    MathRbrace,        // \}
    TextMathStart,     // $ or \(
    TextMathEnd,       // $ or \)
    InlineMathStart,   // $$ or \[
    InlineMathEnd,     // $$ or \]

    // etc
    ArgSpliter,

    // error token
    ILLEGAL,
}

impl Default for TokenType {
    fn default() -> Self {
        Self::ILLEGAL
    }
}

pub fn is_keyword(string: &str) -> Option<TokenType> {
    match string {
        "docclass" => Some(TokenType::Docclass),
        "import" => Some(TokenType::Import),
        "document" => Some(TokenType::Document),
        "begenv" => Some(TokenType::Begenv),
        "endenv" => Some(TokenType::Endenv),
        "mtxt" => Some(TokenType::Mtxt),
        "etxt" => Some(TokenType::Etxt),
        "mst" => Some(TokenType::TextMathStart),
        "mnd" => Some(TokenType::TextMathEnd),
        "dmst" => Some(TokenType::InlineMathStart),
        "dmnd" => Some(TokenType::InlineMathEnd),
        "docstartmode" => Some(TokenType::DocumentStartMode),
        _ => None,
    }
}

pub fn is_latex_function_ident(chr: char) -> bool {
    chr == '@' || chr.is_alphabetic()
}

impl TokenType {
    pub fn should_not_use_before_doc(self) -> bool {
        self == TokenType::Space2
            || self == TokenType::Begenv
            || self == TokenType::Endenv
            || self == TokenType::TextMathStart
            || self == TokenType::TextMathEnd
            || self == TokenType::InlineMathStart
            || self == TokenType::InlineMathEnd
    }

    pub fn can_pkg_name(&self) -> bool {
        *self == TokenType::MainString || *self == TokenType::Minus || *self == TokenType::Integer
    }
}

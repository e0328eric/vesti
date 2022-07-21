#[cfg(test)]
mod lexer_test;

#[macro_use]
mod macros;

mod newline_handler;
pub mod token;

use crate::location::{Location, Span};
use newline_handler::Newlinehandler;
use token::{Token, TokenType};

#[derive(Clone, Debug)]
pub struct LexToken {
    pub token: Token,
    pub span: Span,
}

impl LexToken {
    pub fn new(token: Token, start: Location, end: Location) -> Self {
        Self {
            token,
            span: Span { start, end },
        }
    }

    fn illegal(start: Location, end: Location) -> Self {
        Self {
            token: Token::default(),
            span: Span { start, end },
        }
    }
}

#[derive(Clone)]
pub struct Lexer<'a> {
    source: Newlinehandler<'a>,
    chr0: Option<char>,
    chr1: Option<char>,
    chr2: Option<char>,
    current_loc: Location,
    pub math_started: bool,
}

impl<'a> Lexer<'a> {
    pub fn new<T: AsRef<str> + ?Sized>(source: &'a T) -> Self {
        let mut output = Self {
            source: Newlinehandler::new(source),
            chr0: None,
            chr1: None,
            chr2: None,
            current_loc: Location::default(),
            math_started: false,
        };
        output.next_char();
        output.next_char();
        output.next_char();
        output.current_loc.reset_location();
        output
    }

    fn next_char(&mut self) {
        if self.chr0 == Some('\n') {
            self.current_loc.move_next_line();
        } else {
            self.current_loc.move_right(self.chr0.as_ref());
        }
        self.chr0 = self.chr1;
        self.chr1 = self.chr2;
        self.chr2 = self.source.next();
    }

    fn take_tok(&mut self) -> Option<LexToken> {
        let start_loc = self.current_loc;
        match self.chr0 {
            Some('\0') | None => None,
            Some(' ') => {
                if self.chr1 == Some('@') && self.chr2 != Some('!') {
                    self.next_char();
                    tokenize!(self:ArgSpliter, ""; start_loc)
                } else {
                    tokenize!(self:Space, " "; start_loc)
                }
            }
            Some('\t') => tokenize!(self:Tab, "\t"; start_loc),
            Some('\n') => tokenize!(self:Newline, "\n"; start_loc),
            Some('+') => tokenize!(self: Plus, "+"; start_loc),
            Some('-') => match self.chr1 {
                Some('>') if self.math_started => {
                    self.next_char();
                    tokenize!(self: RightArrow, "\\rightarrow "; start_loc)
                }
                Some(chr) if chr.is_ascii_digit() => Some(self.lex_number()),
                _ => tokenize!(self: Minus, "-"; start_loc),
            },
            Some('*') => tokenize!(self: Star, "*"; start_loc),
            Some('/') => tokenize!(self: Slash, "/";start_loc),
            Some('=') => tokenize!(self: Equal , "="; start_loc),
            Some('<') => match self.chr1 {
                Some('=') => {
                    self.next_char();
                    tokenize!(self: LessEq, "<="; start_loc)
                }
                Some('-') if self.math_started => {
                    self.next_char();
                    tokenize!(self: LeftArrow, "\\leftarrow "; start_loc)
                }
                _ => tokenize!(self: Less, "<"; start_loc),
            },
            Some('>') => {
                if self.chr1 == Some('=') {
                    self.next_char();
                    tokenize!(self: GreatEq, ">="; start_loc)
                } else {
                    tokenize!(self: Great, ">"; start_loc)
                }
            }
            Some('!') => tokenize!(self: Bang, "!"; start_loc),
            Some('?') => tokenize!(self: Question, "?"; start_loc),
            Some('@') => {
                if self.chr1 == Some('!') {
                    self.next_char();
                    tokenize!(self: At, "@"; start_loc)
                } else {
                    tokenize!(self: ArgSpliter, "@"; start_loc)
                }
            }
            Some('#') => tokenize!(self: FntParam, "#"; start_loc),
            Some('^') => tokenize!(self: Superscript, "^"; start_loc),
            Some('&') => tokenize!(self: Ampersand, "&"; start_loc),
            Some(';') => tokenize!(self: Semicolon, ";"; start_loc),
            Some(':') => tokenize!(self: Colon, ":"; start_loc),
            Some('\'') => tokenize!(self: RightQuote, "'"; start_loc),
            Some('`') => tokenize!(self: LeftQuote, "`"; start_loc),
            Some('"') => tokenize!(self: DoubleQuote, "\""; start_loc),
            Some('_') => tokenize!(self: Subscript, "_"; start_loc),
            Some('|') => tokenize!(self: Vert, "|"; start_loc),
            Some('.') => tokenize!(self: Period, "."; start_loc),
            Some(',') => tokenize!(self: Comma, ","; start_loc),
            Some('~') => tokenize!(self: Tilde, "~"; start_loc),
            Some('(') => tokenize!(self: Lparen, "("; start_loc),
            Some(')') => tokenize!(self: Rparen, ")"; start_loc),
            Some('{') => tokenize!(self: Lbrace, "{"; start_loc),
            Some('}') => tokenize!(self: Rbrace, "}"; start_loc),
            Some('[') => tokenize!(self: Lsqbrace, "["; start_loc),
            Some(']') => tokenize!(self: Rsqbrace, "]"; start_loc),
            Some('$') => self.lex_dollar_char(),
            Some('%') => self.lex_percent_char(),
            Some('\\') => self.lex_backslash(),
            _ if self.chr0.map_or(false, |chr| chr.is_alphabetic()) => Some(self.lex_main_string()),
            _ if self.chr0.map_or(false, |chr| chr.is_ascii_digit()) => Some(self.lex_number()),
            _ => {
                self.next_char();
                Some(LexToken::illegal(start_loc, self.current_loc))
            }
        }
    }

    fn lex_main_string(&mut self) -> LexToken {
        let start_loc = self.current_loc;
        let mut literal = String::new();
        while let Some(chr) = self.chr0 {
            if !chr.is_alphanumeric() {
                break;
            }
            literal.push(chr);
            self.next_char();
        }
        let toktype = if let Some(toktype) = TokenType::is_keyword_str(&literal) {
            if &literal == "mnd" && self.chr0 == Some(' ') {
                self.next_char();
            }
            toktype
        } else {
            TokenType::Text
        };
        LexToken::new(Token::new(toktype, literal), start_loc, self.current_loc)
    }

    // TODO: lexing failed for large integers
    fn lex_number(&mut self) -> LexToken {
        let start_loc = self.current_loc;
        let mut literal = String::new();

        if self.chr0 == Some('-') {
            literal.push('-');
            self.next_char();
        }

        let toktype;
        if self.chr0 == Some('0') && self.chr1.map_or(false, |chr| chr.is_ascii_digit()) {
            toktype = TokenType::Text;
            while let Some(chr) = self.chr0 {
                if !chr.is_ascii_digit() {
                    break;
                }
                literal.push(chr);
                self.next_char();
            }
        } else {
            while let Some(chr) = self.chr0 {
                if !chr.is_ascii_digit() {
                    break;
                }
                literal.push(chr);
                self.next_char();
            }

            toktype =
                if self.chr0 == Some('.') && self.chr1.map_or(false, |chr| chr.is_ascii_digit()) {
                    literal.push('.');
                    self.next_char();
                    TokenType::Float
                } else {
                    TokenType::Integer
                };

            if self.chr0.map_or(false, |chr| chr.is_ascii_digit()) {
                while let Some(chr) = self.chr0 {
                    if !chr.is_ascii_digit() {
                        break;
                    }
                    literal.push(chr);
                    self.next_char();
                }
            }
        }

        LexToken::new(Token::new(toktype, literal), start_loc, self.current_loc)
    }

    fn lex_percent_char(&mut self) -> Option<LexToken> {
        let start_loc = self.current_loc;
        match self.chr1 {
            Some('!') => {
                self.next_char();
                tokenize!(self: LatexComment, "%"; start_loc)
            }
            Some('*') => {
                self.next_char();
                self.next_char();
                while self.chr0? != '*' || self.chr1 != Some('%') {
                    self.next_char();
                }
                self.next_char();
                self.next_char();
                if self.chr0 == Some('\n') {
                    self.next_char();
                }
                self.take_tok()
            }
            Some('-') => {
                let mut literal = String::new();
                self.next_char();
                self.next_char();
                while self.chr0 != Some('-') || self.chr1 != Some('%') {
                    literal.push(self.chr0?);
                    self.next_char();
                }
                self.next_char();
                self.next_char();
                Some(LexToken::new(
                    Token::new(TokenType::RawLatex, literal),
                    start_loc,
                    self.current_loc,
                ))
            }
            _ => {
                while self.chr0? != '\n' {
                    self.next_char();
                }
                self.next_char();
                self.take_tok()
            }
        }
    }

    fn lex_dollar_char(&mut self) -> Option<LexToken> {
        let start_loc = self.current_loc;
        match self.chr1 {
            Some('!') => {
                self.next_char();
                tokenize!(self: Dollar, "$"; start_loc)
            }
            _ => {
                if !self.math_started {
                    self.math_started = true;
                    tokenize!(self: TextMathStart, "$"; start_loc)
                } else {
                    self.math_started = false;
                    tokenize!(self: TextMathEnd, "$"; start_loc)
                }
            }
        }
    }

    fn lex_backslash(&mut self) -> Option<LexToken> {
        let start_loc = self.current_loc;
        match self.chr1 {
            Some('#') => {
                self.next_char();
                tokenize!(self: Sharp, "\\#"; start_loc)
            }
            Some('$') => {
                self.next_char();
                tokenize!(self: Dollar, "\\$"; start_loc)
            }
            Some('%') => {
                self.next_char();
                tokenize!(self: Percent, "\\%"; start_loc)
            }
            Some(',') => {
                self.next_char();
                if self.math_started {
                    tokenize!(self: MathSmallSpace, "\\,"; start_loc)
                } else {
                    tokenize!(self: Comma, ","; start_loc)
                }
            }
            Some('(') => {
                self.math_started = true;
                self.next_char();
                tokenize!(self: TextMathStart, "$"; start_loc)
            }
            Some(')') => {
                self.math_started = false;
                self.next_char();
                tokenize!(self: TextMathEnd, "$"; start_loc)
            }
            Some('[') => {
                self.math_started = true;
                self.next_char();
                tokenize!(self: InlineMathStart, "\\["; start_loc)
            }
            Some(']') => {
                self.math_started = false;
                self.next_char();
                tokenize!(self: InlineMathEnd, "\\]"; start_loc)
            }
            Some('{') => {
                self.next_char();
                tokenize!(self: MathLbrace, "\\{"; start_loc)
            }
            Some('}') => {
                self.next_char();
                tokenize!(self: MathRbrace, "\\}"; start_loc)
            }
            Some(' ') => {
                self.next_char();
                if self.math_started {
                    tokenize!(self: MathLargeSpace, "\\;"; start_loc)
                } else {
                    tokenize!(self: Space2, "\\ "; start_loc)
                }
            }
            Some('\\') => {
                self.next_char();
                tokenize!(self: BackSlash, "\\\\"; start_loc)
            }
            _ if self.chr1.map_or(false, token::is_latex_function_ident) => {
                self.next_char();
                let mut literal = String::from("\\");
                while let Some(chr) = self.chr0 {
                    if !token::is_latex_function_ident(chr) {
                        break;
                    }
                    literal.push(chr);
                    self.next_char();
                }
                Some(LexToken::new(
                    Token::new(TokenType::LatexFunction, literal),
                    start_loc,
                    self.current_loc,
                ))
            }
            _ => tokenize!(self: ShortBackSlash, "\\"; start_loc),
        }
    }
}

impl<'a> Iterator for Lexer<'a> {
    type Item = LexToken;
    fn next(&mut self) -> Option<Self::Item> {
        self.take_tok()
    }
}

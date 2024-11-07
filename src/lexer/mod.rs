#[cfg(test)]
mod lexer_test;

#[macro_use]
mod macros;

pub(crate) mod newline_handler;
pub mod token;

use crate::location::{Location, Span};
use newline_handler::Newlinehandler;
use token::{Token, TokenType};

#[derive(Clone)]
pub struct Lexer<'a> {
    source: Newlinehandler<'a>,
    pub(crate) chr0: Option<char>,
    chr1: Option<char>,
    chr2: Option<char>,
    chr3: Option<char>,
    current_loc: Location,
    math_started: bool,
    math_string_started: bool,
    use_subscript_as_letter: bool,
    is_latex3_on: bool,
    lex_with_verbatim: bool,
}

impl<'a> Lexer<'a> {
    pub fn new<T: AsRef<str> + ?Sized>(source: &'a T) -> Self {
        let mut output = Self {
            source: Newlinehandler::new(source),
            chr0: None,
            chr1: None,
            chr2: None,
            chr3: None,
            current_loc: Location::default(),
            math_started: false,
            math_string_started: false,
            use_subscript_as_letter: false,
            is_latex3_on: false,
            lex_with_verbatim: false,
        };
        output.next_char();
        output.next_char();
        output.next_char();
        output.next_char();
        output.current_loc.reset_location();
        output
    }

    #[inline]
    pub fn get_math_started(&self) -> bool {
        self.math_started
    }

    #[inline]
    pub fn set_math_started(&mut self, val: bool) {
        self.math_started = val;
    }

    #[inline]
    pub fn switch_lex_with_verbatim(&mut self) {
        self.lex_with_verbatim = !self.lex_with_verbatim;
    }

    fn next_char(&mut self) {
        if self.chr0 == Some('\n') {
            self.current_loc.move_next_line();
        } else {
            self.current_loc.move_right(self.chr0.as_ref());
        }
        self.chr0 = self.chr1;
        self.chr1 = self.chr2;
        self.chr2 = self.chr3;
        self.chr3 = self.source.next();
    }

    pub fn next(&mut self) -> Token {
        let start_loc = self.current_loc;

        if self.lex_with_verbatim {
            let token = if let Some(chr) = self.chr0 {
                Token {
                    toktype: TokenType::VerbatimChar(chr),
                    literal: String::new(),
                    span: Span {
                        start: start_loc,
                        end: self.current_loc,
                    },
                }
            } else {
                Token {
                    toktype: TokenType::Eof,
                    literal: String::new(),
                    span: Span {
                        start: start_loc,
                        end: self.current_loc,
                    },
                }
            };

            self.next_char();
            return token;
        }

        match self.chr0 {
            Some('\0') | None => Token::eof(start_loc, self.current_loc),
            Some(' ') => tokenize!(self:Space, " "; start_loc),
            Some('\t') => tokenize!(self:Tab, "\t"; start_loc),
            Some('\n') => tokenize!(self:Newline, "\n"; start_loc),
            Some('+') => tokenize!(self: Plus, "+"; start_loc),
            Some('-') => match (self.chr1, self.chr2) {
                (Some('-'), Some('>')) if self.math_started => {
                    self.next_char();
                    self.next_char();
                    tokenize!(self: LongRightArrow, "\\longrightarrow "; start_loc)
                }
                (Some('>'), _) if self.math_started => {
                    self.next_char();
                    tokenize!(self: RightArrow, "\\rightarrow "; start_loc)
                }
                (Some('-'), _) if self.math_started => {
                    self.next_char();
                    tokenize!(self: SetMinus, "\\setminus "; start_loc)
                }
                (Some(chr), _) if chr.is_ascii_digit() => self.lex_number(),
                _ => tokenize!(self: Minus, "-"; start_loc),
            },
            Some('*') => tokenize!(self: Star, "*"; start_loc),
            Some('/') => match self.chr1 {
                Some('=') => {
                    self.next_char();
                    tokenize!(self: NotEqual, "\\neq "; start_loc)
                }
                Some('!') => {
                    self.next_char();
                    tokenize!(self: Slash, "/"; start_loc)
                }
                Some('/') => match self.chr2 {
                    Some('!') => tokenize!(self: Slash, "/"; start_loc),
                    _ => {
                        self.next_char();
                        tokenize!(self: FracDefiner, "//"; start_loc)
                    }
                },
                _ => tokenize!(self: Slash, "/"; start_loc),
            },
            Some('!') => {
                if self.math_started && self.chr1 == Some('=') {
                    self.next_char();
                    tokenize!(self: NotEqual, "\\neq "; start_loc)
                } else {
                    tokenize!(self: Bang, "!"; start_loc)
                }
            }
            Some('=') => match (self.chr1, self.chr2) {
                (Some('='), Some('>')) if self.math_started => {
                    self.next_char();
                    self.next_char();
                    tokenize!(self: LongDoubleRightArrow, "\\Longrightarrow "; start_loc)
                }
                (Some('>'), _) if self.math_started => {
                    self.next_char();
                    tokenize!(self: DoubleRightArrow, "\\Rightarrow "; start_loc)
                }
                _ => tokenize!(self: Equal , "="; start_loc),
            },
            Some('<') => self.lex_less_than(),
            Some('>') => match self.chr1 {
                Some('=') if self.math_started => {
                    self.next_char();
                    tokenize!(self: GreatEq, "\\geq "; start_loc)
                }
                _ => tokenize!(self: Great, ">"; start_loc),
            },
            Some('?') => tokenize!(self: Question, "?"; start_loc),
            Some('@') => match self.chr1 {
                Some('}') if self.math_started => {
                    self.next_char();
                    tokenize!(self: Rangle, "\\rangle "; start_loc)
                }
                _ => tokenize!(self: At, "@"; start_loc),
            },
            Some('#') => tokenize!(self: FntParam, "#"; start_loc),
            Some('^') => tokenize!(self: Superscript, "^"; start_loc),
            Some('&') => tokenize!(self: Ampersand, "&"; start_loc),
            Some(';') => tokenize!(self: Semicolon, ";"; start_loc),
            Some(':') => tokenize!(self: Colon, ":"; start_loc),
            Some('\'') => tokenize!(self: RightQuote, "'"; start_loc),
            Some('`') => tokenize!(self: LeftQuote, "`"; start_loc),
            Some('"') => {
                if self.math_string_started {
                    self.math_string_started = false;
                    tokenize!(self:MathTextEnd, "\""; start_loc)
                } else if self.math_started {
                    self.math_string_started = true;
                    tokenize!(self:MathTextStart, "\""; start_loc)
                } else {
                    tokenize!(self: DoubleQuote, "\""; start_loc)
                }
            }
            Some('_') => tokenize!(self: Subscript, "_"; start_loc),
            Some('|') => match self.chr1 {
                Some('-') => match self.chr2 {
                    Some('>') => {
                        self.next_char();
                        self.next_char();
                        tokenize!(self: MapsTo, "\\mapsto "; start_loc)
                    }
                    _ => tokenize!(self: Vert, "|"; start_loc),
                },
                Some('|') if self.math_started => {
                    self.next_char();
                    tokenize!(self: Norm, "\\|"; start_loc)
                }
                _ => tokenize!(self: Vert, "|"; start_loc),
            },
            Some('.') => match (self.chr1, self.chr2) {
                (Some('.'), Some('.')) if self.math_started => {
                    self.next_char();
                    self.next_char();
                    tokenize!(self: CenterDots, "\\cdots "; start_loc)
                }
                _ => tokenize!(self: Period, "."; start_loc),
            },
            Some(',') => tokenize!(self: Comma, ","; start_loc),
            Some('~') => tokenize!(self: Tilde, "~"; start_loc),
            Some('(') => tokenize!(self: Lparen, "("; start_loc),
            Some(')') => tokenize!(self: Rparen, ")"; start_loc),
            Some('[') => tokenize!(self: Lsqbrace, "["; start_loc),
            Some(']') => tokenize!(self: Rsqbrace, "]"; start_loc),
            Some('{') => match self.chr1 {
                Some('@') if self.math_started => {
                    self.next_char();
                    tokenize!(self: Langle, "\\langle "; start_loc)
                }
                _ => tokenize!(self: Lbrace, "{"; start_loc),
            },
            Some('}') => tokenize!(self: Rbrace, "}"; start_loc),

            Some('$') => self.lex_dollar_char(),
            Some('%') => self.lex_percent_char(),
            Some('\\') => self.lex_backslash(),
            Some('o') => match (self.chr1, self.chr2) {
                (Some('o'), Some(chr)) if self.math_started && !chr.is_alphabetic() => {
                    self.next_char();
                    tokenize!(self: InfinitySym, "\\infty "; start_loc)
                }
                _ => self.lex_main_string(),
            },
            Some(chr) if chr.is_alphabetic() => self.lex_main_string(),
            Some(chr) if chr.is_ascii_digit() => self.lex_number(),
            Some(chr) => tokenize!(self: OtherChar, chr; start_loc),
        }
    }

    fn lex_main_string(&mut self) -> Token {
        let start_loc = self.current_loc;

        let mut literal = String::with_capacity(16);

        while let Some(chr) = self.chr0 {
            if !chr.is_alphanumeric() {
                break;
            }
            literal.push(chr);
            self.next_char();
        }
        let toktype = if let Some(toktype) = TokenType::is_keyword_str(&literal) {
            match toktype {
                TokenType::MakeAtLetter => self.use_subscript_as_letter = true,
                TokenType::MakeAtOther => self.use_subscript_as_letter = false,
                TokenType::Latex3On => self.is_latex3_on = true,
                TokenType::Latex3Off => self.is_latex3_on = false,
                _ => {}
            }
            toktype
        } else {
            TokenType::Text
        };
        Token::new(toktype, literal, start_loc, self.current_loc)
    }

    // TODO: lexing failed for large integers
    fn lex_number(&mut self) -> Token {
        let start_loc = self.current_loc;

        let mut literal = String::new();

        if self.chr0 == Some('-') {
            literal.push('-');
            self.next_char();
        }

        let mut toktype;
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
                    match chr {
                        '1'..='9' => {
                            literal.push(chr);
                            self.next_char();
                        }
                        '0' => {
                            if self.chr1.map(|ch| ch.is_ascii_digit()) != Some(true) {
                                toktype = TokenType::Text;
                                literal.push(chr);
                                self.next_char();
                            } else {
                                literal.push(chr);
                                self.next_char();
                            }
                        }
                        _ => break,
                    }
                }
            }
        }

        Token::new(toktype, literal, start_loc, self.current_loc)
    }

    fn lex_percent_char(&mut self) -> Token {
        let start_loc = self.current_loc;

        match self.chr1 {
            Some('!') => {
                self.next_char();
                tokenize!(self: LatexComment, "%"; start_loc)
            }
            Some('*') => {
                self.next_char();
                self.next_char();
                while unwrap!(self: chr0, start_loc) != '*' || self.chr1 != Some('%') {
                    self.next_char();
                }
                self.next_char();
                self.next_char();
                if self.chr0 == Some('\n') {
                    self.next_char();
                }
                self.next()
            }
            Some('-') => match self.chr2 {
                Some('#') => {
                    let mut literal = String::new();
                    self.next_char();
                    self.next_char();
                    self.next_char();
                    while self.chr0 != Some('\n') {
                        literal.push(unwrap!(self: chr0, start_loc));
                        self.next_char();
                    }
                    literal.push(unwrap!(self: chr0, start_loc));
                    self.next_char();
                    Token::new(TokenType::RawLatex, literal, start_loc, self.current_loc)
                }
                _ => {
                    let mut literal = String::new();
                    self.next_char();
                    self.next_char();
                    while self.chr0 != Some('-') || self.chr1 != Some('%') {
                        literal.push(unwrap!(self: chr0, start_loc));
                        self.next_char();
                    }
                    self.next_char();
                    self.next_char();
                    Token::new(TokenType::RawLatex, literal, start_loc, self.current_loc)
                }
            },
            _ => {
                while unwrap!(self: chr0, start_loc) != '\n' {
                    self.next_char();
                }
                self.next_char();
                self.next()
            }
        }
    }

    fn lex_dollar_char(&mut self) -> Token {
        let start_loc = self.current_loc;

        match self.chr1 {
            Some('!') => {
                self.next_char();
                tokenize!(self: RawDollar, "$"; start_loc)
            }
            Some('$') => {
                self.next_char();
                if !self.math_started {
                    self.math_started = true;
                    tokenize!(self: DisplayMathStart, "$"; start_loc)
                } else {
                    self.math_started = false;
                    tokenize!(self: DisplayMathEnd, "$"; start_loc)
                }
            }
            _ => {
                if !self.math_started {
                    self.math_started = true;
                    tokenize!(self: InlineMathStart, "$"; start_loc)
                } else {
                    self.math_started = false;
                    tokenize!(self: InlineMathEnd, "$"; start_loc)
                }
            }
        }
    }

    fn lex_backslash(&mut self) -> Token {
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
            Some('?') => {
                self.next_char();
                tokenize!(self: RawQuestion, "?"; start_loc)
            }
            Some('^') => {
                self.next_char();
                tokenize!(self: HatAccent, "\\^"; start_loc)
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
                tokenize!(self: RawLbrace, "("; start_loc)
            }
            Some(')') => {
                self.math_started = false;
                self.next_char();
                tokenize!(self: RawRbrace, ")"; start_loc)
            }
            Some('[') => {
                self.math_started = true;
                self.next_char();
                tokenize!(self: DisplayMathStart, "\\["; start_loc)
            }
            Some(']') => {
                self.math_started = false;
                self.next_char();
                tokenize!(self: DisplayMathEnd, "\\]"; start_loc)
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
            Some('"') => {
                if self.math_started {
                    self.next_char();
                    tokenize!(self: DoubleQuote, "\\\""; start_loc)
                } else {
                    tokenize!(self: ShortBackSlash, "\\"; start_loc)
                }
            }
            Some('\\') => {
                self.next_char();
                tokenize!(self: BackSlash, "\\\\"; start_loc)
            }
            _ if self.chr1.map_or(false, |chr| {
                token::is_latex_function_ident(chr, self.use_subscript_as_letter, self.is_latex3_on)
            }) =>
            {
                self.next_char();
                let mut literal = String::from("\\");
                while let Some(chr) = self.chr0 {
                    if !token::is_latex_function_ident(
                        chr,
                        self.use_subscript_as_letter,
                        self.is_latex3_on,
                    ) {
                        break;
                    }
                    literal.push(chr);
                    self.next_char();
                }

                if !self.is_latex3_on {
                    literal = literal.replace('_', "@");
                }

                Token::new(
                    TokenType::LatexFunction,
                    literal,
                    start_loc,
                    self.current_loc,
                )
            }
            _ => tokenize!(self: ShortBackSlash, "\\"; start_loc),
        }
    }

    fn lex_less_than(&mut self) -> Token {
        let start_loc = self.current_loc;

        if !self.math_started {
            return tokenize!(self: Less, "<"; start_loc);
        }

        match (self.chr1, self.chr2, self.chr3) {
            (Some('='), Some('='), Some('>')) => {
                self.next_char();
                self.next_char();
                self.next_char();
                tokenize!(self: LongDoubleLeftRightArrow, "\\Longleftrightarrow "; start_loc)
            }
            (Some('-'), Some('-'), Some('>')) => {
                self.next_char();
                self.next_char();
                self.next_char();
                tokenize!(self: LongLeftRightArrow, "\\longleftrightarrow "; start_loc)
            }
            (Some('='), Some('='), _) => {
                self.next_char();
                self.next_char();
                tokenize!(self: LongDoubleLeftArrow, "\\Longleftarrow "; start_loc)
            }
            (Some('='), Some('>'), _) => {
                self.next_char();
                self.next_char();
                tokenize!(self: DoubleLeftRightArrow, "\\Leftrightarrow "; start_loc)
            }
            (Some('-'), Some('-'), _) => {
                self.next_char();
                self.next_char();
                tokenize!(self: LongLeftArrow, "\\longleftarrow "; start_loc)
            }
            (Some('-'), Some('>'), _) => {
                self.next_char();
                self.next_char();
                tokenize!(self: LeftRightArrow, "\\leftrightarrow "; start_loc)
            }
            (Some('='), _, _) => {
                self.next_char();
                tokenize!(self: LessEq, "\\leq "; start_loc)
            }
            (Some('-'), _, _) => {
                self.next_char();
                tokenize!(self: LeftArrow, "\\leftarrow "; start_loc)
            }
            _ => tokenize!(self: Less, "<"; start_loc),
        }
    }
}

#[cfg(test)]
mod lexer_test;

pub mod token;

use std::borrow::Cow;
use std::str::CharIndices;

use crate::location::{Location, Span};
use token::{Token, TokenType};

/// A single source character: its starting byte offset plus the `&str` slice
/// that spells it. `location.rs` measures display width from the slice, and the
/// byte offset lets the lexer cut literals straight out of the source.
// TODO: get rid of this stupid container
pub type Char<'a> = (usize, &'a str);

#[derive(Clone)]
pub struct Lexer<'s> {
    source: &'s str,
    chars: CharIndices<'s>,
    chr0: Option<Char<'s>>,
    chr1: Option<Char<'s>>,
    chr2: Option<Char<'s>>,
    chr3: Option<Char<'s>>,
    current_loc: Location,
    /// Treat `@` as a letter (set externally, e.g. by `#at_on`).
    make_at_letter: bool,
    /// Treat `_`/`:` as letters (LaTeX3 names; set externally).
    is_latex3_on: bool,
    /// Long-bracket `=` counts for the currently open multiline comment.
    comment_open_eq_count: usize,
    comment_closed_eq_count: usize,
}

impl<'s> Lexer<'s> {
    pub fn new<T: AsRef<str> + ?Sized>(source: &'s T) -> Self {
        let source = source.as_ref();
        let mut lexer = Lexer {
            source,
            chars: source.char_indices(),
            chr0: None,
            chr1: None,
            chr2: None,
            chr3: None,
            current_loc: Location::default(),
            make_at_letter: false,
            is_latex3_on: false,
            comment_open_eq_count: 0,
            comment_closed_eq_count: 0,
        };
        // Prime the four-character window, then reset the location so the first
        // real character reports as (row 1, col 1).
        lexer.next_char();
        lexer.next_char();
        lexer.next_char();
        lexer.next_char();
        lexer.current_loc.reset_location();
        lexer
    }

    #[inline]
    pub fn make_at_letter(&self) -> bool {
        self.make_at_letter
    }

    #[inline]
    pub fn set_make_at_letter(&mut self, value: bool) {
        self.make_at_letter = value;
    }

    #[inline]
    pub fn is_latex3_on(&self) -> bool {
        self.is_latex3_on
    }

    #[inline]
    pub fn set_latex3(&mut self, value: bool) {
        self.is_latex3_on = value;
    }

    // --- low level cursor --------------------------------------------------

    fn next_char(&mut self) {
        // Advance the location using the character we are leaving behind.
        match self.chr0 {
            Some((_, "\n")) => self.current_loc.move_next_line(),
            other => self.current_loc.move_right(other),
        }

        let source = self.source;
        self.chr0 = self.chr1;
        self.chr1 = self.chr2;
        self.chr2 = self.chr3;
        self.chr3 = self
            .chars
            .next()
            .map(|(idx, chr)| (idx, &source[idx..idx + chr.len_utf8()]));
    }

    #[inline]
    fn advance(&mut self, n: usize) {
        for _ in 0..n {
            self.next_char();
        }
    }

    #[inline]
    fn cur_char(&self) -> Option<char> {
        self.chr0.and_then(|(_, s)| s.chars().next())
    }

    #[inline]
    fn peek1_char(&self) -> Option<char> {
        self.chr1.and_then(|(_, s)| s.chars().next())
    }

    #[inline]
    fn peek2_char(&self) -> Option<char> {
        self.chr2.and_then(|(_, s)| s.chars().next())
    }

    /// Byte offset of the current character (end of source when exhausted).
    #[inline]
    fn cur_idx(&self) -> usize {
        self.chr0.map_or(self.source.len(), |(idx, _)| idx)
    }

    #[inline]
    fn span_to_now(&self, start: Location) -> Span {
        Span {
            start,
            end: self.current_loc,
        }
    }

    /// A token whose text- and math-mode spellings are identical.
    #[inline]
    fn sym(&self, toktype: TokenType<'s>, lit: &'static str, start: Location) -> Token<'s> {
        Token::new(
            toktype,
            Cow::Borrowed(lit),
            Cow::Borrowed(lit),
            self.span_to_now(start),
        )
    }

    /// A token with distinct text- and math-mode spellings.
    #[inline]
    fn sym_math(
        &self,
        toktype: TokenType<'s>,
        in_text: &'static str,
        in_math: &'static str,
        start: Location,
    ) -> Token<'s> {
        Token::new(
            toktype,
            Cow::Borrowed(in_text),
            Cow::Borrowed(in_math),
            self.span_to_now(start),
        )
    }

    /// A token whose literal is the source slice `[start_idx, current)`.
    #[inline]
    fn slice_tok(&self, toktype: TokenType<'s>, start_idx: usize, start: Location) -> Token<'s> {
        let lit = &self.source[start_idx..self.cur_idx()];
        Token::new(
            toktype,
            Cow::Borrowed(lit),
            Cow::Borrowed(lit),
            self.span_to_now(start),
        )
    }

    #[inline]
    fn is_eof(c: Option<char>) -> bool {
        matches!(c, None | Some('\0'))
    }

    // --- main dispatch -----------------------------------------------------

    pub fn next(&mut self) -> Token<'s> {
        loop {
            let start_loc = self.current_loc;
            let start_idx = self.cur_idx();

            match self.cur_char() {
                None | Some('\0') => return Token::eof(start_loc, self.current_loc),

                // Normalize CRLF / lone CR into a single newline token.
                Some('\r') => {
                    if self.peek1_char() == Some('\n') {
                        self.advance(2);
                    } else {
                        self.advance(1);
                    }
                    return self.sym(TokenType::Newline, "\n", start_loc);
                }

                Some('%') => {
                    self.advance(1);
                    return self.lex_percent(start_loc);
                }

                // `oo` -> \infty, otherwise ordinary text starting at this `o`.
                Some('o') => {
                    self.advance(1);
                    return self.lex_o(start_idx, start_loc);
                }

                Some('-') => match (self.peek1_char(), self.peek2_char()) {
                    (Some('-'), Some('>')) => {
                        self.advance(3);
                        return self.sym_math(
                            TokenType::LongRightArrow,
                            "-->",
                            "\\longrightarrow ",
                            start_loc,
                        );
                    }
                    (Some('-'), Some('-')) => {
                        self.advance(3);
                        return self.sym(TokenType::EmDash, "---", start_loc);
                    }
                    (Some('-'), Some('!')) => {
                        // The trailing `!` is dropped from the literal.
                        self.advance(3);
                        return self.sym(TokenType::EnDash, "--", start_loc);
                    }
                    // `--` (anything else) opens a comment.
                    (Some('-'), _) => {
                        self.advance(2);
                        match self.skip_comment(start_idx, start_loc) {
                            Some(tok) => return tok,
                            None => continue,
                        }
                    }
                    (Some('!'), _) => {
                        self.advance(2);
                        return self.sym_math(TokenType::SetMinus, "-!", "\\setminus ", start_loc);
                    }
                    (Some('>'), _) => {
                        self.advance(2);
                        return self.sym_math(
                            TokenType::RightArrow,
                            "->",
                            "\\rightarrow ",
                            start_loc,
                        );
                    }
                    (Some('.'), _) => {
                        self.advance(1);
                        return self.lex_float(start_idx, start_loc);
                    }
                    (Some(c), _) if c.is_ascii_digit() => {
                        self.advance(1);
                        return self.lex_integer(start_idx, start_loc);
                    }
                    _ => {
                        self.advance(1);
                        return self.sym(TokenType::Minus, "-", start_loc);
                    }
                },

                Some('!') => {
                    if self.peek1_char() == Some('=') {
                        self.advance(2);
                        return self.sym_math(TokenType::NotEqual, "!=", "\\neq ", start_loc);
                    }
                    self.advance(1);
                    return self.sym(TokenType::Bang, "!", start_loc);
                }

                Some('/') => match self.peek1_char() {
                    Some('=') => {
                        self.advance(2);
                        return self.sym_math(TokenType::NotEqual, "!=", "\\neq ", start_loc);
                    }
                    Some('/') => {
                        self.advance(2);
                        return self.sym(TokenType::FracDefiner, "//", start_loc);
                    }
                    _ => {
                        self.advance(1);
                        return self.sym(TokenType::Slash, "/", start_loc);
                    }
                },

                Some('$') => return self.lex_dollar(start_loc),

                Some('.') => match (self.peek1_char(), self.peek2_char()) {
                    (Some('.'), Some('.')) => {
                        self.advance(3);
                        return self.sym_math(TokenType::CenterDots, "...", "\\cdots ", start_loc);
                    }
                    (Some(c), _) if c.is_ascii_digit() => {
                        self.advance(1);
                        return self.lex_float(start_idx, start_loc);
                    }
                    _ => {
                        self.advance(1);
                        return self.sym(TokenType::Period, ".", start_loc);
                    }
                },

                Some('|') => match (self.peek1_char(), self.peek2_char()) {
                    (Some('|'), _) => {
                        self.advance(2);
                        return self.sym_math(TokenType::Norm, "||", "\\|", start_loc);
                    }
                    (Some('-'), Some('>')) => {
                        self.advance(3);
                        return self.sym_math(TokenType::MapsTo, "|->", "\\mapsto ", start_loc);
                    }
                    _ => {
                        self.advance(1);
                        return self.sym(TokenType::Vert, "|", start_loc);
                    }
                },

                Some('=') => match (self.peek1_char(), self.peek2_char()) {
                    (Some('='), Some('>')) => {
                        self.advance(3);
                        return self.sym_math(
                            TokenType::LongDoubleRightArrow,
                            "==>",
                            "\\Longrightarrow ",
                            start_loc,
                        );
                    }
                    (Some('='), _) => {
                        self.advance(2);
                        return self.sym(TokenType::EqEq, "==", start_loc);
                    }
                    (Some('>'), _) => {
                        self.advance(2);
                        return self.sym_math(
                            TokenType::DoubleRightArrow,
                            "=>",
                            "\\Rightarrow ",
                            start_loc,
                        );
                    }
                    _ => {
                        self.advance(1);
                        return self.sym(TokenType::Equal, "=", start_loc);
                    }
                },

                Some('>') => match self.peek1_char() {
                    Some('=') => {
                        self.advance(2);
                        return self.sym_math(TokenType::GreatEq, ">=", "\\geq ", start_loc);
                    }
                    Some('}') => {
                        self.advance(2);
                        return self.sym_math(TokenType::Rangle, ">}", "\\rangle ", start_loc);
                    }
                    _ => {
                        self.advance(1);
                        return self.sym(TokenType::Great, ">", start_loc);
                    }
                },

                Some('{') => {
                    if self.peek1_char() == Some('<') {
                        self.advance(2);
                        return self.sym_math(TokenType::Langle, "{<", "\\langle ", start_loc);
                    }
                    self.advance(1);
                    return self.sym(TokenType::Lbrace, "{", start_loc);
                }

                Some('\\') => {
                    self.advance(1);
                    return self.lex_backslash(start_idx, start_loc);
                }

                Some('#') => {
                    self.advance(1);
                    return self.lex_sharp(start_idx, start_loc);
                }

                Some('<') => {
                    self.advance(1);
                    return self.lex_less(start_loc);
                }

                Some(':') => {
                    if self.peek1_char() == Some(':') && self.peek2_char() == Some('#') {
                        self.advance(3);
                        return self.slice_tok(TokenType::LuaCodeEnd, start_idx, start_loc);
                    }
                    self.advance(1);
                    return self.sym(TokenType::Colon, ":", start_loc);
                }

                Some('@') => {
                    if self.make_at_letter {
                        self.advance(1);
                        return self.lex_text(start_idx, start_loc);
                    }
                    self.advance(1);
                    return self.sym(TokenType::At, "@", start_loc);
                }

                // Single-character tokens.
                Some('\n') => {
                    self.advance(1);
                    return self.sym(TokenType::Newline, "\n", start_loc);
                }
                Some('\t') => {
                    self.advance(1);
                    return self.sym(TokenType::Tab, "\t", start_loc);
                }
                Some(' ') => {
                    self.advance(1);
                    return self.sym(TokenType::Space, " ", start_loc);
                }
                Some('+') => {
                    self.advance(1);
                    return self.sym(TokenType::Plus, "+", start_loc);
                }
                Some('*') => {
                    self.advance(1);
                    return self.sym(TokenType::Star, "*", start_loc);
                }
                Some('?') => {
                    self.advance(1);
                    return self.sym(TokenType::Question, "?", start_loc);
                }
                Some('_') => {
                    self.advance(1);
                    return self.sym(TokenType::Subscript, "_", start_loc);
                }
                Some('^') => {
                    self.advance(1);
                    return self.sym(TokenType::Superscript, "^", start_loc);
                }
                Some('&') => {
                    self.advance(1);
                    return self.sym(TokenType::Ampersand, "&", start_loc);
                }
                Some(',') => {
                    self.advance(1);
                    return self.sym(TokenType::Comma, ",", start_loc);
                }
                Some(';') => {
                    self.advance(1);
                    return self.sym(TokenType::Semicolon, ";", start_loc);
                }
                Some('~') => {
                    self.advance(1);
                    return self.sym(TokenType::Tilde, "~", start_loc);
                }
                Some('`') => {
                    self.advance(1);
                    return self.sym(TokenType::LeftQuote, "`", start_loc);
                }
                Some('\'') => {
                    self.advance(1);
                    return self.sym(TokenType::RightQuote, "'", start_loc);
                }
                Some('"') => {
                    self.advance(1);
                    return self.sym(TokenType::DoubleQuote, "\"", start_loc);
                }
                Some('}') => {
                    self.advance(1);
                    return self.sym(TokenType::Rbrace, "}", start_loc);
                }
                Some('[') => {
                    self.advance(1);
                    return self.sym(TokenType::Lsqbrace, "[", start_loc);
                }
                Some(']') => {
                    self.advance(1);
                    return self.sym(TokenType::Rsqbrace, "]", start_loc);
                }
                Some('(') => {
                    self.advance(1);
                    return self.sym(TokenType::Lparen, "(", start_loc);
                }
                Some(')') => {
                    self.advance(1);
                    return self.sym(TokenType::Rparen, ")", start_loc);
                }

                // Numbers, words, and lone "other" characters.
                Some(c) if c.is_ascii_digit() => {
                    self.advance(1);
                    return self.lex_integer(start_idx, start_loc);
                }
                Some(c) if c.is_alphanumeric() => {
                    self.advance(1);
                    return self.lex_text(start_idx, start_loc);
                }
                Some(_) => {
                    self.advance(1);
                    return self.slice_tok(TokenType::OtherChar, start_idx, start_loc);
                }
            }
        }
    }

    /// Entered after the leading `o` has been consumed.
    fn lex_o(&mut self, start_idx: usize, start_loc: Location) -> Token<'s> {
        let next_is_alpha = self.peek1_char().is_some_and(|c| c.is_alphabetic());
        if self.cur_char() == Some('o') && !next_is_alpha {
            self.advance(1);
            self.sym_math(TokenType::InfinitySym, "oo", "\\infty ", start_loc)
        } else {
            self.lex_text(start_idx, start_loc)
        }
    }

    /// Entered after the leading `%` has been consumed.
    fn lex_percent(&mut self, start_loc: Location) -> Token<'s> {
        match self.cur_char() {
            // `%# ... <newline>`  -> raw latex for the rest of the line.
            Some('#') => {
                self.advance(1);
                let lit_start = self.cur_idx();
                self.lex_line_verbatim(lit_start, start_loc)
            }
            // `%- ... -%`  -> raw latex block.
            Some('-') => {
                self.advance(1);
                let lit_start = self.cur_idx();
                self.lex_verbatim(lit_start, start_loc)
            }
            // `%!`  -> a literal latex comment marker (the `!` is consumed).
            Some('!') => {
                self.advance(1);
                self.sym(TokenType::LatexComment, "%", start_loc)
            }
            // Bare `%`  -> latex comment marker (nothing else consumed).
            _ => self.sym(TokenType::LatexComment, "%", start_loc),
        }
    }

    /// Raw latex running until a closing `-%`. `lit_start` points just past the
    /// opening `%-`; the span still begins at the `%`.
    fn lex_verbatim(&mut self, lit_start: usize, start_loc: Location) -> Token<'s> {
        loop {
            if self.cur_char() == Some('-') && self.peek1_char() == Some('%') {
                let tok = self.slice_tok(TokenType::RawLatex, lit_start, start_loc);
                self.advance(2);
                return tok;
            }
            if Self::is_eof(self.cur_char()) {
                let tok = self.slice_tok(TokenType::Illegal, lit_start, start_loc);
                self.advance(1);
                return tok;
            }
            self.advance(1);
        }
    }

    /// Raw latex running to end of line. The trailing newline is included in the
    /// literal
    fn lex_line_verbatim(&mut self, lit_start: usize, start_loc: Location) -> Token<'s> {
        loop {
            match self.cur_char() {
                Some('\n') => {
                    self.advance(1);
                    return self.slice_tok(TokenType::RawLatex, lit_start, start_loc);
                }
                c if Self::is_eof(c) => {
                    let tok = self.slice_tok(TokenType::Illegal, lit_start, start_loc);
                    self.advance(1);
                    return tok;
                }
                _ => self.advance(1),
            }
        }
    }

    /// Collect an identifier / keyword. `start_idx` marks the first character.
    fn lex_text(&mut self, start_idx: usize, start_loc: Location) -> Token<'s> {
        while let Some(c) = self.cur_char() {
            if c.is_ascii_digit()
                || token::is_vesti_ident_char(c, self.make_at_letter, self.is_latex3_on)
            {
                self.advance(1);
            } else {
                break;
            }
        }
        let lit = &self.source[start_idx..self.cur_idx()];
        let toktype: TokenType<'s> = token::lookup_keyword(lit).unwrap_or(TokenType::Text);
        Token::new(
            toktype,
            Cow::Borrowed(lit),
            Cow::Borrowed(lit),
            self.span_to_now(start_loc),
        )
    }

    /// Entered after the first digit (or sign) has been consumed.
    fn lex_integer(&mut self, start_idx: usize, start_loc: Location) -> Token<'s> {
        loop {
            match self.cur_char() {
                Some(c) if c.is_ascii_digit() => self.advance(1),
                // A trailing ascii letter turns the number into text.
                Some(c) if c.is_ascii_alphanumeric() => {
                    self.advance(1);
                    return self.lex_text(start_idx, start_loc);
                }
                Some('.') => {
                    self.advance(1);
                    return self.lex_float(start_idx, start_loc);
                }
                _ => return self.slice_tok(TokenType::Integer, start_idx, start_loc),
            }
        }
    }

    fn lex_float(&mut self, start_idx: usize, start_loc: Location) -> Token<'s> {
        while self.cur_char().is_some_and(|c| c.is_ascii_digit()) {
            self.advance(1);
        }
        self.slice_tok(TokenType::Float, start_idx, start_loc)
    }

    /// Entered after the leading `#` has been consumed (`start_idx` at the `#`).
    fn lex_sharp(&mut self, start_idx: usize, start_loc: Location) -> Token<'s> {
        // `#::` opens a lua-code block.
        if self.cur_char() == Some(':') && self.peek1_char() == Some(':') {
            self.advance(2);
            return self.slice_tok(TokenType::LuaCodeStart, start_idx, start_loc);
        }
        match self.cur_char() {
            Some(c) if c.is_ascii_digit() || c.is_alphabetic() => {
                self.advance(1);
                self.lex_builtin(start_idx, start_loc)
            }
            // `#!` -> raw `#` (the `!` is consumed but not part of the literal).
            Some('!') => {
                self.advance(1);
                self.sym(TokenType::RawSharp, "#", start_loc)
            }
            _ => self.sym(TokenType::RawSharp, "#", start_loc),
        }
    }

    /// Entered after `#` and the first name character were consumed.
    fn lex_builtin(&mut self, start_idx: usize, start_loc: Location) -> Token<'s> {
        while self
            .cur_char()
            .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            self.advance(1);
        }

        let name_end = self.cur_idx();
        let fnt_name = &self.source[start_idx..name_end]; // includes leading '#'
        let end_location = self.current_loc; // span end is *before* any trailing space

        // Optionally absorb a single separating space when more content follows.
        if self.cur_char() == Some(' ')
            && self
                .peek1_char()
                .is_some_and(|c| c.is_ascii_alphanumeric() || c == ' ')
        {
            self.advance(1);
        }

        let in_text = &self.source[start_idx..self.cur_idx()]; // may include that space
        let name = &fnt_name[1..]; // strip the '#'
        Token::new(
            TokenType::BuiltinFunction(name),
            Cow::Borrowed(in_text),
            Cow::Borrowed(in_text),
            Span {
                start: start_loc,
                end: end_location,
            },
        )
    }

    /// Entered after the leading `\` has been consumed (`start_idx` at the `\`).
    fn lex_backslash(&mut self, start_idx: usize, start_loc: Location) -> Token<'s> {
        match self.cur_char() {
            Some('\\') => {
                self.advance(1);
                self.sym(TokenType::BackSlash, "\\\\", start_loc)
            }
            Some('#') => {
                self.advance(1);
                self.sym(TokenType::TextSharp, "\\#", start_loc)
            }
            Some('$') => {
                self.advance(1);
                self.sym(TokenType::TextDollar, "\\$", start_loc)
            }
            Some('%') => {
                self.advance(1);
                self.sym(TokenType::TextPercent, "\\%", start_loc)
            }
            Some('[') => {
                self.advance(1);
                self.sym(TokenType::DisplayMathStart, "\\[", start_loc)
            }
            Some(']') => {
                self.advance(1);
                self.sym(TokenType::DisplayMathEnd, "\\]", start_loc)
            }
            Some('{') => {
                self.advance(1);
                self.sym(TokenType::MathLbrace, "\\{", start_loc)
            }
            Some('}') => {
                self.advance(1);
                self.sym(TokenType::MathRbrace, "\\}", start_loc)
            }
            Some(',') => {
                self.advance(1);
                self.sym(TokenType::MathSmallSpace, "\\,", start_loc)
            }
            Some(';') => {
                self.advance(1);
                self.sym(TokenType::MathLargeSpace, "\\;", start_loc)
            }
            Some(' ') => {
                self.advance(1);
                self.sym_math(TokenType::MathLargeSpace, "\\ ", "\\;", start_loc)
            }
            Some(c) if token::is_vesti_ident_char(c, self.make_at_letter, self.is_latex3_on) => {
                self.advance(1);
                self.lex_latex_function(start_idx, start_loc)
            }
            // Bare `\` (current char not consumed).
            _ => self.sym(TokenType::ShortBackSlash, "\\", start_loc),
        }
    }

    /// Entered after `\` and the first name character were consumed.
    fn lex_latex_function(&mut self, start_idx: usize, start_loc: Location) -> Token<'s> {
        while self
            .cur_char()
            .is_some_and(|c| token::is_vesti_ident_char(c, self.make_at_letter, self.is_latex3_on))
        {
            self.advance(1);
        }
        let toktype = if self.make_at_letter {
            TokenType::MakeAtLetterFnt
        } else if self.is_latex3_on {
            TokenType::Latex3Fnt
        } else {
            TokenType::LatexFunction
        };
        self.slice_tok(toktype, start_idx, start_loc)
    }

    /// Entered after the leading `<` has been consumed.
    fn lex_less(&mut self, start_loc: Location) -> Token<'s> {
        match self.cur_char() {
            Some('=') => match (self.peek1_char(), self.peek2_char()) {
                (Some('='), Some('>')) => {
                    self.advance(3);
                    self.sym_math(
                        TokenType::LongDoubleLeftRightArrow,
                        "<==>",
                        "\\Longleftrightarrow ",
                        start_loc,
                    )
                }
                (Some('='), _) => {
                    self.advance(2);
                    self.sym_math(
                        TokenType::LongDoubleLeftArrow,
                        "<==",
                        "\\Longleftarrow ",
                        start_loc,
                    )
                }
                (Some('>'), _) => {
                    self.advance(2);
                    self.sym_math(
                        TokenType::DoubleLeftRightArrow,
                        "<=>",
                        "\\Leftrightarrow ",
                        start_loc,
                    )
                }
                _ => {
                    self.advance(1);
                    self.sym_math(TokenType::LessEq, "<=", "\\leq ", start_loc)
                }
            },
            Some('-') => match (self.peek1_char(), self.peek2_char()) {
                (Some('-'), Some('>')) => {
                    self.advance(3);
                    self.sym_math(
                        TokenType::LongLeftRightArrow,
                        "<-->",
                        "\\longleftrightarrow ",
                        start_loc,
                    )
                }
                (Some('-'), _) => {
                    self.advance(2);
                    self.sym_math(
                        TokenType::LongLeftArrow,
                        "<--",
                        "\\longleftarrow ",
                        start_loc,
                    )
                }
                (Some('>'), _) => {
                    self.advance(2);
                    self.sym_math(
                        TokenType::LeftRightArrow,
                        "<->",
                        "\\leftrightarrow ",
                        start_loc,
                    )
                }
                _ => {
                    self.advance(1);
                    self.sym_math(TokenType::LeftArrow, "<-", "\\leftarrow ", start_loc)
                }
            },
            _ => self.sym(TokenType::Less, "<", start_loc),
        }
    }

    /// Dispatch for `$` (the `$` itself has not yet been consumed).
    fn lex_dollar(&mut self, start_loc: Location) -> Token<'s> {
        match self.peek1_char() {
            Some('#') => {
                // `$#name` is `$` followed by a separate `#name`; bare `$#` is raw.
                if self
                    .peek2_char()
                    .is_some_and(|c| c.is_ascii_digit() || c.is_alphabetic())
                {
                    self.advance(1);
                    self.sym(TokenType::InlineMathSwitch, "$", start_loc)
                } else {
                    self.advance(2);
                    self.sym(TokenType::RawDollar, "$", start_loc)
                }
            }
            Some('$') => {
                self.advance(2);
                self.sym(TokenType::DisplayMathSwitch, "$$", start_loc)
            }
            _ => {
                self.advance(1);
                self.sym(TokenType::InlineMathSwitch, "$", start_loc)
            }
        }
    }

    /// Entered after a `--`. Returns `None` when the comment is fully skipped
    /// (the caller should resume lexing) and `Some(_)` only for a malformed
    /// multiline opener, which yields an `Illegal` token.
    fn skip_comment(&mut self, start_idx: usize, start_loc: Location) -> Option<Token<'s>> {
        loop {
            match self.cur_char() {
                c if Self::is_eof(c) || c == Some('\n') => {
                    self.advance(1);
                    return None;
                }
                Some('[') => {
                    self.advance(1);
                    self.comment_open_eq_count = 0;
                    self.comment_closed_eq_count = 0;
                    return self.multiline_comment_start(start_idx, start_loc);
                }
                _ => self.advance(1),
            }
        }
    }

    fn multiline_comment_start(
        &mut self,
        start_idx: usize,
        start_loc: Location,
    ) -> Option<Token<'s>> {
        loop {
            match self.cur_char() {
                Some('=') => {
                    self.advance(1);
                    self.comment_open_eq_count += 1;
                }
                Some('[') => {
                    self.advance(1);
                    return self.multiline_comment_body(start_loc);
                }
                _ => {
                    let tok = self.slice_tok(TokenType::Illegal, start_idx, start_loc);
                    self.advance(1);
                    return Some(tok);
                }
            }
        }
    }

    fn multiline_comment_body(&mut self, start_loc: Location) -> Option<Token<'s>> {
        loop {
            match self.cur_char() {
                Some(']') => {
                    self.advance(1);
                    return self.multiline_comment_end(start_loc);
                }
                c if Self::is_eof(c) => {
                    self.advance(1);
                    return None;
                }
                _ => self.advance(1),
            }
        }
    }

    fn multiline_comment_end(&mut self, start_loc: Location) -> Option<Token<'s>> {
        loop {
            match self.cur_char() {
                Some(']') => {
                    if self.comment_open_eq_count == self.comment_closed_eq_count {
                        self.advance(1);
                        return None;
                    }
                    self.advance(1);
                    return self.multiline_comment_body(start_loc);
                }
                c if Self::is_eof(c) => {
                    self.advance(1);
                    return None;
                }
                Some('=') => {
                    self.advance(1);
                    self.comment_closed_eq_count += 1;
                }
                _ => {
                    self.advance(1);
                    return self.multiline_comment_body(start_loc);
                }
            }
        }
    }
}

impl<'s> Iterator for Lexer<'s> {
    type Item = Token<'s>;

    fn next(&mut self) -> Option<Self::Item> {
        let tok = Lexer::next(self);
        if matches!(tok.toktype(), TokenType::Eof) {
            None
        } else {
            Some(tok)
        }
    }
}

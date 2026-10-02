use crate::diagnostic::{Diagnostic, ParseErrorInfo};
use crate::lexer::token::{Token, TokenType};
use crate::parser::{ParseError, Parser, PreprocessError, Preprocessor};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Which {
    Current,
    Peek,
}

pub(super) trait Expectable<'s> {
    type Error;
    fn next_token(&mut self);
    fn get_tok(&self, which: Which) -> &Token<'s>;
    fn get_error(&mut self) -> Self::Error;
    fn diagnostic(&mut self) -> &mut Diagnostic<'s>;

    #[inline]
    fn curr_toktype(&self) -> TokenType<'s> {
        self.get_tok(Which::Current).toktype()
    }

    #[inline]
    fn peek_toktype(&self) -> TokenType<'s> {
        self.get_tok(Which::Peek).toktype()
    }

    fn expect(&self, which: Which, toktypes: &[TokenType<'_>]) -> bool {
        let tok = match which {
            Which::Current => self.curr_toktype(),
            Which::Peek => self.peek_toktype(),
        };
        toktypes.iter().any(|t| toktype_eq(&tok, t))
    }

    fn expect_remain(&mut self, token: TokenType<'static>) -> Result<(), Self::Error> {
        if !self.expect(Which::Current, &[token]) {
            let span = self.get_tok(Which::Current).span();
            let obtained = self.curr_toktype();
            self.diagnostic().set_parse_error(
                ParseErrorInfo::TokenExpected {
                    expected: token_expected_slice(token),
                    obtained: Some(obtained),
                },
                Some(span),
            );
            return Err(self.get_error());
        }
        Ok(())
    }

    fn expect_eat(&mut self, token: TokenType<'static>) -> Result<Token<'s>, Self::Error> {
        self.expect_remain(token)?;
        let curr = self.get_tok(Which::Current).clone();
        self.next_token();
        Ok(curr)
    }

    fn eat_whitespaces(&mut self, handle_newline: bool) {
        while self.expect(Which::Current, &[TokenType::Space, TokenType::Tab])
            || (handle_newline && self.expect(Which::Current, &[TokenType::Newline]))
        {
            self.next_token();
        }
    }
}

impl<'s> Expectable<'s> for Parser<'s, '_> {
    type Error = ParseError;

    fn next_token(&mut self) {
        if self.tok_idx + 1 < self.tok_list.len() {
            self.tok_idx += 1;
        } else {
            self.parse_finished = true;
        }
    }

    #[inline]
    fn get_tok(&self, which: Which) -> &Token<'s> {
        let idx = match which {
            Which::Current => self.tok_idx,
            Which::Peek => (self.tok_idx + 1).min(self.tok_list.len() - 1),
        };
        &self.tok_list[idx]
    }

    #[inline]
    fn get_error(&mut self) -> Self::Error {
        ParseError::ParseFailed
    }

    #[inline]
    fn diagnostic(&mut self) -> &mut Diagnostic<'s> {
        self.diagnostic
    }
}

impl<'s> Expectable<'s> for Preprocessor<'s, '_> {
    type Error = PreprocessError;

    fn next_token(&mut self) {
        if !self.state.lex_sleep {
            self.curr_tok = std::mem::replace(&mut self.peek_tok, self.lexer.next());
        } else {
            self.state.lex_sleep = false;
        }
    }

    #[inline]
    fn get_tok(&self, which: Which) -> &Token<'s> {
        match which {
            Which::Current => &self.curr_tok,
            Which::Peek => &self.peek_tok,
        }
    }

    #[inline]
    fn get_error(&mut self) -> Self::Error {
        PreprocessError::PreprocessFailed
    }

    #[inline]
    fn diagnostic(&mut self) -> &mut Diagnostic<'s> {
        self.diagnostic
    }
}

pub(super) fn toktype_eq(a: &TokenType<'_>, b: &TokenType<'_>) -> bool {
    match (a, b) {
        (TokenType::BuiltinFunction(_), TokenType::BuiltinFunction(_)) => true,
        (TokenType::Deprecated { .. }, TokenType::Deprecated { .. }) => true,
        _ => a == b,
    }
}

fn token_expected_slice(t: TokenType<'static>) -> &'static [TokenType<'static>] {
    macro_rules! s {
        ($v:expr) => {{
            const ARR: [TokenType<'static>; 1] = [$v];
            &ARR
        }};
    }
    match t {
        TokenType::Lparen => s!(TokenType::Lparen),
        TokenType::Rparen => s!(TokenType::Rparen),
        TokenType::Lbrace => s!(TokenType::Lbrace),
        TokenType::Rbrace => s!(TokenType::Rbrace),
        TokenType::Lsqbrace => s!(TokenType::Lsqbrace),
        TokenType::Rsqbrace => s!(TokenType::Rsqbrace),
        TokenType::Newline => s!(TokenType::Newline),
        TokenType::Comma => s!(TokenType::Comma),
        TokenType::Period => s!(TokenType::Period),
        TokenType::Integer => s!(TokenType::Integer),
        TokenType::Text => s!(TokenType::Text),
        TokenType::Great => s!(TokenType::Great),
        TokenType::Less => s!(TokenType::Less),
        TokenType::Docclass => s!(TokenType::Docclass),
        TokenType::ImportPkg => s!(TokenType::ImportPkg),
        _ => s!(TokenType::Illegal),
    }
}

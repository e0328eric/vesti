use std::borrow::Cow;
use std::fmt::Write as _;
use std::path::Path;

use crate::diagnostic::ParseErrorInfo;
use crate::lexer::token::{Token, TokenType, is_function_param};
use crate::location::Span;

use super::ast::{Arg, ArgNeed, DelimiterKind, MathState, Stmt, UsePackage};
use super::defkind::{DefenvKind, DefunKind};
use super::{
    DefKind, MAX_BEGENV_NUM, ParseError, Parser, Which, env_math_ident, is_name_token,
    static_toktype, tok_in_math, tok_in_text, vesti_name_mangle,
};

const COMMA_RBRACE: &[TokenType<'static>] = &[TokenType::Comma, TokenType::Rbrace];
const COMMA_RSQBRACE: &[TokenType<'static>] = &[TokenType::Comma, TokenType::Rsqbrace];
const RPAREN_RSQBRACE: &[TokenType<'static>] = &[TokenType::Rparen, TokenType::Rsqbrace];

impl<'s, 'd> Parser<'s, 'd> {
    /// Inner loops call this to recurse into a statement (the dispatcher lives
    /// in `mod.rs`).
    pub(super) fn parse_statement_pub(&mut self) -> Result<Stmt<'s>, ParseError> {
        self.parse_statement_entry()
    }

    pub(super) fn parse_docclass(&mut self) -> Result<Stmt<'s>, ParseError> {
        let docclass_span = self.get_tok(Which::Current).span();
        self.expect_eat(TokenType::Docclass)?;
        self.eat_whitespaces(false);

        let name = self.take_name(docclass_span)?;
        self.eat_whitespaces(false);

        let options = match self.curr_toktype() {
            TokenType::Eof | TokenType::Newline => None,
            _ => Some(self.parse_options()?),
        };

        Ok(Stmt::DocumentClass { name, options })
    }

    pub(super) fn parse_single_pkg(&mut self) -> Result<Stmt<'s>, ParseError> {
        let importpkg_span = self.get_tok(Which::Current).span();
        self.expect_eat(TokenType::ImportPkg)?;
        self.eat_whitespaces(false);

        if self.expect(Which::Current, &[TokenType::Lbrace]) {
            return self.parse_multiple_pkgs();
        }

        let name = self.take_name(importpkg_span)?;
        self.eat_whitespaces(false);

        let options = match self.curr_toktype() {
            TokenType::Lparen => Some(self.parse_options()?),
            _ => None,
        };

        Ok(Stmt::ImportSinglePkg(UsePackage { name, options }))
    }

    fn parse_multiple_pkgs(&mut self) -> Result<Stmt<'s>, ParseError> {
        let lbrace_span = self.get_tok(Which::Current).span();
        self.expect_eat(TokenType::Lbrace)?;

        let mut output: Vec<UsePackage<'s>> = Vec::with_capacity(10);

        loop {
            self.eat_whitespaces(true);
            if self.expect(Which::Current, &[TokenType::Rbrace]) {
                break;
            }

            let name = self.take_name(lbrace_span)?;
            self.eat_whitespaces(false);

            let open_paren_loc = self.get_tok(Which::Current).span();
            let options = match self.curr_toktype() {
                TokenType::Lparen => {
                    let tmp = self.parse_options()?;
                    self.next_token();
                    Some(tmp)
                }
                _ => None,
            };
            self.eat_whitespaces(true);

            match self.curr_toktype() {
                TokenType::Comma | TokenType::Rbrace => {
                    output.push(UsePackage { name, options });
                    if self.expect(Which::Current, &[TokenType::Rbrace]) {
                        break;
                    } else {
                        self.next_token();
                        continue;
                    }
                }
                TokenType::Eof => {
                    self.diagnostic
                        .set_parse_error(ParseErrorInfo::EofErr, Some(open_paren_loc));
                    return Err(ParseError::ParseFailed);
                }
                _ => {
                    let span = self.get_tok(Which::Current).span();
                    let obtained = self.curr_toktype();
                    self.diagnostic.set_parse_error(
                        ParseErrorInfo::TokenExpected {
                            expected: COMMA_RBRACE,
                            obtained: Some(obtained),
                        },
                        Some(span),
                    );
                    return Err(ParseError::ParseFailed);
                }
            }
        }

        if !self.expect(Which::Current, &[TokenType::Rbrace]) {
            let span = self.get_tok(Which::Current).span();
            self.diagnostic.set_parse_error(
                ParseErrorInfo::VestiInternal("`parseMultiplePkgs` implementation bug occurs"),
                Some(span),
            );
            return Err(ParseError::ParseFailed);
        }

        Ok(Stmt::ImportMultiplePkgs(output))
    }

    pub(super) fn parse_options(&mut self) -> Result<Vec<Cow<'s, str>>, ParseError> {
        let open_paren_span = self.get_tok(Which::Current).span();
        self.expect_eat(TokenType::Lparen)?;

        let mut output: Vec<Cow<'s, str>> = Vec::with_capacity(10);
        let mut tmp: Cow<'s, str> = Cow::Borrowed("");
        let mut tmp_has = false;

        loop {
            match self.curr_toktype() {
                TokenType::Rparen => break,
                TokenType::Eof => {
                    self.diagnostic
                        .set_parse_error(ParseErrorInfo::EofErr, Some(open_paren_span));
                    return Err(ParseError::ParseFailed);
                }
                TokenType::Comma => {
                    if tmp_has {
                        output.push(std::mem::replace(&mut tmp, Cow::Borrowed("")));
                        tmp_has = false;
                    }
                }
                TokenType::Space | TokenType::Tab | TokenType::Newline => {}
                _ => {
                    let piece = tok_in_text(self.get_tok(Which::Current));
                    cow_append(&mut tmp, piece);
                    tmp_has = true;
                }
            }
            self.next_token();
        }

        if tmp_has {
            output.push(tmp);
        }

        Ok(output)
    }

    /// Collect a (possibly multi-token) name
    pub(super) fn take_name(&mut self, span: Span) -> Result<Cow<'s, str>, ParseError> {
        if self.expect(Which::Current, &[TokenType::Eof]) {
            self.diagnostic
                .set_parse_error(ParseErrorInfo::EofErr, Some(span));
            return Err(ParseError::ParseFailed);
        }

        let mut output: Cow<'s, str> = match self.curr_toktype() {
            TokenType::Text | TokenType::Minus | TokenType::Integer => {
                Cow::Owned(tok_in_text(self.get_tok(Which::Current)).to_owned())
            }
            _ => {
                return Ok(Cow::Borrowed(tok_in_text(self.get_tok(Which::Current))));
            }
        };
        self.next_token();

        while self.expect(
            Which::Current,
            &[TokenType::Text, TokenType::Minus, TokenType::Integer],
        ) {
            let piece = tok_in_text(self.get_tok(Which::Current));
            cow_append(&mut output, piece);
            self.next_token();
        }

        Ok(output)
    }

    pub(super) fn parse_math_stmt(&mut self) -> Result<Stmt<'s>, ParseError> {
        match self.curr_toktype() {
            TokenType::InlineMathSwitch => self.parse_math_stmt_inner(TokenType::InlineMathSwitch),
            TokenType::DisplayMathSwitch => {
                self.parse_math_stmt_inner(TokenType::DisplayMathSwitch)
            }
            TokenType::DisplayMathStart => self.parse_math_stmt_inner(TokenType::DisplayMathStart),
            _ => unreachable!("parse_math_stmt called on non-math token"),
        }
    }

    fn parse_math_stmt_inner(
        &mut self,
        open_tok: TokenType<'static>,
    ) -> Result<Stmt<'s>, ParseError> {
        let (close_tok, state) = match open_tok {
            TokenType::InlineMathSwitch => (TokenType::InlineMathSwitch, MathState::Inline),
            TokenType::DisplayMathSwitch => (TokenType::DisplayMathSwitch, MathState::Display),
            TokenType::DisplayMathStart => (TokenType::DisplayMathEnd, MathState::Display),
            _ => unreachable!("invalid open_tok"),
        };

        let mut ctx: Vec<Stmt<'s>> = Vec::with_capacity(20);
        let open_tok_span = self.get_tok(Which::Current).span();
        self.expect_eat(open_tok)?;

        loop {
            let t = self.curr_toktype();
            if super::toktype_eq(&t, &close_tok) {
                break;
            }
            if matches!(t, TokenType::Eof) {
                self.diagnostic
                    .set_parse_error(ParseErrorInfo::EofErr, Some(open_tok_span));
                return Err(ParseError::ParseFailed);
            }
            let stmt = self.parse_statement_pub()?;
            ctx.push(stmt);
            self.next_token();
        }

        self.expect_remain(close_tok)?;
        self.doc_state.math_mode = false;

        Ok(Stmt::MathCtx {
            state,
            inner: ctx,
            label: None,
        })
    }

    pub(super) fn parse_text_in_math(
        &mut self,
        add_front_space: bool,
    ) -> Result<Stmt<'s>, ParseError> {
        let mut add_back_space = false;
        let mut inner: Vec<Stmt<'s>> = Vec::with_capacity(20);

        let open_text_span = self.get_tok(Which::Current).span();
        if add_front_space {
            self.expect_eat(TokenType::RawSharp)?;
        }
        self.expect_eat(TokenType::DoubleQuote)?;

        self.doc_state.math_mode = false;
        loop {
            match self.curr_toktype() {
                TokenType::DoubleQuote => break,
                TokenType::Eof => {
                    self.diagnostic
                        .set_parse_error(ParseErrorInfo::EofErr, Some(open_text_span));
                    return Err(ParseError::ParseFailed);
                }
                _ => {}
            }
            let stmt = self.parse_statement_pub()?;
            inner.push(stmt);
            self.next_token();
        }
        self.doc_state.math_mode = true;

        if self.expect(Which::Peek, &[TokenType::RawSharp]) {
            self.next_token();
            add_back_space = true;
        }

        Ok(Stmt::PlainTextInMath {
            add_front_space,
            add_back_space,
            inner,
        })
    }

    pub(super) fn parse_open_delimiter(&mut self) -> Result<Stmt<'s>, ParseError> {
        self.expect_eat(TokenType::Question)?;

        if self.expect(
            Which::Current,
            &[
                TokenType::Lparen,
                TokenType::Lsqbrace,
                TokenType::Langle,
                TokenType::MathLbrace,
                TokenType::Vert,
                TokenType::Norm,
                TokenType::Rparen,
                TokenType::Rsqbrace,
                TokenType::Rangle,
                TokenType::MathRbrace,
                TokenType::Period,
            ],
        ) {
            Ok(Stmt::MathDelimiter {
                delimiter: tok_in_math(self.get_tok(Which::Current)),
                kind: DelimiterKind::LeftBig,
            })
        } else {
            Ok(Stmt::MathLit("?"))
        }
    }

    pub(super) fn parse_closed_delimiter(&mut self) -> Result<Stmt<'s>, ParseError> {
        let delimiter = tok_in_math(self.get_tok(Which::Current));

        if self.expect(Which::Peek, &[TokenType::Question]) {
            self.next_token();
            Ok(Stmt::MathDelimiter {
                delimiter,
                kind: DelimiterKind::RightBig,
            })
        } else {
            Ok(Stmt::MathDelimiter {
                delimiter,
                kind: DelimiterKind::None,
            })
        }
    }
}

/// Append into a `Cow`, promoting to owned as needed.
pub(super) fn cow_append<'s>(c: &mut Cow<'s, str>, s: &str) {
    if s.is_empty() {
        return;
    }
    match c {
        Cow::Borrowed(b) if b.is_empty() => *c = Cow::Owned(s.to_owned()),
        Cow::Borrowed(b) => {
            let mut owned = String::with_capacity(b.len() + s.len());
            owned.push_str(b);
            owned.push_str(s);
            *c = Cow::Owned(owned);
        }
        Cow::Owned(o) => o.push_str(s),
    }
}

impl<'s, 'd> Parser<'s, 'd> {
    pub(super) fn parse_brace(&mut self, frac_enable: bool) -> Result<Stmt<'s>, ParseError> {
        let begin_location = self.get_tok(Which::Current).span();
        self.expect_eat(TokenType::Lbrace)?;

        let mut is_fraction = false;
        let mut numerator: Vec<Stmt<'s>> = Vec::with_capacity(10);
        let mut denominator: Vec<Stmt<'s>> = Vec::new();

        loop {
            match self.curr_toktype() {
                TokenType::Rbrace => break,
                TokenType::Eof => {
                    self.diagnostic
                        .set_parse_error(ParseErrorInfo::EofErr, Some(begin_location));
                    return Err(ParseError::ParseFailed);
                }
                _ => {}
            }

            if frac_enable
                && self.expect(Which::Current, &[TokenType::FracDefiner])
                && self.doc_state.math_mode
            {
                is_fraction = true;
                self.next_token();
                continue;
            }

            let stmt = self.parse_statement_pub()?;
            if frac_enable && is_fraction {
                denominator.push(stmt);
            } else {
                numerator.push(stmt);
            }
            self.next_token();
        }

        if frac_enable && is_fraction {
            Ok(Stmt::Fraction {
                numerator,
                denominator,
            })
        } else {
            Ok(Stmt::Braced {
                unwrap_brace: false,
                inner: numerator,
            })
        }
    }

    fn push_endenv_stack(
        &mut self,
        begenv_name: &'s str,
        begenv_location: Span,
    ) -> Result<(), ParseError> {
        if self.endenv_stack.len() >= MAX_BEGENV_NUM {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::TooManyBegenv(MAX_BEGENV_NUM as u8),
                Some(begenv_location),
            );
            return Err(ParseError::ParseFailed);
        }
        self.endenv_stack.push(begenv_name);
        Ok(())
    }

    fn pop_endenv_stack(&mut self, endenv_location: Span) -> Result<&'s str, ParseError> {
        match self.endenv_stack.pop() {
            Some(name) => Ok(name),
            None => {
                self.diagnostic
                    .set_parse_error(ParseErrorInfo::BegenvUnderflow, Some(endenv_location));
                Err(ParseError::ParseFailed)
            }
        }
    }

    pub(super) fn parse_environment<const IS_REAL: bool>(
        &mut self,
    ) -> Result<Stmt<'s>, ParseError> {
        let begenv_location = self.get_tok(Which::Current).span();
        let begin_env_tok = if IS_REAL {
            TokenType::Useenv
        } else {
            TokenType::Begenv
        };

        let mut off_math_state = false;
        let mut add_newline = false;
        let mut push_name = true;

        self.expect_eat(begin_env_tok)?;
        if !IS_REAL && self.expect(Which::Current, &[TokenType::Bang]) {
            self.next_token();
            push_name = false;
        }
        if !IS_REAL && self.expect(Which::Current, &[TokenType::Star]) {
            self.next_token();
            add_newline = true;
        }
        self.eat_whitespaces(false);

        let name_src: &'s str = {
            let tt = self.curr_toktype();
            if is_name_token(&tt) {
                tok_in_text(self.get_tok(Which::Current))
            } else if matches!(tt, TokenType::Eof) {
                if IS_REAL {
                    self.diagnostic.set_parse_error(
                        ParseErrorInfo::NameMissErr(TokenType::Useenv),
                        Some(begenv_location),
                    );
                } else {
                    self.diagnostic
                        .set_parse_error(ParseErrorInfo::EofErr, Some(begenv_location));
                }
                return Err(ParseError::ParseFailed);
            } else {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::NameMissErr(static_toktype(begin_env_tok)),
                    Some(begenv_location),
                );
                return Err(ParseError::ParseFailed);
            }
        };

        if name_src == "picture" {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::IllegalUseErr(
                    "`picture` environment is illegal in vesti. Use #picture instead.",
                ),
                Some(begenv_location),
            );
            return Err(ParseError::ParseFailed);
        }

        if env_math_ident(name_src) {
            self.doc_state.math_mode = true;
            off_math_state = true;
        }

        let mut name: Cow<'s, str> = Cow::Borrowed(name_src);

        if IS_REAL {
            self.next_token(); // eat name
            while self.expect(Which::Current, &[TokenType::Star]) {
                cow_append(&mut name, "*");
                self.next_token();
            }
            self.eat_whitespaces(false);
        } else {
            if self.expect(Which::Peek, &[TokenType::Star]) {
                while self.expect(Which::Peek, &[TokenType::Star]) {
                    cow_append(&mut name, "*");
                    self.next_token();
                }
                while self.expect(Which::Peek, &[TokenType::Space, TokenType::Tab]) {
                    self.next_token();
                }
            }
            if self.expect(Which::Peek, &[TokenType::Space, TokenType::Tab]) {
                while self.expect(Which::Peek, &[TokenType::Space, TokenType::Tab]) {
                    self.next_token();
                }
                if self.expect(Which::Peek, &[TokenType::Lparen, TokenType::Lsqbrace]) {
                    self.next_token();
                }
            } else if self.expect(Which::Peek, &[TokenType::Lparen, TokenType::Lsqbrace]) {
                self.next_token();
            }
        }

        if !IS_REAL && push_name {
            self.push_endenv_stack(name_src, begenv_location)?;
        }

        let args = self.parse_function_args(
            TokenType::Lparen,
            TokenType::Rparen,
            TokenType::Lsqbrace,
            TokenType::Rsqbrace,
            !IS_REAL,
        )?;

        if !IS_REAL {
            if off_math_state {
                self.doc_state.math_mode = false;
            }
            return Ok(Stmt::BeginPhantomEnviron {
                name,
                args,
                add_newline,
            });
        }

        if !args.is_empty() {
            if !self.expect(Which::Current, &[TokenType::Rparen])
                && !self.expect(Which::Current, &[TokenType::Rsqbrace])
            {
                let span = self.get_tok(Which::Current).span();
                let obtained = self.curr_toktype();
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::TokenExpected {
                        expected: RPAREN_RSQBRACE,
                        obtained: Some(obtained),
                    },
                    Some(span),
                );
                return Err(ParseError::ParseFailed);
            }
            self.next_token();
        }
        self.eat_whitespaces(true);

        self.expect_remain(TokenType::Lbrace)?;
        let inner = self.parse_brace(false)?;

        if off_math_state {
            self.doc_state.math_mode = false;
        }

        let inner_vec = match inner {
            Stmt::Braced { inner, .. } => inner,
            _ => unreachable!("parse_brace must return Braced"),
        };

        Ok(Stmt::Environment {
            name,
            args,
            inner: inner_vec,
            label: None,
        })
    }

    pub(super) fn parse_end_phantom_environment(&mut self) -> Result<Stmt<'s>, ParseError> {
        let endenv_location = self.get_tok(Which::Current).span();
        self.expect_remain(TokenType::Endenv)?;
        if matches!(self.peek_toktype(), TokenType::Bang) {
            self.next_token(); // eat `endenv`
            self.next_token(); // eat `!`
            self.eat_whitespaces(false);

            let tt = self.curr_toktype();
            let name: &'s str = if is_name_token(&tt) {
                tok_in_text(self.get_tok(Which::Current))
            } else if matches!(tt, TokenType::Eof) {
                self.diagnostic
                    .set_parse_error(ParseErrorInfo::EofErr, Some(endenv_location));
                return Err(ParseError::ParseFailed);
            } else {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::NameMissErr(TokenType::Endenv),
                    Some(endenv_location),
                );
                return Err(ParseError::ParseFailed);
            };
            Ok(Stmt::EndPhantomEnviron(Cow::Owned(name.to_owned())))
        } else {
            let name = self.pop_endenv_stack(endenv_location)?;
            Ok(Stmt::EndPhantomEnviron(Cow::Borrowed(name)))
        }
    }

    pub(super) fn parse_define_command(
        &mut self,
        kind: DefKind,
        is_xparse: bool,
    ) -> Result<Stmt<'s>, ParseError> {
        let def_toktype = if kind == DefKind::Fnt {
            TokenType::DefineFunction
        } else {
            TokenType::DefineEnv
        };
        let def_location = self.get_tok(Which::Current).span();

        let mut defun_kind = DefunKind::default();
        let mut defenv_kind = DefenvKind::default();

        self.expect_eat(def_toktype)?;
        self.eat_whitespaces(false);

        if self.expect(Which::Current, &[TokenType::Lsqbrace]) {
            let kind_brace_location = self.get_tok(Which::Current).span();
            self.next_token();
            let mut kind_str = String::with_capacity(10);
            while !self.expect(Which::Current, &[TokenType::Rsqbrace, TokenType::Eof]) {
                kind_str.push_str(tok_in_text(self.get_tok(Which::Current)));
                self.next_token();
            }
            if matches!(self.curr_toktype(), TokenType::Eof) {
                self.diagnostic
                    .set_parse_error(ParseErrorInfo::EofErr, Some(kind_brace_location));
                return Err(ParseError::ParseFailed);
            }

            let ok = match kind {
                DefKind::Fnt => defun_kind.parse(&kind_str, is_xparse),
                DefKind::Env => defenv_kind.parse(&kind_str),
            };
            if !ok {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::InvalidDefunKind(kind_str),
                    Some(kind_brace_location),
                );
                return Err(ParseError::ParseFailed);
            }
            self.expect_eat(TokenType::Rsqbrace)?;
        } else if kind == DefKind::Fnt && is_xparse {
            defun_kind.xparse = true;
        }
        self.eat_whitespaces(false);

        if kind == DefKind::Fnt {
            self.doc_state.xparse_defun = true;
        }

        let name: Cow<'s, str> = {
            let tt = self.curr_toktype();
            if is_name_token(&tt) {
                Cow::Owned(tok_in_text(self.get_tok(Which::Current)).to_owned())
            } else if matches!(tt, TokenType::Eof) {
                self.diagnostic
                    .set_parse_error(ParseErrorInfo::EofErr, Some(def_location));
                return Err(ParseError::ParseFailed);
            } else {
                let span = self.get_tok(Which::Current).span();
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::NameMissErr(TokenType::DefineFunction),
                    Some(span),
                );
                return Err(ParseError::ParseFailed);
            }
        };
        self.next_token();
        self.eat_whitespaces(false);

        let mut param_str: Option<Cow<'s, str>> = None;
        if self.expect(Which::Current, &[TokenType::Lparen]) {
            self.next_token(); // eat `(`
            let mut param_toks: Vec<Token<'s>> = Vec::with_capacity(20);
            let mut nested = 1usize;
            loop {
                let cont = match self.curr_toktype() {
                    TokenType::Lparen => {
                        nested += 1;
                        true
                    }
                    TokenType::Rparen => {
                        nested -= 1;
                        nested != 0
                    }
                    TokenType::Eof => {
                        self.diagnostic
                            .set_parse_error(ParseErrorInfo::EofErr, Some(def_location));
                        return Err(ParseError::ParseFailed);
                    }
                    _ => true,
                };
                if !cont {
                    break;
                }
                param_toks.push(self.get_tok(Which::Current).clone());
                self.next_token();
            }
            debug_assert!(self.expect(Which::Current, &[TokenType::Rparen]));
            let s = self.build_define_function_param(&param_toks)?;
            param_str = Some(Cow::Owned(s));
            self.next_token(); // eat `)`
        }
        self.eat_whitespaces(true);

        match kind {
            DefKind::Fnt => {
                self.expect_remain(TokenType::Lbrace)?;
                let inner = self.parse_brace(false)?;
                let inner_vec = match inner {
                    Stmt::Braced { inner, .. } => inner,
                    _ => unreachable!(),
                };
                Ok(Stmt::DefineFunction {
                    name,
                    param_str,
                    kind: defun_kind,
                    inner: inner_vec,
                })
            }
            DefKind::Env => {
                self.expect_remain(TokenType::Lbrace)?;
                let inner_begin = self.parse_brace(false)?;
                let inner_begin_vec = match inner_begin {
                    Stmt::Braced { inner, .. } => inner,
                    _ => unreachable!(),
                };
                self.next_token(); // eat `}`
                self.eat_whitespaces(true);

                self.expect_remain(TokenType::Lbrace)?;
                let inner_end = self.parse_brace(false)?;
                let inner_end_vec = match inner_end {
                    Stmt::Braced { inner, .. } => inner,
                    _ => unreachable!(),
                };
                self.eat_whitespaces(true);

                Ok(Stmt::DefineEnv {
                    name,
                    param_str,
                    kind: defenv_kind,
                    inner_begin: inner_begin_vec,
                    inner_end: inner_end_vec,
                })
            }
        }
    }

    fn build_define_function_param(
        &mut self,
        param_toks: &[Token<'s>],
    ) -> Result<String, ParseError> {
        let mut out = String::new();
        for tok in param_toks {
            match tok.toktype() {
                TokenType::BuiltinFunction(builtin_fnt) => {
                    if let Some(fnt_param) = is_function_param(builtin_fnt) {
                        if fnt_param % 10 == 0 {
                            self.diagnostic.set_parse_error(
                                ParseErrorInfo::InvalidDefunParam(fnt_param),
                                Some(tok.span()),
                            );
                            return Err(ParseError::ParseFailed);
                        }
                        let exp = fnt_param / 10;
                        let num_of_sharp = match 2usize.checked_pow(exp as u32) {
                            Some(v) => v,
                            None => {
                                self.diagnostic.set_parse_error(
                                    ParseErrorInfo::DefunParamOverflow(exp),
                                    Some(tok.span()),
                                );
                                return Err(ParseError::ParseFailed);
                            }
                        };
                        let param = fnt_param % 10;
                        for _ in 0..num_of_sharp {
                            out.push('#');
                        }
                        let _ = write!(out, "{param}");
                    } else {
                        self.diagnostic.set_parse_error(
                            ParseErrorInfo::WrongBuiltin {
                                name: Cow::Owned(builtin_fnt.to_owned()),
                                note: "this is not a valid function parameter",
                            },
                            Some(tok.span()),
                        );
                        return Err(ParseError::ParseFailed);
                    }
                }
                _ => out.push_str(tok_in_text(tok)),
            }
        }
        Ok(out)
    }

    pub(super) fn parse_lua_code(&mut self) -> Result<Stmt<'s>, ParseError> {
        let codeblock_loc = self.get_tok(Which::Current).span();
        self.expect_eat(TokenType::LuaCodeStart)?;

        let mut luacode = String::with_capacity(25);
        while !self.expect(Which::Current, &[TokenType::LuaCodeEnd, TokenType::Eof]) {
            luacode.push_str(tok_in_text(self.get_tok(Which::Current)));
            self.next_token();
        }

        if self.expect(Which::Current, &[TokenType::Eof]) {
            self.diagnostic
                .set_parse_error(ParseErrorInfo::EofErr, Some(codeblock_loc));
            return Err(ParseError::ParseFailed);
        }
        debug_assert!(self.expect(Which::Current, &[TokenType::LuaCodeEnd]));

        let mut is_global = false;
        if self.expect(Which::Peek, &[TokenType::Star]) {
            self.next_token();
            is_global = true;
        }

        let mut code_import: Option<Vec<&'s str>> = None;
        if self.expect(Which::Peek, &[TokenType::Lsqbrace]) {
            let mut imports: Vec<&'s str> = Vec::with_capacity(10);
            self.next_token(); // skip ':lu#'/'*' token
            self.next_token(); // skip '[' token
            loop {
                self.eat_whitespaces(true);
                if self.expect(Which::Current, &[TokenType::Rsqbrace]) {
                    break;
                }
                self.expect_remain(TokenType::Text)?;
                imports.push(tok_in_text(self.get_tok(Which::Current)));
                self.next_token();
                self.eat_whitespaces(true);
                match self.curr_toktype() {
                    TokenType::Comma => continue,
                    TokenType::Rsqbrace => break,
                    _ => {
                        let span = self.get_tok(Which::Current).span();
                        let obtained = self.curr_toktype();
                        self.diagnostic.set_parse_error(
                            ParseErrorInfo::TokenExpected {
                                expected: COMMA_RSQBRACE,
                                obtained: Some(obtained),
                            },
                            Some(span),
                        );
                        return Err(ParseError::ParseFailed);
                    }
                }
            }
            code_import = Some(imports);
        }

        let mut code_export: Option<&'s str> = None;
        if self.expect(Which::Peek, &[TokenType::Less]) {
            self.next_token(); // skip ':lu#'/']' token
            self.next_token(); // skip '<' token
            self.expect_remain(TokenType::Text)?;
            code_export = Some(tok_in_text(self.get_tok(Which::Current)));
            self.next_token();
            self.expect_remain(TokenType::Great)?;
        }

        Ok(Stmt::LuaCode {
            code_span: codeblock_loc,
            is_global,
            code_import,
            code_export,
            code: luacode,
        })
    }

    pub(super) fn parse_import_module(&mut self) -> Result<Stmt<'s>, ParseError> {
        let import_file_loc = self.get_tok(Which::Current).span();
        self.expect_eat(TokenType::ImportModule)?;
        self.eat_whitespaces(false);

        let open_paren_span = self.get_tok(Which::Current).span();
        self.expect_remain(TokenType::Lparen)?;

        let mut mod_dir_path = String::with_capacity(30);
        let mut nested = 1usize;
        loop {
            let peek = self.get_tok(Which::Peek);
            match peek.toktype() {
                TokenType::Lparen => nested += 1,
                TokenType::Rparen => {
                    nested -= 1;
                    if nested == 0 {
                        break;
                    }
                }
                TokenType::Eof => {
                    self.diagnostic
                        .set_parse_error(ParseErrorInfo::EofErr, Some(open_paren_span));
                    return Err(ParseError::ParseFailed);
                }
                _ => mod_dir_path.push_str(tok_in_text(peek)),
            }
            self.next_token();
        }
        self.next_token();

        let trimmed = mod_dir_path
            .trim_matches(|c| c == ' ' || c == '\t')
            .trim_start_matches(['/', '\\'])
            .to_owned();

        if crate::ves_module::download_module(self.diagnostic, &trimmed, Some(import_file_loc))
            .is_err()
        {
            return Err(ParseError::ParseFailed);
        }

        Ok(Stmt::NopStmt)
    }

    pub(super) fn parse_import_vesti(&mut self) -> Result<Stmt<'s>, ParseError> {
        let import_ves_loc = self.get_tok(Which::Current).span();
        self.expect_eat(TokenType::ImportVesti)?;
        self.eat_whitespaces(false);
        self.expect_remain(TokenType::Lparen)?;

        let mut file_path_str = String::with_capacity(30);
        let mut nested = 1usize;
        loop {
            let peek = self.get_tok(Which::Peek);
            match peek.toktype() {
                TokenType::Lparen => nested += 1,
                TokenType::Rparen => {
                    nested -= 1;
                    if nested == 0 {
                        break;
                    }
                }
                TokenType::Eof => {
                    self.diagnostic
                        .set_parse_error(ParseErrorInfo::EofErr, Some(import_ves_loc));
                    return Err(ParseError::ParseFailed);
                }
                _ => file_path_str.push_str(tok_in_text(peek)),
            }
            self.next_token();
        }
        self.next_token();

        // Faithful: canonicalize then name-mangle. If the path cannot be
        // resolved (e.g. the included file is absent in a unit test), fall back
        // to mangling the raw path so the parse still succeeds.
        let real = std::fs::canonicalize(&file_path_str)
            .ok()
            .and_then(|p| p.to_str().map(|s| s.to_owned()))
            .unwrap_or_else(|| file_path_str.clone());
        let filename = vesti_name_mangle(&real);

        Ok(Stmt::ImportVesti(filename))
    }

    pub(super) fn parse_function_args(
        &mut self,
        open: TokenType<'static>,
        closed: TokenType<'static>,
        optional_open: TokenType<'static>,
        optional_closed: TokenType<'static>,
        is_phantom_env: bool,
    ) -> Result<Vec<Arg<'s>>, ParseError> {
        let mut args: Vec<Arg<'s>> = Vec::with_capacity(10);

        let mut first_token = is_phantom_env;
        if self.expect(Which::Current, &[open, optional_open, TokenType::Star]) {
            loop {
                let cur = self.curr_toktype();
                if super::toktype_eq(&cur, &open) {
                    self.parse_function_args_core(&mut args, open, closed, ArgNeed::MainArg)?;
                } else if super::toktype_eq(&cur, &optional_open) {
                    self.parse_function_args_core(
                        &mut args,
                        optional_open,
                        optional_closed,
                        ArgNeed::Optional,
                    )?;
                } else if matches!(cur, TokenType::Star) {
                    if !first_token {
                        args.push(Arg {
                            needed: ArgNeed::StarArg,
                            ctx: Vec::new(),
                        });
                    }
                } else {
                    unreachable!("parse_function_args invariant");
                }

                first_token = false;
                if !self.expect(Which::Peek, &[open, optional_open, TokenType::Star]) {
                    break;
                }
                self.next_token();
            }
        }

        Ok(args)
    }

    fn parse_function_args_core(
        &mut self,
        args: &mut Vec<Arg<'s>>,
        open: TokenType<'static>,
        closed: TokenType<'static>,
        arg_need: ArgNeed,
    ) -> Result<(), ParseError> {
        let open_brace_location = self.get_tok(Which::Current).span();
        self.expect_eat(open)?;

        let mut tmp: Vec<Stmt<'s>> = Vec::with_capacity(20);
        let mut nested = 1usize;
        loop {
            let cur = self.curr_toktype();
            let cont = if super::toktype_eq(&cur, &open) {
                nested += 1;
                true
            } else if super::toktype_eq(&cur, &closed) {
                nested -= 1;
                nested > 0
            } else if matches!(cur, TokenType::Eof) {
                self.diagnostic
                    .set_parse_error(ParseErrorInfo::EofErr, Some(open_brace_location));
                return Err(ParseError::ParseFailed);
            } else {
                true
            };
            if !cont {
                break;
            }
            let stmt = self.parse_statement_pub()?;
            tmp.push(stmt);
            self.next_token();
        }

        self.expect_remain(closed)?;
        args.push(Arg {
            needed: arg_need,
            ctx: tmp,
        });
        Ok(())
    }

    pub(super) fn parse_filepath_helper(
        &mut self,
        left_parn_loc: Span,
    ) -> Result<(String, String), ParseError> {
        debug_assert!(matches!(self.curr_toktype(), TokenType::Lparen));

        let mut file_path_str = String::with_capacity(30);
        let mut inside_config_dir = false;
        let mut parse_very_first_chr = false;
        let mut nested = 1usize;

        loop {
            let peek = self.get_tok(Which::Peek);
            let chr_ty = peek.toktype();
            let chr_str = tok_in_text(peek);

            match chr_ty {
                TokenType::Lparen => nested += 1,
                TokenType::Rparen => {
                    nested -= 1;
                    if nested == 0 {
                        break;
                    }
                }
                TokenType::Tilde if !parse_very_first_chr => match home_path() {
                    Some(home) => file_path_str.push_str(&home),
                    None => {
                        let span = self.get_tok(Which::Current).span();
                        self.diagnostic.set_parse_error(
                            ParseErrorInfo::VestiInternal(
                                "Cannot find home. Check `HOME` env is defined on linux and macos, or `USERPROFILE` on windows",
                            ),
                            Some(span),
                        );
                        return Err(ParseError::ParseFailed);
                    }
                },
                TokenType::At if !parse_very_first_chr => {
                    inside_config_dir = true;
                    self.next_token();
                    if !matches!(self.peek_toktype(), TokenType::Slash) {
                        self.diagnostic.set_parse_error(
                            ParseErrorInfo::IllegalUseErr("The next token for `@` should be `/`"),
                            Some(left_parn_loc),
                        );
                        return Err(ParseError::ParseFailed);
                    }
                    continue;
                }
                TokenType::Eof => {
                    self.diagnostic.set_parse_error(
                        ParseErrorInfo::IsNotClosed {
                            open: LPAREN_SLICE,
                            close: TokenType::Rparen,
                        },
                        Some(left_parn_loc),
                    );
                    return Err(ParseError::ParseFailed);
                }
                _ => file_path_str.push_str(chr_str),
            }
            parse_very_first_chr = true;
            self.next_token();
        }
        self.next_token();

        let trimmed = file_path_str
            .trim_matches(|c| c == ' ' || c == '\t')
            .to_owned();
        let final_path = if inside_config_dir {
            let config = config_path();
            format!("{config}/{trimmed}")
        } else if Path::new(&trimmed).is_absolute() {
            trimmed
        } else {
            format!("./{trimmed}")
        };

        let basename = Path::new(&final_path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_owned();

        Ok((final_path, basename))
    }
}

const LPAREN_SLICE: &[TokenType<'static>] = &[TokenType::Lparen];

fn home_path() -> Option<String> {
    #[cfg(windows)]
    {
        std::env::var("USERPROFILE").ok()
    }
    #[cfg(not(windows))]
    {
        std::env::var("HOME").ok()
    }
}

fn config_path() -> String {
    #[cfg(windows)]
    let base = std::env::var("APPDATA").ok();
    #[cfg(not(windows))]
    let base = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .or_else(|| std::env::var("HOME").ok().map(|h| format!("{h}/.config")));
    match base {
        Some(b) => format!("{b}/vesti"),
        None => "./vesti".to_owned(),
    }
}

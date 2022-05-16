#[cfg(test)]
mod parser_test;

#[macro_use]
mod macros;
pub mod ast;
pub mod maker;

use crate::error::err_kind::VestiParseErr::BracketMismatchErr;
use crate::error::err_kind::{VestiErrKind, VestiParseErr};
use crate::error::{self, VestiErr};
use crate::lexer::token::TokenType;
use crate::lexer::{LexToken, Lexer};
use crate::location::Span;
use ast::*;
use bitflags::bitflags;

const ENV_MATH_IDENT: [&str; 4] = ["equation", "align", "array", "eqnarray"];

bitflags! {
    struct DocState: u8 {
        const DOC_START = 0x1;
        const PREVENT_END_DOC = 0x2;
    }
}

impl DocState {
    fn new() -> Self {
        Self { bits: 0 }
    }
}

pub struct Parser<'a> {
    source: Lexer<'a>,
    peek_tok: Option<LexToken>,
    document_state: DocState,
}

impl<'a> Parser<'a> {
    // Store Parser in the heap
    pub fn new(source: Lexer<'a>) -> Box<Self> {
        let mut output = Box::new(Self {
            source,
            peek_tok: None,
            document_state: DocState::new(),
        });
        output.next_tok();

        output
    }

    fn next_tok(&mut self) -> Option<LexToken> {
        let curr_tok = self.peek_tok.take();
        self.peek_tok = self.source.next();

        curr_tok
    }

    fn peek_tok(&mut self) -> Option<TokenType> {
        self.peek_tok
            .as_ref()
            .map(|tok| tok.token.toktype)
            .as_ref()
            .copied()
    }

    fn peek_tok_location(&mut self) -> Option<Span> {
        self.peek_tok.as_ref().map(|lt| lt.span).as_ref().copied()
    }

    fn eat_whitespaces(&mut self, newline_handle: bool) {
        while self.peek_tok() == Some(TokenType::Space)
            || self.peek_tok() == Some(TokenType::Tab)
            || (newline_handle && self.peek_tok() == Some(TokenType::Newline))
        {
            self.next_tok();
        }
    }

    pub fn make_latex_format(&mut self) -> error::Result<String> {
        let latex = self.parse_latex()?;
        let mut output = String::new();

        for stmt in latex {
            output += &stmt.to_string();
        }

        Ok(output)
    }

    pub fn parse_latex(&mut self) -> error::Result<Latex> {
        let mut latex: Latex = Vec::new();
        while self.peek_tok().is_some() {
            latex.push(self.parse_statement()?);
        }
        if self.document_state == DocState::DOC_START {
            latex.push(Statement::DocumentEnd);
        }

        Ok(latex)
    }

    fn parse_statement(&mut self) -> error::Result<Statement> {
        let is_doc_start = (self.document_state & DocState::DOC_START).bits();
        match self.peek_tok() {
            // Keywords
            Some(TokenType::Docclass) if is_doc_start == 0 => self.parse_docclass(),
            Some(TokenType::Import) if is_doc_start == 0 => self.parse_usepackage(),
            Some(TokenType::StartDoc) if is_doc_start == 0 => {
                self.document_state |= DocState::DOC_START;
                self.next_tok();
                self.eat_whitespaces(true);
                Ok(Statement::DocumentStart)
            }
            Some(TokenType::Begenv) => self.parse_environment(),
            Some(TokenType::Endenv) => Err(VestiErr::make_parse_err(
                VestiParseErr::EndenvIsUsedWithoutBegenvPairErr,
                self.peek_tok_location(),
            )),
            Some(TokenType::Mtxt) => self.parse_text_in_math(),
            Some(TokenType::Etxt) => Err(VestiErr::make_parse_err(
                VestiParseErr::InvalidTokToParse {
                    got: TokenType::Etxt,
                },
                self.peek_tok_location(),
            )),
            Some(TokenType::DocumentStartMode) => {
                self.document_state |= DocState::PREVENT_END_DOC | DocState::DOC_START;
                let loc = self.next_tok().map(|lex_tok| lex_tok.span);
                expect_peek!(self: TokenType::Newline; loc);
                self.parse_statement()
            }

            // Identifiers
            Some(TokenType::LatexFunction) => self.parse_latex_function(),
            Some(TokenType::RawLatex) => self.parse_raw_latex(),
            Some(TokenType::Integer) => self.parse_integer(),
            Some(TokenType::Float) => self.parse_float(),
            Some(toktype) if toktype.should_not_use_before_doc() && is_doc_start == 0 => {
                Err(VestiErr::make_parse_err(
                    VestiParseErr::BeforeDocumentErr { got: toktype },
                    self.peek_tok_location(),
                ))
            }

            // Math related tokens
            Some(TokenType::TextMathStart) => self.parse_math_stmt(),
            Some(TokenType::InlineMathStart) => self.parse_math_stmt(),
            Some(TokenType::Superscript | TokenType::Subscript)
                if !self.source.math_started && is_doc_start != 0 =>
            {
                self.parse_scripts()
            }

            Some(TokenType::TextMathEnd) => Err(VestiErr::make_parse_err(
                VestiParseErr::InvalidTokToParse {
                    got: TokenType::TextMathEnd,
                },
                self.peek_tok_location(),
            )),
            Some(TokenType::InlineMathEnd) => Err(VestiErr::make_parse_err(
                VestiParseErr::InvalidTokToParse {
                    got: TokenType::InlineMathEnd,
                },
                self.peek_tok_location(),
            )),

            Some(TokenType::ILLEGAL) => Err(VestiErr::make_parse_err(
                VestiParseErr::IllegalCharacterFoundErr,
                self.peek_tok_location(),
            )),

            _ => self.parse_main_stmt(),
        }
    }

    fn parse_integer(&mut self) -> error::Result<Statement> {
        let curr_tok = self.next_tok().unwrap();
        let output = if let Ok(int) = curr_tok.token.literal.parse() {
            int
        } else {
            return Err(VestiErr::make_parse_err(
                VestiParseErr::ParseIntErr,
                Some(curr_tok.span),
            ));
        };

        Ok(Statement::Integer(output))
    }

    fn parse_float(&mut self) -> error::Result<Statement> {
        let curr_tok = self.next_tok().unwrap();
        let output = if let Ok(float) = curr_tok.token.literal.parse() {
            float
        } else {
            return Err(VestiErr::make_parse_err(
                VestiParseErr::ParseFloatErr,
                Some(curr_tok.span),
            ));
        };

        Ok(Statement::Float(output))
    }

    fn parse_raw_latex(&mut self) -> error::Result<Statement> {
        Ok(Statement::RawLatex(self.next_tok().unwrap().token.literal))
    }

    fn parse_main_stmt(&mut self) -> error::Result<Statement> {
        if self.peek_tok().is_none() {
            return Err(VestiErr::make_parse_err(
                VestiParseErr::EOFErr,
                self.peek_tok_location(),
            ));
        }
        let text = self.next_tok().unwrap().token.literal;

        Ok(Statement::MainText(text))
    }

    fn parse_math_stmt(&mut self) -> error::Result<Statement> {
        let start_location = self.peek_tok_location();
        let mut text = Vec::new();
        let mut stmt;

        match self.peek_tok() {
            Some(TokenType::TextMathStart) => {
                expect_peek!(self: TokenType::TextMathStart; self.peek_tok_location());

                while self.peek_tok() != Some(TokenType::TextMathEnd) {
                    stmt = match self.parse_statement() {
                        Ok(stmt) => stmt,
                        Err(VestiErr {
                            err_kind: VestiErrKind::ParseErr(VestiParseErr::EOFErr),
                            ..
                        }) => {
                            return Err(VestiErr::make_parse_err(
                                BracketMismatchErr {
                                    expected: TokenType::TextMathEnd,
                                },
                                start_location,
                            ));
                        }
                        Err(err) => return Err(err),
                    };
                    text.push(stmt);
                }

                expect_peek!(self: TokenType::TextMathEnd; self.peek_tok_location());
                Ok(Statement::MathText {
                    state: MathState::Text,
                    text,
                })
            }

            Some(TokenType::InlineMathStart) => {
                expect_peek!(self: TokenType::InlineMathStart; self.peek_tok_location());

                while self.peek_tok() != Some(TokenType::InlineMathEnd) {
                    stmt = match self.parse_statement() {
                        Ok(stmt) => stmt,
                        Err(VestiErr {
                            err_kind: VestiErrKind::ParseErr(VestiParseErr::EOFErr),
                            ..
                        }) => {
                            return Err(VestiErr::make_parse_err(
                                BracketMismatchErr {
                                    expected: TokenType::TextMathEnd,
                                },
                                start_location,
                            ));
                        }
                        Err(err) => return Err(err),
                    };
                    text.push(stmt);
                }

                expect_peek!(self: TokenType::InlineMathEnd; self.peek_tok_location());
                Ok(Statement::MathText {
                    state: MathState::Inline,
                    text,
                })
            }

            Some(toktype) => Err(VestiErr::make_parse_err(
                VestiParseErr::TypeMismatch {
                    expected: vec![TokenType::TextMathStart, TokenType::InlineMathStart],
                    got: toktype,
                },
                self.peek_tok_location(),
            )),

            None => Err(VestiErr::make_parse_err(
                VestiParseErr::ParseFloatErr,
                self.peek_tok_location(),
            )),
        }
    }

    fn parse_text_in_math(&mut self) -> error::Result<Statement> {
        let mut output: Latex = Vec::new();

        expect_peek!(self: TokenType::Mtxt; self.peek_tok_location());
        self.eat_whitespaces(false);

        while self.peek_tok() != Some(TokenType::Etxt) {
            if self.peek_tok().is_none() {
                return Err(VestiErr::make_parse_err(
                    VestiParseErr::BracketMismatchErr {
                        expected: TokenType::Etxt,
                    },
                    self.peek_tok_location(),
                ));
            }
            output.push(self.parse_statement()?);
        }

        expect_peek!(self: TokenType::Etxt; self.peek_tok_location());

        Ok(Statement::PlainTextInMath(output))
    }

    fn parse_scripts(&mut self) -> error::Result<Statement> {
        let start_location = self.peek_tok_location();
        let state = MathState::Text;
        let mut text: Latex = Vec::new();

        text.push(Statement::MainText(match self.peek_tok() {
            Some(TokenType::Superscript) => String::from("^"),
            Some(TokenType::Subscript) => String::from("_"),
            _ => unreachable!(),
        }));
        self.next_tok();

        if self.peek_tok() == Some(TokenType::Lbrace) {
            while self.peek_tok() != Some(TokenType::Rbrace) {
                text.push(self.parse_statement().map_err(|err| {
                    if let VestiErrKind::ParseErr(VestiParseErr::EOFErr) = err.err_kind {
                        VestiErr::make_parse_err(
                            BracketMismatchErr {
                                expected: TokenType::TextMathEnd,
                            },
                            start_location,
                        )
                    } else {
                        err
                    }
                })?);
            }
            expect_peek!(self: TokenType::Rbrace; self.peek_tok_location());
            text.push(Statement::MainText(String::from("}")));
        } else {
            text.push(self.parse_statement().map_err(|err| {
                if let VestiErrKind::ParseErr(VestiParseErr::EOFErr) = err.err_kind {
                    VestiErr::make_parse_err(
                        BracketMismatchErr {
                            expected: TokenType::TextMathEnd,
                        },
                        start_location,
                    )
                } else {
                    err
                }
            })?);
        }

        Ok(Statement::MathText { state, text })
    }

    fn parse_docclass(&mut self) -> error::Result<Statement> {
        let mut options: Option<Vec<Latex>> = None;

        expect_peek!(self: TokenType::Docclass; self.peek_tok_location());
        self.eat_whitespaces(false);

        take_name!(let name: String <- self);

        self.parse_comma_args(&mut options)?;
        if self.peek_tok() == Some(TokenType::Newline) {
            self.next_tok();
        }

        Ok(Statement::DocumentClass { name, options })
    }

    fn parse_usepackage(&mut self) -> error::Result<Statement> {
        expect_peek!(self: TokenType::Import; self.peek_tok_location());
        self.eat_whitespaces(false);

        if self.peek_tok() == Some(TokenType::Lbrace) {
            return self.parse_multiple_usepackages();
        }

        let mut options: Option<Vec<Latex>> = None;
        take_name!(let name: String <- self);

        self.parse_comma_args(&mut options)?;
        if self.peek_tok() == Some(TokenType::Newline) {
            self.next_tok();
        }

        Ok(Statement::Usepackage { name, options })
    }

    fn parse_multiple_usepackages(&mut self) -> error::Result<Statement> {
        let mut pkgs: Vec<Statement> = Vec::new();

        expect_peek!(self: TokenType::Lbrace; self.peek_tok_location());
        self.eat_whitespaces(true);

        while self.peek_tok() != Some(TokenType::Rbrace) {
            let mut options: Option<Vec<Latex>> = None;
            take_name!(let name: String <- self);

            self.parse_comma_args(&mut options)?;

            match self.peek_tok() {
                Some(TokenType::Newline) => self.eat_whitespaces(true),
                Some(TokenType::Text) => {}
                Some(TokenType::RawLatex) => {}
                Some(TokenType::Rbrace) => {
                    pkgs.push(Statement::Usepackage { name, options });
                    break;
                }
                Some(tok_type) => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErr::TypeMismatch {
                            expected: vec![
                                TokenType::Newline,
                                TokenType::Rbrace,
                                TokenType::Text,
                                TokenType::RawLatex,
                            ],
                            got: tok_type,
                        },
                        self.peek_tok_location(),
                    ));
                }
                None => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErr::EOFErr,
                        self.peek_tok_location(),
                    ));
                }
            }

            pkgs.push(Statement::Usepackage { name, options });
        }

        expect_peek!(self: TokenType::Rbrace; self.peek_tok_location());

        self.eat_whitespaces(false);
        if self.peek_tok() == Some(TokenType::Newline) {
            self.next_tok();
        }

        Ok(Statement::MultiUsepackages { pkgs })
    }

    fn parse_environment(&mut self) -> error::Result<Statement> {
        let begenv_location = self.peek_tok_location();
        let mut off_math_state = false;

        expect_peek!(self: TokenType::Begenv; self.peek_tok_location());
        self.eat_whitespaces(false);

        if self.peek_tok().is_none() {
            return Err(VestiErr {
                err_kind: VestiErrKind::ParseErr(VestiParseErr::BegenvIsNotClosedErr),
                location: begenv_location,
            });
        }
        let mut name = match self.peek_tok() {
            Some(TokenType::Text) => self.next_tok().unwrap().token.literal,
            Some(_) => {
                return Err(VestiErr::make_parse_err(
                    VestiParseErr::BegenvNameMissErr,
                    begenv_location,
                ))
            }
            None => {
                return Err(VestiErr::make_parse_err(
                    VestiParseErr::EOFErr,
                    begenv_location,
                ))
            }
        };

        // If name is math related one, then math mode will be turn on
        if ENV_MATH_IDENT.contains(&name.as_str()) {
            self.source.math_started = true;
            off_math_state = true;
        }

        while self.peek_tok() == Some(TokenType::Star) {
            expect_peek!(self: TokenType::Star; self.peek_tok_location());
            name.push('*');
        }
        self.eat_whitespaces(false);

        let args = self.parse_function_args(
            TokenType::Lparen,
            TokenType::Rparen,
            TokenType::Lsqbrace,
            TokenType::Rsqbrace,
        )?;
        let mut text: Latex = Vec::new();

        while self.peek_tok() != Some(TokenType::Endenv) {
            if self.peek_tok().is_none() {
                return Err(VestiErr::make_parse_err(
                    VestiParseErr::BegenvIsNotClosedErr,
                    begenv_location,
                ));
            }
            text.push(self.parse_statement()?);
        }

        expect_peek!(self: TokenType::Endenv; self.peek_tok_location());

        // If name is math related one, then math mode will be turn off
        if off_math_state {
            self.source.math_started = false;
        }
        if self.peek_tok() == Some(TokenType::Newline) {
            self.next_tok();
        }

        Ok(Statement::Environment { name, args, text })
    }

    fn parse_latex_function(&mut self) -> error::Result<Statement> {
        let mut name = self
            .next_tok()
            .ok_or(VestiErr {
                err_kind: VestiErrKind::ParseErr(VestiParseErr::EOFErr),
                location: self.peek_tok_location(),
            })?
            .token
            .literal;

        let mut is_no_arg_but_space = false;
        if self.peek_tok() == Some(TokenType::Space) {
            is_no_arg_but_space = true;
            self.eat_whitespaces(false);
        }

        let args = self.parse_function_args(
            TokenType::Lbrace,
            TokenType::Rbrace,
            TokenType::OptionalOpenBrace,
            TokenType::Rsqbrace,
        )?;
        if args.is_empty() && is_no_arg_but_space {
            name += " ";
        }

        Ok(Statement::LatexFunction { name, args })
    }

    fn parse_comma_args(&mut self, options: &mut Option<Vec<Latex>>) -> error::Result<()> {
        self.eat_whitespaces(false);
        if self.peek_tok() == Some(TokenType::Lparen) {
            let mut options_vec: Vec<Latex> = Vec::new();
            // Since we yet tell to the computer to get the next token,
            // peeking the token location is the location of the open brace one.
            let open_brace_location = self.peek_tok_location();
            self.next_tok();
            self.eat_whitespaces(true);

            while self.peek_tok() != Some(TokenType::Rparen) {
                if self.peek_tok().is_none() {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErr::BracketNumberMatchedErr,
                        open_brace_location,
                    ));
                }

                self.eat_whitespaces(true);
                let mut tmp: Latex = Vec::new();

                while self.peek_tok() != Some(TokenType::Comma) {
                    self.eat_whitespaces(true);
                    if self.peek_tok().is_none() {
                        return Err(VestiErr::make_parse_err(
                            VestiParseErr::BracketNumberMatchedErr,
                            open_brace_location,
                        ));
                    }
                    if self.peek_tok() == Some(TokenType::Rparen) {
                        break;
                    }
                    tmp.push(self.parse_statement()?);
                }

                options_vec.push(tmp);
                self.eat_whitespaces(true);

                if self.peek_tok() == Some(TokenType::Rparen) {
                    break;
                }

                expect_peek!(self: TokenType::Comma; self.peek_tok_location());
                self.eat_whitespaces(true);
            }

            expect_peek!(self: TokenType::Rparen; self.peek_tok_location());
            self.eat_whitespaces(false);
            *options = Some(options_vec);
        }

        Ok(())
    }

    fn parse_function_args(
        &mut self,
        open: TokenType,
        closed: TokenType,
        optional_open: TokenType,
        optional_closed: TokenType,
    ) -> error::Result<Vec<(ArgNeed, Vec<Statement>)>> {
        let mut args: Vec<(ArgNeed, Vec<Statement>)> = Vec::new();

        if self.peek_tok() == Some(open)
            || self.peek_tok() == Some(optional_open)
            || self.peek_tok() == Some(TokenType::Star)
        {
            loop {
                match self.peek_tok() {
                    Some(toktype) if toktype == open => {
                        self.parse_function_args_core(&mut args, open, closed, ArgNeed::MainArg)?
                    }

                    Some(toktype) if toktype == optional_open => self.parse_function_args_core(
                        &mut args,
                        optional_open,
                        optional_closed,
                        ArgNeed::Optional,
                    )?,

                    Some(TokenType::Star) => {
                        expect_peek!(self: TokenType::Star; self.peek_tok_location());
                        args.push((ArgNeed::StarArg, Vec::new()));
                    }

                    _ => break,
                }

                if self.peek_tok() == Some(TokenType::Newline) || self.peek_tok().is_none() {
                    break;
                }
            }
        }

        Ok(args)
    }

    fn parse_function_args_core(
        &mut self,
        args: &mut Vec<(ArgNeed, Vec<Statement>)>,
        open: TokenType,
        closed: TokenType,
        arg_need: ArgNeed,
    ) -> error::Result<()> {
        let open_brace_location = self.peek_tok_location();
        let mut nested = 0;
        expect_peek!(self: open; open_brace_location);

        loop {
            let mut tmp_vec: Vec<Statement> = Vec::new();
            while (self.peek_tok() != Some(closed) || nested > 0)
                && self.peek_tok() != Some(TokenType::ArgSpliter)
            {
                if self.peek_tok().is_none() {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErr::BracketNumberMatchedErr,
                        open_brace_location,
                    ));
                }
                if self.peek_tok() == Some(open) {
                    nested += 1;
                }
                if self.peek_tok() == Some(closed) {
                    nested -= 1;
                }
                let stmt = self.parse_statement()?;
                tmp_vec.push(stmt);
            }
            args.push((arg_need, tmp_vec));

            if self.peek_tok() != Some(TokenType::ArgSpliter) {
                break;
            }
            expect_peek!(self: TokenType::ArgSpliter; self.peek_tok_location());

            // Multiline splitting argument support
            self.eat_whitespaces(true);
        }
        expect_peek!(self: closed; self.peek_tok_location());

        Ok(())
    }
}

//! `#builtin` handlers

use std::borrow::Cow;
use std::fmt::Write as _;

use crate::diagnostic::{DiagnosticInner, IoDiagnostic, ParseErrorInfo};
use crate::lexer::token::{TokenType, is_function_param};
use crate::location::Span;

use super::ast::{MathState, Stmt};
use super::expectable::{Expectable, Which};
use super::{ParseError, Parser, VESTI_DUMMY_DIR, compile_type, tok_in_text};

#[derive(Clone, Copy)]
enum MathClass {
    Ordinary = 0,
    Largeop = 1,
    Binary = 2,
    Relation = 3,
    Opening = 4,
    Closing = 5,
    Punct = 6,
    Variable = 7,
}

fn math_class_from_str(s: &str) -> Option<MathClass> {
    Some(match s {
        "ordinary" => MathClass::Ordinary,
        "largeop" => MathClass::Largeop,
        "binary" => MathClass::Binary,
        "relation" => MathClass::Relation,
        "opening" => MathClass::Opening,
        "closing" => MathClass::Closing,
        "punct" => MathClass::Punct,
        "variable" => MathClass::Variable,
        _ => return None,
    })
}

impl<'s, 'd> Parser<'s, 'd> {
    pub(super) fn parse_builtins(&mut self, builtin_fnt: &'s str) -> Result<Stmt<'s>, ParseError> {
        let builtin_location = self.get_tok(Which::Current).span();

        if let Some(fnt_param) = is_function_param(builtin_fnt) {
            if fnt_param % 10 == 0 {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::InvalidDefunParam(fnt_param),
                    Some(builtin_location),
                );
                return Err(ParseError::ParseFailed);
            }
            let nested = fnt_param / 10;
            let arg_num = fnt_param % 10;
            return Ok(Stmt::DefunParamList {
                nested,
                arg_num,
                span: builtin_location,
            });
        }

        match builtin_fnt {
            "chardef" => self.parse_builtin_chardef(),
            "copy_file" => self.parse_builtin_copy_file(),
            "engine_type" => self.parse_builtin_engine_type(),
            "enum" => self.parse_builtin_enum(),
            "enum_counter" => self.parse_builtin_enum_counter(),
            "eq" => self.parse_builtin_eq(),
            "get_filepath" => self.parse_builtin_get_filepath(),
            "label" => self.parse_builtin_label(),
            "mathchardef" => self.parse_builtin_mathchardef(),
            "mathmode" => self.parse_builtin_mathmode(),
            "picture" => self.parse_builtin_picture(),
            "raw_tex" => self.parse_builtin_raw_tex(),
            "showfont" => self.parse_builtin_showfont(),
            "textmode" => self.parse_builtin_textmode(),
            _ => {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::InvalidBuiltin(builtin_fnt.to_owned()),
                    Some(builtin_location),
                );
                Err(ParseError::ParseFailed)
            }
        }
    }

    fn parse_builtins_arguments(
        &mut self,
        span: Span,
        open: TokenType<'static>,
        closed: TokenType<'static>,
        ignore_newline: bool,
    ) -> Result<String, ParseError> {
        let mut inner = String::new();
        self.expect_eat(open)?;

        let mut nested = 1usize;
        loop {
            let cur = self.curr_toktype();
            let cont = if super::toktype_eq(&cur, &open) {
                nested += 1;
                true
            } else if super::toktype_eq(&cur, &closed) {
                nested -= 1;
                nested > 0
            } else {
                true
            };
            if !cont {
                break;
            }
            if matches!(self.curr_toktype(), TokenType::Eof) {
                self.diagnostic
                    .set_parse_error(ParseErrorInfo::EofErr, Some(span));
                return Err(ParseError::ParseFailed);
            }
            inner.push_str(tok_in_text(self.get_tok(Which::Current)));
            self.next_token();
        }

        self.expect_eat(closed)?;
        self.eat_whitespaces(ignore_newline);
        Ok(inner)
    }

    fn parse_builtin_textmode(&mut self) -> Result<Stmt<'s>, ParseError> {
        let loc = self.get_tok(Which::Current).span();
        self.next_token();
        self.eat_whitespaces(false);

        self.expect_remain(TokenType::Lbrace)?;
        if !self.doc_state.math_mode {
            self.diagnostic
                .set_parse_error(ParseErrorInfo::TextmodeInText, Some(loc));
            return Err(ParseError::ParseFailed);
        }

        self.doc_state.math_mode = false;
        let inner = self.parse_brace(false)?;
        self.doc_state.math_mode = true;

        match inner {
            Stmt::Braced { inner, .. } => Ok(Stmt::Braced {
                unwrap_brace: true,
                inner,
            }),
            other => Ok(other),
        }
    }

    fn parse_builtin_mathmode(&mut self) -> Result<Stmt<'s>, ParseError> {
        let loc = self.get_tok(Which::Current).span();
        self.next_token();
        self.eat_whitespaces(false);

        self.expect_remain(TokenType::Lbrace)?;
        if self.doc_state.math_mode {
            self.diagnostic
                .set_parse_error(ParseErrorInfo::MathmodeInMath, Some(loc));
            return Err(ParseError::ParseFailed);
        }

        self.doc_state.math_mode = true;
        let inner = self.parse_brace(false)?;
        self.doc_state.math_mode = false;

        match inner {
            Stmt::Braced { inner, .. } => Ok(Stmt::Braced {
                unwrap_brace: true,
                inner,
            }),
            other => Ok(other),
        }
    }

    fn parse_builtin_label(&mut self) -> Result<Stmt<'s>, ParseError> {
        let label_block_loc = self.get_tok(Which::Current).span();
        self.next_token(); // eat `#label`
        self.eat_whitespaces(false);

        let label = self.parse_builtins_arguments(
            label_block_loc,
            TokenType::Lparen,
            TokenType::Rparen,
            true,
        )?;

        if !self.expect(Which::Current, &[TokenType::Useenv]) {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("label"),
                    note: "`#label` must be located before `useenv`",
                },
                Some(label_block_loc),
            );
            return Err(ParseError::ParseFailed);
        }

        let mut env = self.parse_environment::<true>()?;
        if let Stmt::Environment { label: l, .. } = &mut env {
            *l = Some(label);
        }
        Ok(env)
    }

    fn parse_builtin_eq(&mut self) -> Result<Stmt<'s>, ParseError> {
        let eq_block_loc = self.get_tok(Which::Current).span();
        if self.doc_state.math_mode {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("eq"),
                    note: "`#eq` cannot be used inside math mode",
                },
                Some(eq_block_loc),
            );
            return Err(ParseError::ParseFailed);
        }

        self.next_token(); // eat `#eq`
        self.eat_whitespaces(false);

        let label = if self.expect(Which::Current, &[TokenType::Lparen]) {
            Some(self.parse_builtins_arguments(
                eq_block_loc,
                TokenType::Lparen,
                TokenType::Rparen,
                true,
            )?)
        } else {
            None
        };

        self.doc_state.math_mode = true;
        let inner = self.parse_brace(false)?;
        self.doc_state.math_mode = false;

        let inner_vec = match inner {
            Stmt::Braced { inner, .. } => inner,
            _ => unreachable!(),
        };

        Ok(Stmt::MathCtx {
            state: MathState::Labeled,
            inner: inner_vec,
            label,
        })
    }

    fn parse_builtin_showfont(&mut self) -> Result<Stmt<'s>, ParseError> {
        let showfont_loc = self.get_tok(Which::Current).span();
        self.next_token(); // eat `#showfont`
        self.eat_whitespaces(false);
        self.expect_eat(TokenType::Lparen)?;

        if !self.expect(Which::Current, &[TokenType::Integer]) {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("showfont"),
                    note: "only integer values are possible",
                },
                Some(showfont_loc),
            );
            return Err(ParseError::ParseFailed);
        }
        let num: u8 = match tok_in_text(self.get_tok(Which::Current)).parse() {
            Ok(v) => v,
            Err(_) => {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::WrongBuiltin {
                        name: Cow::Borrowed("showfont"),
                        note: "integer should be in 0 to 255",
                    },
                    Some(showfont_loc),
                );
                return Err(ParseError::ParseFailed);
            }
        };
        self.next_token();

        self.expect_remain(TokenType::Rparen)?;
        let mut output = String::with_capacity(50);
        let _ = write!(
            output,
            " {{\\ttfamily\\expandafter\\meaning\\the\\textfont{num}}}"
        );
        Ok(Stmt::TextLit(Cow::Owned(output)))
    }

    fn parse_builtin_chardef(&mut self) -> Result<Stmt<'s>, ParseError> {
        let chardef_loc = self.get_tok(Which::Current).span();
        self.next_token(); // eat `#chardef`
        self.eat_whitespaces(false);

        if !self.expect(Which::Current, &[TokenType::Text, TokenType::Integer]) {
            let span = self.get_tok(Which::Current).span();
            let obtained = self.curr_toktype();
            self.diagnostic.set_parse_error(
                ParseErrorInfo::TokenExpected {
                    expected: TEXT_INTEGER,
                    obtained: Some(obtained),
                },
                Some(span),
            );
            return Err(ParseError::ParseFailed);
        }

        let unicode_codepoint =
            match u32::from_str_radix(tok_in_text(self.get_tok(Which::Current)), 16) {
                Ok(v) => v,
                Err(_) => {
                    self.diagnostic.set_parse_error(
                        ParseErrorInfo::WrongBuiltin {
                            name: Cow::Borrowed("chardef"),
                            note: "hexdecimal number expected in the third argument",
                        },
                        Some(chardef_loc),
                    );
                    return Err(ParseError::ParseFailed);
                }
            };
        self.next_token();
        self.eat_whitespaces(false);

        if !self.expect(
            Which::Current,
            &[TokenType::LatexFunction, TokenType::MakeAtLetterFnt],
        ) {
            let span = self.get_tok(Which::Current).span();
            let obtained = self.curr_toktype();
            self.diagnostic.set_parse_error(
                ParseErrorInfo::TokenExpected {
                    expected: LTXFNT_MAKEAT,
                    obtained: Some(obtained),
                },
                Some(span),
            );
            return Err(ParseError::ParseFailed);
        }
        let latex_function = tok_in_text(self.get_tok(Which::Current));
        self.next_token();
        self.eat_whitespaces(false);

        if !self.expect(Which::Current, &[TokenType::Newline]) {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("chardef"),
                    note: "this builtin must end with the newline",
                },
                Some(chardef_loc),
            );
            return Err(ParseError::ParseFailed);
        }

        let mut output = String::with_capacity(50);
        let _ = write!(
            output,
            "\\chardef{latex_function}=\"{unicode_codepoint:X}\n"
        );
        Ok(Stmt::TextLit(Cow::Owned(output)))
    }

    fn parse_builtin_mathchardef(&mut self) -> Result<Stmt<'s>, ParseError> {
        let mchardef_loc = self.get_tok(Which::Current).span();
        self.next_token(); // eat `#mathchardef`
        self.eat_whitespaces(false);

        self.expect_eat(TokenType::Period)?;
        self.expect_remain(TokenType::Text)?;

        let kind_txt = tok_in_text(self.get_tok(Which::Current));
        let math_class = match math_class_from_str(kind_txt) {
            Some(c) => c,
            None => {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::WrongBuiltin {
                        name: Cow::Borrowed("mathchardef"),
                        note: "invalid math class was found. Here is the list of math class available:\n.ordinary  .largeop  .binary  .relation\n.opening   .closing  .punct   .variable\nhere, the prefix `.` is needed",
                    },
                    Some(mchardef_loc),
                );
                return Err(ParseError::ParseFailed);
            }
        };
        self.next_token();
        self.eat_whitespaces(false);

        self.expect_remain(TokenType::Integer)?;
        let font_num: u8 = match tok_in_text(self.get_tok(Which::Current)).parse() {
            Ok(v) => v,
            Err(_) => {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::WrongBuiltin {
                        name: Cow::Borrowed("mathchardef"),
                        note: "integer should be in 0 to 255",
                    },
                    Some(mchardef_loc),
                );
                return Err(ParseError::ParseFailed);
            }
        };
        self.next_token();
        self.eat_whitespaces(false);

        if !self.expect(Which::Current, &[TokenType::Text, TokenType::Integer]) {
            let span = self.get_tok(Which::Current).span();
            let obtained = self.curr_toktype();
            self.diagnostic.set_parse_error(
                ParseErrorInfo::TokenExpected {
                    expected: TEXT_INTEGER,
                    obtained: Some(obtained),
                },
                Some(span),
            );
            return Err(ParseError::ParseFailed);
        }

        let unicode_codepoint =
            match u32::from_str_radix(tok_in_text(self.get_tok(Which::Current)), 16) {
                Ok(v) => v,
                Err(_) => {
                    self.diagnostic.set_parse_error(
                        ParseErrorInfo::WrongBuiltin {
                            name: Cow::Borrowed("mathchardef"),
                            note: "hexdecimal number expected in the third argument",
                        },
                        Some(mchardef_loc),
                    );
                    return Err(ParseError::ParseFailed);
                }
            };
        self.next_token();
        self.eat_whitespaces(false);

        if !self.expect(
            Which::Current,
            &[TokenType::LatexFunction, TokenType::MakeAtLetterFnt],
        ) {
            let span = self.get_tok(Which::Current).span();
            let obtained = self.curr_toktype();
            self.diagnostic.set_parse_error(
                ParseErrorInfo::TokenExpected {
                    expected: LTXFNT_MAKEAT,
                    obtained: Some(obtained),
                },
                Some(span),
            );
            return Err(ParseError::ParseFailed);
        }
        let latex_function = tok_in_text(self.get_tok(Which::Current));
        self.next_token();
        self.eat_whitespaces(false);

        if !self.expect(Which::Current, &[TokenType::Newline]) {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("mathchardef"),
                    note: "this builtin must end with the newline",
                },
                Some(mchardef_loc),
            );
            return Err(ParseError::ParseFailed);
        }

        let mut output = String::with_capacity(50);
        let _ = write!(
            output,
            "\\Umathchardef{latex_function}={} {font_num} \"{unicode_codepoint:X}\n",
            math_class as u8
        );
        Ok(Stmt::TextLit(Cow::Owned(output)))
    }

    fn parse_builtin_enum(&mut self) -> Result<Stmt<'s>, ParseError> {
        let enum_loc = self.get_tok(Which::Current).span();
        if self.enum_depth >= 5 {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("enum"),
                    note: "`#enum` builtin cannot be nested more than four times",
                },
                Some(enum_loc),
            );
            return Err(ParseError::ParseFailed);
        }
        self.enum_depth += 1;

        self.next_token(); // eat `#enum`
        self.eat_whitespaces(false);

        let label_kind = if self.expect(Which::Current, &[TokenType::Lparen]) {
            Some(self.parse_builtins_arguments(
                enum_loc,
                TokenType::Lparen,
                TokenType::Rparen,
                true,
            )?)
        } else {
            None
        };

        let inner = self.parse_brace(false)?;
        let inner_vec = match inner {
            Stmt::Braced { inner, .. } => inner,
            _ => unreachable!(),
        };

        let env = Stmt::Environment {
            name: Cow::Borrowed("enumerate"),
            args: Vec::new(),
            inner: inner_vec,
            label: None,
        };

        let mut output_inner: Vec<Stmt<'s>> = Vec::with_capacity(5);
        output_inner.push(Stmt::TextLit(Cow::Borrowed("\\begingroup ")));

        if let Some(lk) = &label_kind {
            let label_cmd = match self.enum_depth {
                1 => "labelenumi",
                2 => "labelenumii",
                3 => "labelenumiii",
                4 => "labelenumiv",
                _ => unreachable!(),
            };
            let mut reset_label = String::new();
            let _ = write!(reset_label, "\\renewcommand{{\\{label_cmd}}}{{");

            let counter = match self.enum_depth {
                1 => "enumi",
                2 => "enumii",
                3 => "enumiii",
                4 => "enumiv",
                _ => unreachable!(),
            };

            let bytes = lk.as_bytes();
            let mut i = 0usize;
            while i < bytes.len() {
                let current = bytes[i];
                if current != b'*' {
                    // copy a full UTF-8 codepoint
                    let len = utf8_len(current);
                    reset_label.push_str(&lk[i..i + len]);
                    i += len;
                    continue;
                }
                if i + 1 < bytes.len() && bytes[i + 1] == b'*' {
                    i += 2;
                    reset_label.push('*');
                    continue;
                }
                let _ = write!(reset_label, "{{{counter}}}");
                i += 1;
            }
            reset_label.push_str("}\n");
            output_inner.push(Stmt::TextLit(Cow::Owned(reset_label)));
        }

        output_inner.push(env);
        output_inner.push(Stmt::TextLit(Cow::Borrowed("\\endgroup ")));

        self.enum_depth -= 1;

        Ok(Stmt::Braced {
            unwrap_brace: true,
            inner: output_inner,
        })
    }

    fn parse_builtin_enum_counter(&mut self) -> Result<Stmt<'s>, ParseError> {
        let enum_counter_loc = self.get_tok(Which::Current).span();
        if self.enum_depth >= 5 {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("enum_counter"),
                    note: "`#enum_counter` builtin cannot be nested more than four times",
                },
                Some(enum_counter_loc),
            );
            return Err(ParseError::ParseFailed);
        }

        let counter = match self.enum_depth {
            1 => "enumi",
            2 => "enumii",
            3 => "enumiii",
            4 => "enumiv",
            _ => unreachable!(),
        };
        Ok(Stmt::TextLit(Cow::Owned(counter.to_owned())))
    }

    fn parse_builtin_picture(&mut self) -> Result<Stmt<'s>, ParseError> {
        let picture_block_loc = self.get_tok(Which::Current).span();
        self.next_token(); // eat `#picture`
        self.eat_whitespaces(false);

        let unit_length = if self.expect(Which::Current, &[TokenType::Lsqbrace]) {
            Some(self.parse_builtins_arguments(
                picture_block_loc,
                TokenType::Lsqbrace,
                TokenType::Rsqbrace,
                false,
            )?)
        } else {
            None
        };

        self.expect_eat(TokenType::Lparen)?;
        let width = self.read_picture_int("picture")?;
        self.expect_eat(TokenType::Comma)?;
        self.eat_whitespaces(false);
        let height = self.read_picture_int("picture")?;
        self.expect_eat(TokenType::Rparen)?;
        self.eat_whitespaces(false);

        let mut xoffset = None;
        let mut yoffset = None;
        if self.expect(Which::Current, &[TokenType::Lparen]) {
            self.expect_eat(TokenType::Lparen)?;
            xoffset = Some(self.read_picture_int("picture")?);
            self.expect_eat(TokenType::Comma)?;
            self.eat_whitespaces(false);
            yoffset = Some(self.read_picture_int("picture")?);
            self.expect_eat(TokenType::Rparen)?;
        }
        self.eat_whitespaces(true);

        let inner = self.parse_brace(false)?;
        let inner_vec = match inner {
            Stmt::Braced { inner, .. } => inner,
            _ => unreachable!(),
        };

        Ok(Stmt::PictureEnvironment {
            width,
            height,
            xoffset,
            yoffset,
            unit_length,
            inner: inner_vec,
        })
    }

    fn read_picture_int(&mut self, builtin_name: &'static str) -> Result<usize, ParseError> {
        let loc = self.get_tok(Which::Current).span();
        let tok = self.expect_eat(TokenType::Integer)?;
        match tok.in_text_src().parse::<usize>() {
            Ok(v) => Ok(v),
            Err(_) => {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::WrongBuiltin {
                        name: Cow::Borrowed(builtin_name),
                        note: "integer should be nonnegative",
                    },
                    Some(loc),
                );
                Err(ParseError::ParseFailed)
            }
        }
    }

    fn parse_builtin_raw_tex(&mut self) -> Result<Stmt<'s>, ParseError> {
        let raw_tex_block_loc = self.get_tok(Which::Current).span();
        while self.expect(Which::Peek, &[TokenType::Space, TokenType::Tab]) {
            self.next_token();
        }
        if !self.expect(Which::Peek, &[TokenType::DefineFunction]) {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("raw_tex"),
                    note: "`#raw_tex` must be located before `defun`",
                },
                Some(raw_tex_block_loc),
            );
            return Err(ParseError::ParseFailed);
        }
        self.doc_state.xparse_defun = false;
        Ok(Stmt::NopStmt)
    }

    fn parse_builtin_engine_type(&mut self) -> Result<Stmt<'s>, ParseError> {
        let comp_ty_loc = self.get_tok(Which::Current).span();
        if comp_ty_loc.start.row() != 1 {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("engine_type"),
                    note: "`#engine_type` must be located in the very first line of the vesti code",
                },
                Some(comp_ty_loc),
            );
            return Err(ParseError::ParseFailed);
        }
        if !self.allows.change_engine {
            self.diagnostic
                .set_parse_error(ParseErrorInfo::ChangeEngineTwice, Some(comp_ty_loc));
            return Err(ParseError::ParseFailed);
        }

        self.next_token(); // eat #engine_type
        if self.expect(Which::Peek, &[TokenType::Space, TokenType::Tab]) {
            self.next_token();
        }

        while !self.expect(Which::Peek, &[TokenType::Lparen, TokenType::Eof]) {
            self.next_token();
        }
        self.next_token();

        self.expect_eat(TokenType::Lparen)?;
        self.eat_whitespaces(true);

        self.expect_remain(TokenType::Text)?;
        let engine = match compile_type(tok_in_text(self.get_tok(Which::Current))) {
            Some(e) => e,
            None => {
                let span = self.get_tok(Which::Current).span();
                let name = tok_in_text(self.get_tok(Which::Current));
                self.diagnostic
                    .set_parse_error(ParseErrorInfo::InvalidLatexEngine(name), Some(span));
                return Err(ParseError::ParseFailed);
            }
        };

        self.next_token();
        self.eat_whitespaces(true);
        self.expect_remain(TokenType::Rparen)?;

        if self.engine_slot.is_some() {
            self.engine_slot = Some(engine);
            self.current_engine = engine;
            self.engine_slot = None;
            Ok(Stmt::NopStmt)
        } else {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("engine_type"),
                    note: "`#engine_type` is used twice",
                },
                Some(comp_ty_loc),
            );
            Err(ParseError::ParseFailed)
        }
    }

    fn parse_builtin_copy_file(&mut self) -> Result<Stmt<'s>, ParseError> {
        let import_file_loc = self.get_tok(Which::Current).span();
        self.next_token(); // eat #copy_file
        self.eat_whitespaces(false);
        self.expect_remain(TokenType::Lparen)?;

        let left_parn_loc = self.get_tok(Which::Current).span();
        let (file_name, raw_filename) = self.parse_filepath_helper(left_parn_loc)?;

        let into_copy_filename = format!("{VESTI_DUMMY_DIR}/{raw_filename}");

        if std::fs::copy(&file_name, &into_copy_filename).is_err() {
            let io_diag = IoDiagnostic::new(
                Some(import_file_loc),
                format!("cannot copy from {file_name} into {into_copy_filename}"),
            );
            self.diagnostic
                .init_diag_inner(DiagnosticInner::IoError(io_diag));
            return Err(ParseError::ParseFailed);
        }

        Ok(Stmt::NopStmt)
    }

    fn parse_builtin_get_filepath(&mut self) -> Result<Stmt<'s>, ParseError> {
        let _import_file_loc = self.get_tok(Which::Current).span();
        self.next_token(); // eat #get_filepath
        self.eat_whitespaces(false);
        self.expect_remain(TokenType::Lparen)?;

        let left_parn_loc = self.get_tok(Which::Current).span();
        let (file_name, _) = self.parse_filepath_helper(left_parn_loc)?;

        let rel = pathdiff_relative(&file_name, VESTI_DUMMY_DIR);
        Ok(Stmt::FilePath(Cow::Owned(rel)))
    }
}

const TEXT_INTEGER: &[TokenType<'static>] = &[TokenType::Text, TokenType::Integer];
const LTXFNT_MAKEAT: &[TokenType<'static>] =
    &[TokenType::LatexFunction, TokenType::MakeAtLetterFnt];

/// Length in bytes of the UTF-8 sequence starting with `first`.
fn utf8_len(first: u8) -> usize {
    if first < 0x80 {
        1
    } else if first >> 5 == 0b110 {
        2
    } else if first >> 4 == 0b1110 {
        3
    } else {
        4
    }
}

fn pathdiff_relative(target: &str, base_dir: &str) -> String {
    use std::path::{Component, Path, PathBuf};

    let target = Path::new(target);
    let base = Path::new(base_dir);

    let mut ti = target.components().peekable();
    let mut bi = base.components().peekable();

    // strip common prefix
    loop {
        match (ti.peek(), bi.peek()) {
            (Some(a), Some(b)) if a == b => {
                ti.next();
                bi.next();
            }
            _ => break,
        }
    }

    let mut result = PathBuf::new();
    for comp in bi {
        if let Component::Normal(_) | Component::CurDir = comp {
            result.push("..");
        }
    }
    for comp in ti {
        result.push(comp.as_os_str());
    }

    let s = result.to_string_lossy().replace('\\', "/");
    if s.is_empty() {
        target.to_string_lossy().replace('\\', "/")
    } else {
        s
    }
}

#[cfg(test)]
mod parser_test;

#[macro_use]
mod macros;
pub mod ast;

use std::ffi::OsString;
use std::fs;
use std::mem::MaybeUninit;
use std::path::PathBuf;

use base64ct::{Base64Url, Encoding};
use md5::{Digest, Md5};
use path_slash::PathBufExt;

use crate::constants::{self, ILLEGAL_USAGE_OF_SUPERSUB_SCRIPT};
use crate::error::{self, DeprecatedKind, VestiErr, VestiParseErrKind};
use crate::lexer::token::{FunctionDefKind, Token, TokenType};
use crate::lexer::Lexer;
use crate::location::Span;
use crate::vesmodule::VestiModule;
use ast::*;

// TODO: Make a keyword that can use lua script
const ENV_MATH_IDENT: [&str; 7] = [
    "equation", "align", "array", "eqnarray", "gather", "multline", "luacode",
];

#[repr(packed)]
struct DocState {
    doc_start: bool,
    prevent_end_doc: bool,
    parsing_define: bool,
}

impl DocState {
    fn main_document_state() -> Self {
        Self {
            doc_start: false,
            prevent_end_doc: false,
            parsing_define: false,
        }
    }

    fn default_state() -> Self {
        Self {
            doc_start: true,
            prevent_end_doc: true,
            parsing_define: false,
        }
    }
}

pub struct Parser<'a> {
    source: Lexer<'a>,
    peek_tok: Token,
    is_main_vesti: bool,
    latex3_included: bool,
    use_old_bracket: bool,
    doc_state: DocState,
}

impl<'a> Parser<'a> {
    // Store Parser in the heap
    pub fn new(source: Lexer<'a>, is_main_vesti: bool, use_old_bracket: bool) -> Box<Self> {
        let mut output = Box::new(Self {
            source,
            peek_tok: Token::default(),
            is_main_vesti,
            latex3_included: false,
            use_old_bracket,
            doc_state: if is_main_vesti {
                DocState::main_document_state()
            } else {
                DocState::default_state()
            },
        });
        output.next_tok();

        output
    }

    fn next_tok(&mut self) -> Token {
        let curr_tok = std::mem::take(&mut self.peek_tok);
        self.peek_tok = self.source.next();

        curr_tok
    }

    #[inline]
    pub fn is_main_vesti(&self) -> bool {
        self.is_main_vesti
    }

    #[inline]
    fn peek_tok(&mut self) -> TokenType {
        self.peek_tok.toktype
    }

    #[inline]
    fn peek_tok_location(&mut self) -> Span {
        self.peek_tok.span
    }

    #[inline]
    fn is_eof(&self) -> bool {
        self.peek_tok.toktype == TokenType::Eof
    }

    #[inline]
    fn is_premiere(&self) -> bool {
        !self.doc_state.doc_start && !self.doc_state.parsing_define
    }

    #[inline]
    fn is_math_mode(&self) -> bool {
        self.source.get_math_started() || self.doc_state.parsing_define
    }

    fn eat_whitespaces<const NEWLINE_HANDLE: bool>(&mut self) {
        while self.peek_tok() == TokenType::Space
            || self.peek_tok() == TokenType::Tab
            || (NEWLINE_HANDLE && self.peek_tok() == TokenType::Newline)
        {
            self.next_tok();
        }
    }

    pub fn parse_latex(&mut self) -> error::Result<Latex> {
        let mut latex: Latex = Vec::with_capacity(150);
        while !self.is_eof() {
            let stmt = self.parse_statement()?;
            latex.push(stmt);
        }
        if !self.is_premiere() && !self.doc_state.prevent_end_doc {
            latex.push(Statement::DocumentEnd);
        }

        Ok(latex)
    }

    fn parse_statement(&mut self) -> error::Result<Statement> {
        match self.peek_tok() {
            // Keywords
            TokenType::Docclass if self.is_premiere() => self.parse_docclass(),
            TokenType::ImportPkg if self.is_premiere() => self.parse_usepackage(),
            TokenType::ImportVesti => self.parse_import_vesti(),
            TokenType::ImportFile => self.parse_import_file(),
            TokenType::FilePath => self.parse_file_path(),
            TokenType::ImportModule => self.parse_import_module(),
            TokenType::StartDoc if self.is_premiere() => {
                self.doc_state.doc_start = true;
                self.next_tok();
                self.eat_whitespaces::<true>();
                Ok(Statement::DocumentStart)
            }
            TokenType::NonStopMode => {
                self.next_tok();
                self.eat_whitespaces::<true>();
                Ok(Statement::NonStopMode)
            }
            TokenType::MakeAtLetter => {
                self.next_tok();
                self.eat_whitespaces::<true>();
                Ok(Statement::MakeAtLetter)
            }
            TokenType::MakeAtOther => {
                self.next_tok();
                self.eat_whitespaces::<true>();
                Ok(Statement::MakeAtOther)
            }
            TokenType::ImportLatex3 if self.is_premiere() => {
                self.latex3_included = true;
                self.next_tok();
                self.eat_whitespaces::<true>();
                Ok(Statement::ImportExpl3Pkg)
            }
            TokenType::Latex3On => {
                if self.latex3_included {
                    self.next_tok();
                    self.eat_whitespaces::<true>();
                    Ok(Statement::Latex3On)
                } else {
                    Err(VestiErr::make_parse_err(
                        VestiParseErrKind::IllegalUseErr {
                            got: self.peek_tok(),
                            reason: Some("must use `importltx3` to use this keyword"),
                        },
                        self.peek_tok_location(),
                    ))
                }
            }
            TokenType::Latex3Off => {
                if self.latex3_included {
                    self.next_tok();
                    self.eat_whitespaces::<true>();
                    Ok(Statement::Latex3Off)
                } else {
                    Err(VestiErr::make_parse_err(
                        VestiParseErrKind::IllegalUseErr {
                            got: self.peek_tok(),
                            reason: Some("must use `importltx3` to use this keyword"),
                        },
                        self.peek_tok_location(),
                    ))
                }
            }
            TokenType::Useenv => self.parse_environment::<true>(),
            TokenType::Begenv => self.parse_environment::<false>(),
            TokenType::Endenv => self.parse_end_phantom_environment(),
            TokenType::MathTextStart => self.parse_text_in_math::<false>(),
            TokenType::FntParam if self.source.get_math_started() => {
                self.parse_text_in_math::<true>()
            }
            TokenType::MathTextEnd => Err(VestiErr::make_parse_err(
                VestiParseErrKind::IsNotOpenedErr {
                    open: vec![TokenType::MathTextStart],
                    close: TokenType::MathTextEnd,
                },
                self.peek_tok_location(),
            )),
            TokenType::MainVestiFile => {
                self.doc_state.prevent_end_doc = false;
                self.doc_state.doc_start = false;
                self.is_main_vesti = true;
                let loc = self.next_tok().span;
                expect_peek!(self: TokenType::Newline; loc);
                self.parse_statement()
            }
            TokenType::FunctionDef(kind) => self.parse_function_definition(kind),
            TokenType::EndDefinition => Err(VestiErr::make_parse_err(
                VestiParseErrKind::IsNotOpenedErr {
                    open: TokenType::get_definition_start_list(),
                    close: TokenType::EndDefinition,
                },
                self.peek_tok_location(),
            )),
            TokenType::Defenv | TokenType::Redefenv => self.parse_environment_definition(),
            TokenType::EndsWith => Err(VestiErr::make_parse_err(
                VestiParseErrKind::IsNotOpenedErr {
                    open: vec![TokenType::Defenv, TokenType::Redefenv],
                    close: TokenType::EndsWith,
                },
                self.peek_tok_location(),
            )),

            // Identifiers
            TokenType::LatexFunction => self.parse_latex_function(),
            TokenType::RawLatex => self.parse_raw_latex(),
            TokenType::Integer => self.parse_integer(),
            TokenType::Float => self.parse_float(),

            // Math related tokens
            TokenType::InlineMathStart | TokenType::DisplayMathStart => self.parse_math_stmt(),
            TokenType::Superscript | TokenType::Subscript if !self.is_math_mode() => {
                Err(VestiErr::make_parse_err(
                    VestiParseErrKind::IllegalUseErr {
                        got: self.peek_tok(),
                        reason: Some(ILLEGAL_USAGE_OF_SUPERSUB_SCRIPT),
                    },
                    self.peek_tok_location(),
                ))
            }
            TokenType::Lbrace => self.parse_brace_stmt(),

            TokenType::InlineMathEnd => Err(VestiErr::make_parse_err(
                VestiParseErrKind::InvalidTokToConvert {
                    got: TokenType::InlineMathEnd,
                },
                self.peek_tok_location(),
            )),
            TokenType::DisplayMathEnd => Err(VestiErr::make_parse_err(
                VestiParseErrKind::InvalidTokToConvert {
                    got: TokenType::DisplayMathEnd,
                },
                self.peek_tok_location(),
            )),

            // Math Brackets
            // NOTE: After v0.13.1, \left and \right bracket syntax is reversed.
            // if one want to use older compatibility, put -B flag on it.
            toktype if self.is_math_mode() && toktype.is_math_delimiter() => {
                if self.use_old_bracket {
                    self.parse_open_delimiter()
                } else {
                    self.parse_closed_delimiter()
                }
            }
            TokenType::Question if self.is_math_mode() => {
                if self.use_old_bracket {
                    self.parse_closed_delimiter()
                } else {
                    self.parse_open_delimiter()
                }
            }

            // TODO: warning if `valid_in_text` is true
            TokenType::Deprecated {
                valid_in_text,
                instead,
            } if !valid_in_text => Err(VestiErr::make_parse_err(
                VestiParseErrKind::DeprecatedUseErr {
                    instead: DeprecatedKind::InsteadTokenExist(instead),
                },
                self.peek_tok_location(),
            )),

            _ => self.parse_main_stmt(),
        }
    }

    fn parse_integer(&mut self) -> error::Result<Statement> {
        let curr_tok = self.next_tok();
        let output = if let Ok(int) = curr_tok.literal.parse() {
            int
        } else {
            return Err(VestiErr::make_parse_err(
                VestiParseErrKind::ParseIntErr,
                curr_tok.span,
            ));
        };

        Ok(Statement::Integer(output))
    }

    fn parse_float(&mut self) -> error::Result<Statement> {
        let curr_tok = self.next_tok();
        let output = if let Ok(float) = curr_tok.literal.parse() {
            float
        } else {
            return Err(VestiErr::make_parse_err(
                VestiParseErrKind::ParseFloatErr,
                curr_tok.span,
            ));
        };

        Ok(Statement::Float(output))
    }

    fn parse_raw_latex(&mut self) -> error::Result<Statement> {
        Ok(Statement::RawLatex(self.next_tok().literal))
    }

    fn parse_main_stmt(&mut self) -> error::Result<Statement> {
        if self.is_eof() {
            return Err(VestiErr::make_parse_err(
                VestiParseErrKind::EOFErr,
                self.peek_tok_location(),
            ));
        }
        let text = self.next_tok().literal;

        Ok(Statement::MainText(text))
    }

    fn parse_math_stmt(&mut self) -> error::Result<Statement> {
        let start_location = self.peek_tok_location();
        let mut text = Vec::with_capacity(20);
        let mut stmt;

        match self.peek_tok() {
            TokenType::InlineMathStart => {
                expect_peek!(self: TokenType::InlineMathStart; self.peek_tok_location());

                while self.peek_tok() != TokenType::InlineMathEnd {
                    stmt = match self.parse_statement() {
                        Ok(stmt) => stmt,
                        Err(VestiErr::ParseErr {
                            err_kind: VestiParseErrKind::EOFErr,
                            ..
                        }) => {
                            return Err(VestiErr::make_parse_err(
                                VestiParseErrKind::BracketMismatchErr {
                                    expected: TokenType::InlineMathEnd,
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
                    state: MathState::Text,
                    text,
                })
            }

            TokenType::DisplayMathStart => {
                expect_peek!(self: TokenType::DisplayMathStart; self.peek_tok_location());

                while self.peek_tok() != TokenType::DisplayMathEnd {
                    stmt = match self.parse_statement() {
                        Ok(stmt) => stmt,
                        Err(VestiErr::ParseErr {
                            err_kind: VestiParseErrKind::EOFErr,
                            ..
                        }) => {
                            return Err(VestiErr::make_parse_err(
                                VestiParseErrKind::BracketMismatchErr {
                                    expected: TokenType::InlineMathEnd,
                                },
                                start_location,
                            ));
                        }
                        Err(err) => return Err(err),
                    };
                    text.push(stmt);
                }

                expect_peek!(self: TokenType::DisplayMathEnd; self.peek_tok_location());
                Ok(Statement::MathText {
                    state: MathState::Inline,
                    text,
                })
            }

            TokenType::Eof => Err(VestiErr::make_parse_err(
                VestiParseErrKind::EOFErr,
                self.peek_tok_location(),
            )),

            toktype => Err(VestiErr::make_parse_err(
                VestiParseErrKind::TypeMismatch {
                    expected: vec![TokenType::InlineMathStart, TokenType::DisplayMathStart],
                    got: toktype,
                },
                self.peek_tok_location(),
            )),
        }
    }
    fn parse_open_delimiter(&mut self) -> error::Result<Statement> {
        if self.use_old_bracket {
            let delimiter = self.next_tok().literal;
            let kind: DelimiterKind = if self.peek_tok() == TokenType::Question {
                expect_peek!(self: TokenType::Question; self.peek_tok_location());
                DelimiterKind::LeftBig
            } else {
                DelimiterKind::Default
            };

            Ok(Statement::MathDelimiter { delimiter, kind })
        } else {
            if self.peek_tok().is_math_delimiter() {
                Ok(Statement::MathDelimiter {
                    delimiter: self.next_tok().literal,
                    kind: DelimiterKind::Default,
                })
            } else {
                expect_peek!(self: TokenType::Question; self.peek_tok_location());

                Ok(if self.peek_tok().is_math_delimiter() {
                    Statement::MathDelimiter {
                        delimiter: self.next_tok().literal,
                        kind: DelimiterKind::LeftBig,
                    }
                } else {
                    Statement::MainText(String::from("?"))
                })
            }
        }
    }

    fn parse_closed_delimiter(&mut self) -> error::Result<Statement> {
        if self.use_old_bracket {
            expect_peek!(self: TokenType::Question; self.peek_tok_location());

            Ok(if self.peek_tok().is_math_delimiter() {
                let delimiter = self.next_tok().literal;
                Statement::MathDelimiter {
                    delimiter,
                    kind: DelimiterKind::RightBig,
                }
            } else {
                Statement::MainText(String::from("!"))
            })
        } else {
            let delimiter = self.next_tok().literal;
            let kind: DelimiterKind = if self.peek_tok() == TokenType::Question {
                expect_peek!(self: TokenType::Question; self.peek_tok_location());
                DelimiterKind::RightBig
            } else {
                DelimiterKind::Default
            };

            Ok(Statement::MathDelimiter { delimiter, kind })
        }
    }

    fn parse_text_in_math<const REMOVE_FRONT_SPACE: bool>(&mut self) -> error::Result<Statement> {
        let mut remove_back_space = false;
        let mut text: Latex = Vec::with_capacity(20);

        if REMOVE_FRONT_SPACE {
            expect_peek!(self: TokenType::FntParam; self.peek_tok_location());
            if self.peek_tok() != TokenType::MathTextStart {
                return Err(VestiErr::make_parse_err(
                    VestiParseErrKind::BracketMismatchErr {
                        expected: TokenType::MathTextStart,
                    },
                    self.peek_tok_location(),
                ));
            }
        }

        // Since this is a text mod, turn off the math mode
        self.source.set_math_started(false);
        expect_peek!(self: TokenType::MathTextStart; self.peek_tok_location());

        while self.peek_tok() != TokenType::MathTextEnd {
            if self.is_eof() {
                return Err(VestiErr::make_parse_err(
                    VestiParseErrKind::BracketMismatchErr {
                        expected: TokenType::MathTextEnd,
                    },
                    self.peek_tok_location(),
                ));
            }
            text.push(self.parse_statement()?);
        }
        self.source.set_math_started(true);
        expect_peek!(self: TokenType::MathTextEnd; self.peek_tok_location());

        if self.peek_tok() == TokenType::FntParam {
            self.next_tok();
            remove_back_space = true;
        }

        Ok(Statement::PlainTextInMath {
            remove_front_space: REMOVE_FRONT_SPACE,
            remove_back_space,
            text,
        })
    }

    fn parse_brace_stmt(&mut self) -> error::Result<Statement> {
        let begin_location = self.peek_tok_location();
        expect_peek!(self: TokenType::Lbrace; begin_location);

        let mut is_fraction = false;
        let mut numerator: Latex = Vec::with_capacity(10);
        let mut denominator: Latex = Vec::with_capacity(10);
        loop {
            if self.peek_tok() == TokenType::Eof {
                break Err(VestiErr::ParseErr {
                    err_kind: VestiParseErrKind::EOFErr,
                    location: begin_location,
                });
            }
            if self.peek_tok() == TokenType::Rbrace {
                self.next_tok();
                break Ok(if is_fraction {
                    Statement::Fraction {
                        numerator,
                        denominator,
                    }
                } else {
                    Statement::BracedStmt(numerator)
                });
            }
            if self.peek_tok() == TokenType::FracDefiner {
                is_fraction = true;
                self.next_tok();
            }

            if is_fraction {
                denominator.push(self.parse_statement()?);
            } else {
                numerator.push(self.parse_statement()?);
            }
        }
    }

    fn parse_docclass(&mut self) -> error::Result<Statement> {
        let mut options: Option<Vec<Latex>> = None;

        expect_peek!(self: TokenType::Docclass; self.peek_tok_location());
        self.eat_whitespaces::<false>();

        take_name!(let name: String = self);

        self.parse_comma_args(&mut options)?;
        if self.peek_tok() == TokenType::Newline {
            self.next_tok();
        }

        Ok(Statement::DocumentClass { name, options })
    }

    fn parse_usepackage(&mut self) -> error::Result<Statement> {
        expect_peek!(self: TokenType::ImportPkg; self.peek_tok_location());
        self.eat_whitespaces::<false>();

        if self.peek_tok() == TokenType::Lbrace {
            return self.parse_multiple_usepackages();
        }

        let mut options: Option<Vec<Latex>> = None;
        take_name!(let name: String = self);

        self.parse_comma_args(&mut options)?;
        if self.peek_tok() == TokenType::Newline {
            self.next_tok();
        }

        Ok(Statement::Usepackage { name, options })
    }

    fn parse_multiple_usepackages(&mut self) -> error::Result<Statement> {
        let mut pkgs: Vec<Statement> = Vec::with_capacity(10);

        expect_peek!(self: TokenType::Lbrace; self.peek_tok_location());
        self.eat_whitespaces::<true>();

        while self.peek_tok() != TokenType::Rbrace {
            let mut options: Option<Vec<Latex>> = None;
            take_name!(let name: String = self);

            self.parse_comma_args(&mut options)?;
            self.eat_whitespaces::<true>();

            match self.peek_tok() {
                TokenType::Comma => {
                    self.next_tok();
                    self.eat_whitespaces::<true>();
                    if self.peek_tok() == TokenType::Rbrace {
                        pkgs.push(Statement::Usepackage { name, options });
                        break;
                    }
                }
                TokenType::Rbrace => {
                    pkgs.push(Statement::Usepackage { name, options });
                    break;
                }
                TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::EOFErr,
                        self.peek_tok_location(),
                    ));
                }
                tok_type => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::TypeMismatch {
                            expected: vec![TokenType::Comma, TokenType::Rbrace],
                            got: tok_type,
                        },
                        self.peek_tok_location(),
                    ));
                }
            }

            pkgs.push(Statement::Usepackage { name, options });
        }

        expect_peek!(self: TokenType::Rbrace; self.peek_tok_location());

        self.eat_whitespaces::<false>();
        if self.peek_tok() == TokenType::Newline {
            self.next_tok();
        }

        Ok(Statement::MultiUsepackages { pkgs })
    }

    fn parse_import_vesti(&mut self) -> error::Result<Statement> {
        expect_peek!(self: TokenType::ImportVesti; self.peek_tok_location());
        self.eat_whitespaces::<false>();

        let mut file_path_str = String::with_capacity(30);

        // Parse vesti contents within verbatim
        self.source.switch_lex_with_verbatim();
        expect_peek!(self: TokenType::Lparen; self.peek_tok_location());
        assert!(matches!(self.peek_tok.toktype, TokenType::VerbatimChar(_)));

        loop {
            let chr = match self.peek_tok() {
                TokenType::VerbatimChar(')') => break,
                TokenType::VerbatimChar(chr) => chr,
                TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::EOFErr,
                        self.peek_tok_location(),
                    ))
                }
                _ => unreachable!(),
            };

            file_path_str.push(chr);
            self.next_tok();
        }
        // Release verbatim mode
        self.source.switch_lex_with_verbatim();
        self.next_tok();

        self.eat_whitespaces::<false>();
        if self.peek_tok() == TokenType::Newline {
            self.next_tok();
        }

        // trim whitespaces
        file_path_str = String::from(file_path_str.trim());

        // get the absolute path
        // TODO: fs::canonicalize returns error when there is no such path for
        // `file_path_str`. But vesti's error message is so ambiguous to recognize
        // whether error occurs at here. Make a new error variant to handle this.
        let file_path = fs::canonicalize(file_path_str)?;

        // name mangling process
        let mut hasher = Md5::new();
        hasher.update(file_path.into_os_string().into_encoded_bytes());
        let hash = hasher.finalize();
        let base64_hash = Base64Url::encode_string(&hash);

        let mut filename = PathBuf::with_capacity(30);
        filename.push(format!("@vesti__{}.tex", base64_hash));

        Ok(Statement::ImportVesti { filename })
    }

    fn parse_filename_helper(
        &mut self,
        import_file_loc: Span,
    ) -> error::Result<(String, OsString)> {
        let mut file_path_str = String::with_capacity(30);

        // Parse vesti contents within verbatim
        self.source.switch_lex_with_verbatim();
        expect_peek!(self: TokenType::Lparen; self.peek_tok_location());
        assert!(matches!(self.peek_tok.toktype, TokenType::VerbatimChar(_)));

        let mut inside_config_dir = false;
        let mut parse_very_first_chr = false;
        loop {
            let chr = match self.peek_tok() {
                TokenType::VerbatimChar(')') => break,
                TokenType::VerbatimChar('@') => {
                    if !parse_very_first_chr {
                        inside_config_dir = true;
                        self.next_tok();

                        if self.peek_tok() != TokenType::VerbatimChar('/') {
                            return Err(VestiErr::make_parse_err(
                                VestiParseErrKind::IllegalUseErr {
                                    got: TokenType::FilePath,
                                    reason: Some("The next token for `@` should be `/`."),
                                },
                                import_file_loc,
                            ));
                        }
                        continue;
                    } else {
                        '@'
                    }
                }
                TokenType::VerbatimChar(chr) => chr,
                TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::EOFErr,
                        self.peek_tok_location(),
                    ));
                }
                _ => unreachable!(),
            };

            // as we just parse at least one character, in here, it should set with true value
            parse_very_first_chr = true;

            file_path_str.push(chr);
            self.next_tok();
        }
        // Release verbatim mode
        self.source.switch_lex_with_verbatim();
        self.next_tok();

        self.eat_whitespaces::<false>();
        if self.peek_tok() == TokenType::Newline {
            self.next_tok();
        }

        // trim whitespaces
        file_path_str = if inside_config_dir {
            format!(
                "{}/vesti{}",
                dirs::config_dir()
                    .expect("failed to get a config directory for this OS.")
                    .display(),
                file_path_str.trim()
            )
        } else {
            format!("./{}", file_path_str.trim())
        };

        let raw_filename_pathbuf = PathBuf::from(&file_path_str);

        Ok((
            file_path_str,
            raw_filename_pathbuf.file_name().unwrap().to_os_string(),
        ))
    }

    fn parse_file_path(&mut self) -> error::Result<Statement> {
        let import_file_loc = self.peek_tok_location();
        expect_peek!(self: TokenType::FilePath; import_file_loc);
        self.eat_whitespaces::<false>();

        let (file_path_str, _) = self.parse_filename_helper(import_file_loc)?;
        let filepath_diff =
            pathdiff::diff_paths(file_path_str, constants::VESTI_LOCAL_DUMMY_DIR).unwrap();
        Ok(Statement::FilePath {
            filename: PathBuf::from(filepath_diff.to_slash().unwrap().into_owned()),
        })
    }

    fn parse_import_file(&mut self) -> error::Result<Statement> {
        let import_file_loc = self.peek_tok_location();
        expect_peek!(self: TokenType::ImportFile; import_file_loc);
        if self.peek_tok() == TokenType::Star {
            return Err(VestiErr::make_parse_err(
                VestiParseErrKind::DeprecatedUseErr {
                    instead: DeprecatedKind::OtherExplanation("remove this star"),
                },
                self.peek_tok_location(),
            ));
        }
        self.eat_whitespaces::<false>();

        let (file_path_str, raw_filename) = self.parse_filename_helper(import_file_loc)?;

        fs::copy(
            file_path_str,
            format!(
                "{}/{}",
                constants::VESTI_LOCAL_DUMMY_DIR,
                raw_filename.to_string_lossy()
            ),
        )?;

        Ok(Statement::NopStmt)
    }

    fn parse_import_module(&mut self) -> error::Result<Statement> {
        let import_module_loc = self.peek_tok_location();
        expect_peek!(self: TokenType::ImportModule; import_module_loc);
        self.eat_whitespaces::<false>();

        let mut mod_dir_path_str = String::with_capacity(30);

        // Parse vesti contents within verbatim
        self.source.switch_lex_with_verbatim();
        expect_peek!(self: TokenType::Lparen; self.peek_tok_location());
        assert!(matches!(self.peek_tok.toktype, TokenType::VerbatimChar(_)));

        loop {
            let chr = match self.peek_tok() {
                TokenType::VerbatimChar(')') => break,
                TokenType::VerbatimChar(chr) => chr,
                TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::EOFErr,
                        self.peek_tok_location(),
                    ));
                }
                _ => unreachable!(),
            };

            mod_dir_path_str.push(chr);
            self.next_tok();
        }
        // Release verbatim mode
        self.source.switch_lex_with_verbatim();
        self.next_tok();

        self.eat_whitespaces::<false>();
        if self.peek_tok() == TokenType::Newline {
            self.next_tok();
        }

        // trim whitespaces
        let mod_dir_path_str = format!(
            "{}/vesti/{}",
            dirs::config_dir()
                .expect("failed to get a config directory for this OS.")
                .display(),
            mod_dir_path_str.trim().trim_start_matches('/')
        );

        let module_data_pathbuf = PathBuf::from(format!("{}/vesti.ron", &mod_dir_path_str));

        let contents = fs::read_to_string(module_data_pathbuf)?;
        let ves_module = match ron::from_str::<VestiModule>(&contents) {
            Ok(ves_mod) => ves_mod,
            Err(err) => {
                return Err(VestiErr::ParseErr {
                    err_kind: VestiParseErrKind::ParseModuleRonErr(err),
                    location: import_module_loc,
                })
            }
        };

        for export_file in ves_module.exports {
            let mod_filename = format!("{}/{}", &mod_dir_path_str, &export_file);

            fs::copy(
                &mod_filename,
                format!("{}/{}", constants::VESTI_LOCAL_DUMMY_DIR, export_file),
            )?;
        }

        Ok(Statement::NopStmt)
    }

    fn parse_end_phantom_environment(&mut self) -> error::Result<Statement> {
        let endenv_location = self.peek_tok_location();
        expect_peek!(self: TokenType::Endenv; self.peek_tok_location());
        self.eat_whitespaces::<false>();

        let mut name = match self.peek_tok() {
            TokenType::Text => self.next_tok().literal,
            TokenType::Eof => {
                return Err(VestiErr::ParseErr {
                    err_kind: VestiParseErrKind::EOFErr,
                    location: endenv_location,
                });
            }
            _ => {
                return Err(VestiErr::make_parse_err(
                    VestiParseErrKind::NameMissErr {
                        r#type: TokenType::Endenv,
                    },
                    endenv_location,
                ));
            }
        };
        while self.peek_tok() == TokenType::Star {
            expect_peek!(self: TokenType::Star; self.peek_tok_location());
            name.push('*');
        }
        self.eat_whitespaces::<false>();

        Ok(Statement::EndPhantomEnvironment { name })
    }

    fn parse_environment<const IS_REAL: bool>(&mut self) -> error::Result<Statement> {
        let begenv_location = self.peek_tok_location();
        let mut off_math_state = false;
        let mut add_newline = false;

        if IS_REAL {
            expect_peek!(self: TokenType::Useenv; self.peek_tok_location());
        } else {
            expect_peek!(self: TokenType::Begenv; self.peek_tok_location());
            if self.peek_tok() == TokenType::Star {
                expect_peek!(self: TokenType::Star; self.peek_tok_location());
                add_newline = true;
            }
        }
        self.eat_whitespaces::<false>();

        let mut name = match self.peek_tok() {
            TokenType::Text => self.next_tok().literal,
            TokenType::Eof => {
                if IS_REAL {
                    return Err(VestiErr::ParseErr {
                        err_kind: VestiParseErrKind::NameMissErr {
                            r#type: TokenType::Useenv,
                        },
                        location: begenv_location,
                    });
                } else {
                    return Err(VestiErr::ParseErr {
                        err_kind: if IS_REAL {
                            VestiParseErrKind::IsNotClosedErr {
                                open: vec![TokenType::Begenv],
                                close: TokenType::Endenv,
                            }
                        } else {
                            VestiParseErrKind::EOFErr
                        },
                        location: begenv_location,
                    });
                }
            }
            _ => {
                return Err(VestiErr::make_parse_err(
                    VestiParseErrKind::NameMissErr {
                        r#type: TokenType::Begenv,
                    },
                    begenv_location,
                ));
            }
        };

        // If name is math related one, then math mode will be turn on
        if ENV_MATH_IDENT.contains(&name.as_str()) {
            self.source.set_math_started(true);
            off_math_state = true;
        }

        while self.peek_tok() == TokenType::Star {
            expect_peek!(self: TokenType::Star; self.peek_tok_location());
            name.push('*');
        }
        self.eat_whitespaces::<false>();

        let args = self.parse_function_args(
            TokenType::Lparen,
            TokenType::Rparen,
            TokenType::Lsqbrace,
            TokenType::Rsqbrace,
        )?;

        let mut text = MaybeUninit::<Latex>::uninit();
        if IS_REAL {
            self.eat_whitespaces::<false>();
            expect_peek!(self: TokenType::Lbrace; self.peek_tok_location());
            let text_ref = text.write(Vec::with_capacity(32));
            while self.peek_tok() != TokenType::Rbrace {
                if self.is_eof() {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::IsNotClosedErr {
                            open: vec![TokenType::Lbrace],
                            close: TokenType::Rbrace,
                        },
                        begenv_location,
                    ));
                }
                text_ref.push(self.parse_statement()?);
            }
            expect_peek!(self: TokenType::Rbrace; self.peek_tok_location());
        }

        // If name is math related one, then math mode will be turn off
        if off_math_state {
            self.source.set_math_started(false);
        }
        if self.peek_tok() == TokenType::Newline {
            self.next_tok();
        }

        if IS_REAL {
            // SAFETY: We know that text is initialized at the same if branch, and IS_REAL can be
            // determined only at the compile time
            Ok(Statement::Environment {
                name,
                args,
                text: unsafe { text.assume_init() },
            })
        } else {
            Ok(Statement::BeginPhantomEnvironment {
                name,
                args,
                add_newline,
            })
        }
    }

    fn parse_function_definition(&mut self, kind: FunctionDefKind) -> error::Result<Statement> {
        let begfntdef_location = self.peek_tok_location();
        let mut trim = TrimWhitespace {
            start: true,
            mid: None,
            end: true,
        };

        expect_peek!(self: TokenType::FunctionDef(kind); self.peek_tok_location());

        if self.peek_tok() == TokenType::Star {
            expect_peek!(self: TokenType::Star; self.peek_tok_location());
            trim.start = false;
        }
        self.eat_whitespaces::<false>();

        if self.is_eof() {
            return Err(VestiErr::ParseErr {
                err_kind: VestiParseErrKind::IsNotClosedErr {
                    open: vec![TokenType::FunctionDef(kind)],
                    close: TokenType::EndDefinition,
                },
                location: begfntdef_location,
            });
        }

        let mut name = String::with_capacity(16);
        loop {
            name.push_str(
                match self.peek_tok() {
                    TokenType::Text | TokenType::Subscript => self.next_tok().literal,
                    TokenType::Space | TokenType::Tab | TokenType::Newline | TokenType::Lparen => {
                        break
                    }
                    TokenType::Eof => {
                        return Err(VestiErr::make_parse_err(
                            VestiParseErrKind::EOFErr,
                            begfntdef_location,
                        ));
                    }
                    _ => {
                        return Err(VestiErr::make_parse_err(
                            VestiParseErrKind::NameMissErr {
                                r#type: TokenType::FunctionDef(kind),
                            },
                            begfntdef_location,
                        ));
                    }
                }
                .as_str(),
            );
        }
        name = name.replace('_', "@");
        self.eat_whitespaces::<false>();

        let args = self.parse_function_definition_argument()?;

        let body = self.parse_function_definebody(begfntdef_location, kind)?;
        expect_peek!(self: TokenType::EndDefinition; self.peek_tok_location());

        if self.peek_tok() == TokenType::Star {
            expect_peek!(self: TokenType::Star; self.peek_tok_location());
            trim.end = false;
        }

        if self.peek_tok() == TokenType::Newline {
            self.next_tok();
        }
        Ok(Statement::FunctionDefine {
            kind,
            name,
            args,
            trim,
            body,
        })
    }

    fn parse_environment_definition(&mut self) -> error::Result<Statement> {
        let begenvdef_location = self.peek_tok_location();
        let mut trim = TrimWhitespace {
            start: true,
            mid: Some(true),
            end: true,
        };

        let (is_redefine, beg_toktype) = match self.peek_tok() {
            TokenType::Eof => {
                return Err(VestiErr::ParseErr {
                    err_kind: VestiParseErrKind::EOFErr,
                    location: begenvdef_location,
                })
            }
            TokenType::Defenv => (false, TokenType::Defenv),
            TokenType::Redefenv => (true, TokenType::Redefenv),
            got => {
                return Err(VestiErr::ParseErr {
                    err_kind: VestiParseErrKind::TypeMismatch {
                        expected: vec![TokenType::Defenv, TokenType::Redefenv],
                        got,
                    },
                    location: begenvdef_location,
                })
            }
        };
        expect_peek!(self: beg_toktype; self.peek_tok_location());

        if self.peek_tok() == TokenType::Star {
            expect_peek!(self: TokenType::Star; self.peek_tok_location());
            trim.start = false;
        }
        self.eat_whitespaces::<false>();

        if self.is_eof() {
            return Err(VestiErr::ParseErr {
                err_kind: VestiParseErrKind::IsNotClosedErr {
                    open: vec![beg_toktype],
                    close: TokenType::EndsWith,
                },
                location: begenvdef_location,
            });
        }

        let mut name = String::new();
        loop {
            name.push_str(
                match self.peek_tok() {
                    TokenType::Text | TokenType::At => self.next_tok().literal,
                    TokenType::Space
                    | TokenType::Tab
                    | TokenType::Newline
                    | TokenType::Lsqbrace => break,
                    TokenType::Eof => {
                        return Err(VestiErr::make_parse_err(
                            VestiParseErrKind::EOFErr,
                            begenvdef_location,
                        ));
                    }
                    _ => {
                        return Err(VestiErr::make_parse_err(
                            VestiParseErrKind::NameMissErr {
                                r#type: beg_toktype,
                            },
                            begenvdef_location,
                        ));
                    }
                }
                .as_str(),
            );
        }
        self.eat_whitespaces::<false>();

        let (args_num, optional_arg) = if self.peek_tok() == TokenType::Lsqbrace {
            expect_peek!(self: TokenType::Lsqbrace; self.peek_tok_location());
            let tmp_argnum = match self.peek_tok() {
                TokenType::Integer => {
                    let lex_token = self.next_tok();
                    if let Ok(num) = lex_token.literal.parse::<u8>() {
                        num
                    } else {
                        return Err(VestiErr::make_parse_err(
                            VestiParseErrKind::ParseIntErr,
                            lex_token.span,
                        ));
                    }
                }
                TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::EOFErr,
                        begenvdef_location,
                    ));
                }
                got => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::TypeMismatch {
                            expected: vec![TokenType::Integer],
                            got,
                        },
                        self.peek_tok_location(),
                    ))
                }
            };

            match self.peek_tok() {
                TokenType::Comma => {
                    expect_peek!(self: TokenType::Comma; self.peek_tok_location());
                    if self.peek_tok() == TokenType::Space {
                        self.next_tok();
                    }
                    let mut tmp_inner: Latex = Vec::with_capacity(20);
                    while self.peek_tok() != TokenType::Rsqbrace {
                        if self.is_eof() {
                            return Err(VestiErr::make_parse_err(
                                VestiParseErrKind::EOFErr,
                                begenvdef_location,
                            ));
                        }
                        tmp_inner.push(self.parse_statement()?);
                    }
                    expect_peek!(self: TokenType::Rsqbrace; self.peek_tok_location());

                    (tmp_argnum, Some(tmp_inner))
                }
                TokenType::Rsqbrace => {
                    expect_peek!(self: TokenType::Rsqbrace; self.peek_tok_location());
                    (tmp_argnum, None)
                }
                TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::EOFErr,
                        begenvdef_location,
                    ));
                }
                got => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::TypeMismatch {
                            expected: vec![TokenType::Rsqbrace, TokenType::Comma],
                            got,
                        },
                        self.peek_tok_location(),
                    ))
                }
            }
        } else {
            (0, None)
        };

        let mut begin_part = Vec::with_capacity(20);
        loop {
            match self.peek_tok() {
                TokenType::Defenv | TokenType::Redefenv => {
                    begin_part.push(self.parse_environment_definition()?)
                }
                TokenType::EndsWith => break,
                TokenType::EndDefinition | TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::IsNotClosedErr {
                            open: vec![TokenType::Defenv, TokenType::Redefenv],
                            close: TokenType::EndsWith,
                        },
                        begenvdef_location,
                    ));
                }
                _ => {
                    self.doc_state.parsing_define = true;
                    begin_part.push(self.parse_statement()?);
                    self.doc_state.parsing_define = false;
                }
            }
        }
        let midenvdef_location = self.peek_tok_location();

        expect_peek!(self: TokenType::EndsWith; self.peek_tok_location());
        if self.peek_tok() == TokenType::Star {
            expect_peek!(self: TokenType::Star; self.peek_tok_location());
            trim.mid = Some(false);
        }

        let mut end_part = Vec::with_capacity(20);
        loop {
            match self.peek_tok() {
                TokenType::Defenv | TokenType::Redefenv => {
                    end_part.push(self.parse_environment_definition()?)
                }
                TokenType::EndDefinition => break,
                TokenType::EndsWith | TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::IsNotClosedErr {
                            open: vec![TokenType::EndsWith],
                            close: TokenType::EndDefinition,
                        },
                        midenvdef_location,
                    ));
                }
                _ => {
                    self.doc_state.parsing_define = true;
                    end_part.push(self.parse_statement()?);
                    self.doc_state.parsing_define = false;
                }
            }
        }
        expect_peek!(self: TokenType::EndDefinition; self.peek_tok_location());
        if self.peek_tok() == TokenType::Star {
            expect_peek!(self: TokenType::Star; self.peek_tok_location());
            trim.end = false;
        }
        if self.peek_tok() == TokenType::Newline {
            self.next_tok();
        }
        Ok(Statement::EnvironmentDefine {
            is_redefine,
            name,
            args_num,
            optional_arg,
            trim,
            begin_part,
            end_part,
        })
    }

    fn parse_latex_function(&mut self) -> error::Result<Statement> {
        let name = if self.is_eof() {
            return Err(VestiErr::ParseErr {
                err_kind: VestiParseErrKind::EOFErr,
                location: self.peek_tok_location(),
            });
        } else {
            self.next_tok().literal
        };

        let args = self.parse_function_args(
            TokenType::Lbrace,
            TokenType::Rbrace,
            TokenType::Lsqbrace,
            TokenType::Rsqbrace,
        )?;

        Ok(Statement::LatexFunction { name, args })
    }

    fn parse_function_definition_argument(&mut self) -> error::Result<String> {
        let open_brace_location = self.peek_tok_location();
        let mut output = String::new();
        let mut parenthesis_level = 0;
        let mut is_first_token = true;

        expect_peek!(self: TokenType::Lparen; open_brace_location);
        while !self.is_eof() && parenthesis_level >= 0 {
            match self.peek_tok() {
                TokenType::Lparen => parenthesis_level += 1,
                TokenType::Rparen => {
                    parenthesis_level -= 1;
                    if parenthesis_level < 0 {
                        break;
                    }
                }
                TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::BracketNumberMatchedErr,
                        open_brace_location,
                    ))
                }
                _ => {}
            }

            if is_first_token
                && (self.peek_tok() == TokenType::Text
                    || self.peek_tok().is_deprecated()
                    || self.peek_tok().is_keyword())
            {
                output.push(' ');
            }
            is_first_token = false;

            output.push_str(self.next_tok().literal.as_str());
        }
        expect_peek!(self: TokenType::Rparen; open_brace_location);

        Ok(output)
    }

    fn parse_function_definebody(
        &mut self,
        begdef_location: Span,
        kind: FunctionDefKind,
    ) -> error::Result<Latex> {
        let mut body: Latex = Vec::with_capacity(64);
        let mut def_level = 0;
        while self.peek_tok() != TokenType::EndDefinition && def_level >= 0 {
            match self.peek_tok() {
                TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::IsNotClosedErr {
                            open: vec![TokenType::FunctionDef(kind)],
                            close: TokenType::EndDefinition,
                        },
                        begdef_location,
                    ));
                }
                TokenType::FunctionDef(_) => def_level += 1,
                TokenType::EndDefinition => {
                    def_level -= 1;
                    if def_level < 0 {
                        break;
                    }
                }
                _ => {}
            }
            self.doc_state.parsing_define = true;
            body.push(self.parse_statement()?);
            self.doc_state.parsing_define = false;
        }

        Ok(body)
    }

    fn parse_comma_args(&mut self, options: &mut Option<Vec<Latex>>) -> error::Result<()> {
        self.eat_whitespaces::<false>();
        if self.peek_tok() == TokenType::Lparen {
            let mut options_vec: Vec<Latex> = Vec::new();
            // Since we yet tell to the computer to get the next token,
            // peeking the token location is the location of the open brace one.
            let open_brace_location = self.peek_tok_location();
            self.next_tok();
            self.eat_whitespaces::<true>();

            while self.peek_tok() != TokenType::Rparen {
                if self.is_eof() {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::BracketNumberMatchedErr,
                        open_brace_location,
                    ));
                }

                self.eat_whitespaces::<true>();
                let mut tmp: Latex = Vec::new();

                while self.peek_tok() != TokenType::Comma {
                    self.eat_whitespaces::<true>();
                    if self.is_eof() {
                        return Err(VestiErr::make_parse_err(
                            VestiParseErrKind::BracketNumberMatchedErr,
                            open_brace_location,
                        ));
                    }
                    if self.peek_tok() == TokenType::Rparen {
                        break;
                    }
                    tmp.push(self.parse_statement()?);
                }

                options_vec.push(tmp);
                self.eat_whitespaces::<true>();

                if self.peek_tok() == TokenType::Rparen {
                    break;
                }

                expect_peek!(self: TokenType::Comma; self.peek_tok_location());
                self.eat_whitespaces::<true>();
            }

            expect_peek!(self: TokenType::Rparen; self.peek_tok_location());
            self.eat_whitespaces::<false>();
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

        if self.peek_tok() == open
            || self.peek_tok() == optional_open
            || self.peek_tok() == TokenType::Star
        {
            loop {
                match self.peek_tok() {
                    toktype if toktype == open => {
                        self.parse_function_args_core(&mut args, open, closed, ArgNeed::MainArg)?
                    }

                    toktype if toktype == optional_open => self.parse_function_args_core(
                        &mut args,
                        optional_open,
                        optional_closed,
                        ArgNeed::Optional,
                    )?,

                    TokenType::Star => {
                        expect_peek!(self: TokenType::Star; self.peek_tok_location());
                        args.push((ArgNeed::StarArg, Vec::new()));
                    }

                    _ => break,
                }

                if let TokenType::Eof | TokenType::Newline = self.peek_tok() {
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
        expect_peek!(self: open; open_brace_location);

        let mut tmp_vec: Vec<Statement> = Vec::new();
        while self.peek_tok() != closed {
            if self.is_eof() {
                return Err(VestiErr::make_parse_err(
                    VestiParseErrKind::BracketNumberMatchedErr,
                    open_brace_location,
                ));
            }
            let stmt = self.parse_statement()?;
            tmp_vec.push(stmt);
        }

        expect_peek!(self: closed; self.peek_tok_location());
        args.push((arg_need, tmp_vec));

        Ok(())
    }
}

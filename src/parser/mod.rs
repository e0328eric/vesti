pub mod ast;
mod builtins;
pub mod defkind;
mod parser_impl;
pub mod preprocessor;

#[cfg(test)]
mod parser_test;

use std::borrow::Cow;

use crate::diagnostic::{Diagnostic, ParseErrorInfo};
use crate::lexer::token::{Token, TokenType};
use ast::Stmt;
use preprocessor::{PreprocessError, Preprocessor, TokenList};

pub const MAX_BEGENV_NUM: usize = 64;

/// Directory name where vesti writes generated `.tex` files.
pub const VESTI_DUMMY_DIR: &str = ".vesti-dummy";

#[derive(Debug)]
pub enum ParseError {
    ParseFailed,
    Preprocess(PreprocessError),
}

impl From<PreprocessError> for ParseError {
    fn from(e: PreprocessError) -> Self {
        ParseError::Preprocess(e)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Deserialize)]
pub enum LatexEngine {
    Latex,
    PdfLatex,
    XeLatex,
    LuaLatex,
    #[cfg(feature = "tectonic-backend")]
    Tectonic,
}

impl LatexEngine {
    pub fn to_str(self) -> &'static str {
        match self {
            LatexEngine::Latex => "latex",
            LatexEngine::PdfLatex => "pdflatex",
            LatexEngine::XeLatex => "xelatex",
            LatexEngine::LuaLatex => "lualatex",
            #[cfg(feature = "tectonic-backend")]
            LatexEngine::Tectonic => "tectonic",
        }
    }
}

pub(crate) fn env_math_ident(name: &str) -> bool {
    matches!(
        name,
        "equation" | "align" | "array" | "eqnarray" | "gather" | "multline"
    )
}

pub(crate) fn compile_type(name: &str) -> Option<LatexEngine> {
    Some(match name {
        "plain" => LatexEngine::Latex,
        "pdf" => LatexEngine::PdfLatex,
        "xe" => LatexEngine::XeLatex,
        "lua" => LatexEngine::LuaLatex,
        #[cfg(feature = "tectonic-backend")]
        "tect" => LatexEngine::Tectonic,
        _ => return None,
    })
}

#[derive(Clone, Copy)]
pub(crate) struct ParserState {
    pub xparse_defun: bool,
    pub doc_start: bool,
    pub prevent_end_doc: bool,
    pub parsing_define: bool,
    pub math_mode: bool,
}

impl Default for ParserState {
    fn default() -> Self {
        ParserState {
            xparse_defun: true,
            doc_start: false,
            prevent_end_doc: false,
            parsing_define: false,
            math_mode: false,
        }
    }
}

#[derive(Clone, Copy)]
pub struct ParserAllows {
    pub luacode: bool,
    pub global_def: bool,
    pub is_main: bool,
    pub change_engine: bool,
}

impl Default for ParserAllows {
    fn default() -> Self {
        ParserAllows {
            luacode: false,
            global_def: false,
            is_main: false,
            change_engine: true,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Which {
    Current,
    Peek,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum DefKind {
    Fnt,
    Env,
}

pub struct Parser<'s, 'd> {
    pub(crate) diagnostic: &'d mut Diagnostic<'s>,
    pub(crate) tok_list: TokenList<'s>,
    pub(crate) tok_idx: usize,
    pub(crate) parse_finished: bool,
    pub(crate) current_engine: LatexEngine,
    pub(crate) engine_slot: Option<LatexEngine>,
    pub(crate) allows: ParserAllows,
    pub(crate) doc_state: ParserState,
    pub(crate) enum_depth: u8,
    pub(crate) endenv_stack: Vec<&'s str>,
}

impl<'s, 'd> Parser<'s, 'd> {
    /// `engine` is `(slot, default)`: `slot` is `Some` when `#engine_type` may
    /// change the engine, `None` to disallow it. `default` is the starting
    /// engine when `slot` is `None`.
    pub fn new(
        source: &'s str,
        diagnostic: &'d mut Diagnostic<'s>,
        allows: ParserAllows,
        engine: (Option<LatexEngine>, LatexEngine),
    ) -> Result<Self, ParseError> {
        let tok_list = {
            let pp = Preprocessor::new(source, diagnostic);
            pp.preprocess()?
        };

        let (engine_slot, current_engine) = match engine.0 {
            Some(e) => (Some(e), e),
            None => (None, engine.1),
        };

        Ok(Parser {
            diagnostic,
            tok_list,
            tok_idx: 0,
            parse_finished: false,
            current_engine,
            engine_slot,
            allows,
            doc_state: ParserState::default(),
            enum_depth: 0,
            endenv_stack: Vec::new(),
        })
    }

    pub fn current_engine(&self) -> LatexEngine {
        self.current_engine
    }

    pub fn parse(&mut self) -> Result<Vec<Stmt<'s>>, ParseError> {
        let mut stmts: Vec<Stmt<'s>> = Vec::with_capacity(100);
        while !self.parse_finished {
            let stmt = self.parse_statement_entry()?;
            stmts.push(stmt);
            self.next_token();
        }
        if self.doc_state.doc_start && !self.doc_state.prevent_end_doc {
            stmts.push(Stmt::DocumentEnd);
        }
        Ok(stmts)
    }

    pub(crate) fn is_premiere(&self) -> bool {
        !self.doc_state.doc_start && !self.doc_state.parsing_define
    }

    pub(crate) fn next_token(&mut self) {
        if self.tok_idx + 1 < self.tok_list.len() {
            self.tok_idx += 1;
        } else {
            self.parse_finished = true;
        }
    }

    #[inline]
    pub(crate) fn get_tok(&self, which: Which) -> &Token<'s> {
        let idx = match which {
            Which::Current => self.tok_idx,
            Which::Peek => (self.tok_idx + 1).min(self.tok_list.len() - 1),
        };
        &self.tok_list[idx]
    }

    #[inline]
    pub(crate) fn curr_toktype(&self) -> TokenType<'s> {
        self.get_tok(Which::Current).toktype()
    }

    #[inline]
    pub(crate) fn peek_toktype(&self) -> TokenType<'s> {
        self.get_tok(Which::Peek).toktype()
    }

    pub(crate) fn expect(&self, which: Which, toktypes: &[TokenType<'_>]) -> bool {
        let tt = match which {
            Which::Current => self.curr_toktype(),
            Which::Peek => self.peek_toktype(),
        };
        toktypes.iter().any(|t| toktype_eq(&tt, t))
    }

    pub(crate) fn expect_remain(&mut self, token: TokenType<'static>) -> Result<(), ParseError> {
        if !self.expect(Which::Current, &[token]) {
            let span = self.get_tok(Which::Current).span();
            let obtained = self.curr_toktype();
            self.diagnostic.set_parse_error(
                ParseErrorInfo::TokenExpected {
                    expected: token_expected_slice(token),
                    obtained: Some(obtained),
                },
                Some(span),
            );
            return Err(ParseError::ParseFailed);
        }
        Ok(())
    }

    pub(crate) fn expect_eat(
        &mut self,
        token: TokenType<'static>,
    ) -> Result<Token<'s>, ParseError> {
        self.expect_remain(token)?;
        let curr = self.get_tok(Which::Current).clone();
        self.next_token();
        Ok(curr)
    }

    pub(crate) fn eat_whitespaces(&mut self, handle_newline: bool) {
        while self.expect(Which::Current, &[TokenType::Space, TokenType::Tab])
            || (handle_newline && self.expect(Which::Current, &[TokenType::Newline]))
        {
            self.next_token();
        }
    }

    pub(super) fn parse_statement_entry(&mut self) -> Result<Stmt<'s>, ParseError> {
        match self.curr_toktype() {
            TokenType::BuiltinFunction(builtin_fnt) => self.parse_builtins(builtin_fnt),
            TokenType::Docclass => {
                if self.is_premiere() {
                    self.parse_docclass()
                } else {
                    Ok(self.parse_literal())
                }
            }
            TokenType::ImportPkg => {
                if self.is_premiere() {
                    self.parse_single_pkg()
                } else {
                    Ok(self.parse_literal())
                }
            }
            TokenType::StartDoc => {
                if self.is_premiere() {
                    self.doc_state.doc_start = true;
                    Ok(Stmt::DocumentStart)
                } else {
                    Ok(self.parse_literal())
                }
            }
            TokenType::InlineMathSwitch | TokenType::DisplayMathSwitch => {
                if !self.doc_state.math_mode {
                    self.doc_state.math_mode = true;
                    self.parse_math_stmt()
                } else {
                    let span = self.get_tok(Which::Current).span();
                    self.diagnostic.set_parse_error(
                        ParseErrorInfo::IllegalUseErr("math block is not properly closed"),
                        Some(span),
                    );
                    Err(ParseError::ParseFailed)
                }
            }
            TokenType::DisplayMathStart => {
                self.doc_state.math_mode = true;
                self.parse_math_stmt()
            }
            TokenType::DisplayMathEnd => {
                let span = self.get_tok(Which::Current).span();
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::IllegalUseErr("math block is not properly closed"),
                    Some(span),
                );
                Err(ParseError::ParseFailed)
            }
            TokenType::Question => {
                if self.doc_state.math_mode {
                    self.parse_open_delimiter()
                } else {
                    Ok(self.parse_literal())
                }
            }
            TokenType::Period
            | TokenType::Lparen
            | TokenType::Lsqbrace
            | TokenType::Langle
            | TokenType::MathLbrace
            | TokenType::Vert
            | TokenType::Norm
            | TokenType::Rparen
            | TokenType::Rsqbrace
            | TokenType::Rangle
            | TokenType::MathRbrace => {
                if self.doc_state.math_mode {
                    self.parse_closed_delimiter()
                } else {
                    Ok(self.parse_literal())
                }
            }
            TokenType::Lbrace => self.parse_brace(true),
            TokenType::Useenv => self.parse_environment::<true>(),
            TokenType::Begenv => self.parse_environment::<false>(),
            TokenType::Endenv => self.parse_end_phantom_environment(),
            TokenType::DefineFunction => {
                self.parse_define_command(DefKind::Fnt, self.doc_state.xparse_defun)
            }
            TokenType::DefineEnv => self.parse_define_command(DefKind::Env, false),
            TokenType::DoubleQuote => {
                if self.doc_state.math_mode {
                    self.parse_text_in_math(false)
                } else {
                    Ok(self.parse_literal())
                }
            }
            TokenType::RawSharp => {
                if self.doc_state.math_mode {
                    self.parse_text_in_math(true)
                } else {
                    Ok(self.parse_literal())
                }
            }
            TokenType::ImportVesti => self.parse_import_vesti(),
            TokenType::ImportModule => self.parse_import_module(),
            TokenType::LuaCodeStart => {
                if self.allows.luacode {
                    self.parse_lua_code()
                } else {
                    let span = self.get_tok(Which::Current).span();
                    self.diagnostic
                        .set_parse_error(ParseErrorInfo::DisallowLuacode, Some(span));
                    Err(ParseError::ParseFailed)
                }
            }
            TokenType::LuaCodeEnd => {
                let span = self.get_tok(Which::Current).span();
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::VestiInternal("unexpected `LuacodeEnd` was found"),
                    Some(span),
                );
                Err(ParseError::ParseFailed)
            }
            TokenType::Illegal => {
                let span = self.get_tok(Which::Current).span();
                self.diagnostic
                    .set_parse_error(ParseErrorInfo::InvalidTokenFound, Some(span));
                Err(ParseError::ParseFailed)
            }
            TokenType::Deprecated {
                valid_in_text,
                instead,
            } => {
                if valid_in_text {
                    Ok(self.parse_literal())
                } else {
                    let span = self.get_tok(Which::Current).span();
                    self.diagnostic
                        .set_parse_error(ParseErrorInfo::Deprecated(instead), Some(span));
                    Err(ParseError::ParseFailed)
                }
            }
            _ => Ok(self.parse_literal()),
        }
    }

    fn parse_literal(&mut self) -> Stmt<'s> {
        let tok = self.get_tok(Which::Current);
        if self.doc_state.math_mode {
            Stmt::MathLit(tok_in_math(tok))
        } else {
            Stmt::TextLit(Cow::Borrowed(tok_in_text(tok)))
        }
    }
}

pub(crate) fn toktype_eq(a: &TokenType<'_>, b: &TokenType<'_>) -> bool {
    match (a, b) {
        (TokenType::BuiltinFunction(_), TokenType::BuiltinFunction(_)) => true,
        (TokenType::Deprecated { .. }, TokenType::Deprecated { .. }) => true,
        _ => a == b,
    }
}

/// True for `Text` or any keyword token
pub(crate) fn is_name_token(t: &TokenType<'_>) -> bool {
    matches!(
        t,
        TokenType::Text
            | TokenType::Docclass
            | TokenType::ImportPkg
            | TokenType::ImportVesti
            | TokenType::ImportModule
            | TokenType::StartDoc
            | TokenType::Useenv
            | TokenType::Begenv
            | TokenType::Endenv
            | TokenType::DefineFunction
            | TokenType::DefineEnv
    )
}

/// Borrow the token's in_text literal with the source lifetime.
pub(crate) fn tok_in_text<'s>(tok: &Token<'s>) -> &'s str {
    tok.in_text_src()
}

pub(crate) fn tok_in_math<'s>(tok: &Token<'s>) -> &'s str {
    tok.in_math_src()
}

pub(crate) fn token_expected_slice(t: TokenType<'static>) -> &'static [TokenType<'static>] {
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

/// Map a runtime `begin_env_tok` back to its `'static` form for diagnostics
/// (`NameMissErr` needs an owned-lifetime token).
pub(crate) fn static_toktype(t: TokenType<'_>) -> TokenType<'static> {
    match t {
        TokenType::Useenv => TokenType::Useenv,
        TokenType::Begenv => TokenType::Begenv,
        TokenType::Endenv => TokenType::Endenv,
        TokenType::DefineFunction => TokenType::DefineFunction,
        TokenType::DefineEnv => TokenType::DefineEnv,
        _ => TokenType::Illegal,
    }
}

/// Name-mangle an absolute path into the `@vesti__<hex>.tex` form vesti uses for
/// generated include files.
pub fn vesti_name_mangle(real_path: &str) -> String {
    // FNV-1a 64-bit — a small, dependency-free stable hash.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in real_path.as_bytes() {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("@vesti__{hash:016x}.tex")
}

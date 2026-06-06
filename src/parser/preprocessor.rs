use std::borrow::Cow;
use std::collections::HashMap;

use super::expectable::{Expectable, Which};
use crate::diagnostic::{Diagnostic, ParseErrorInfo};
use crate::lexer::Lexer;
use crate::lexer::token::{self, Token, TokenType};
use crate::location::{Location, Span};

pub type TokenList<'s> = Vec<Token<'s>>;

#[derive(Debug)]
pub enum PreprocessError {
    PreprocessFailed,
    GetFilePathFailed,
}

pub(super) struct PreprocessorState {
    // After 2020-10-01 the LaTeX kernel allows expl3 without importing it, so
    // `#ltx3_on`/`#ltx3_off` are allowed by default.
    allow_latex3: bool,
    is_premiere: bool,
    pub(super) lex_sleep: bool, // "sleep" the lexer for one step
}

impl Default for PreprocessorState {
    fn default() -> Self {
        PreprocessorState {
            allow_latex3: true,
            is_premiere: true,
            lex_sleep: false,
        }
    }
}

struct ComptimeFunction<'s> {
    params: usize,
    contents: TokenList<'s>,
}

pub struct Preprocessor<'s, 'd> {
    pub(super) diagnostic: &'d mut Diagnostic<'s>,
    pub(super) lexer: Lexer<'s>,
    pub(super) curr_tok: Token<'s>,
    pub(super) peek_tok: Token<'s>,
    comptime_fnt: HashMap<&'s str, ComptimeFunction<'s>>,
    pub(super) state: PreprocessorState,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum BuiltinKind {
    Preprocess,
    Normal,
    All,
}

impl<'s, 'd> Preprocessor<'s, 'd> {
    pub fn new(source: &'s str, diagnostic: &'d mut Diagnostic<'s>) -> Self {
        let lexer = Lexer::new(source);
        // Prime curr/peek
        let invalid = invalid_token();
        let mut pp = Preprocessor {
            diagnostic,
            lexer,
            curr_tok: invalid.clone(),
            peek_tok: invalid,
            comptime_fnt: HashMap::new(),
            state: PreprocessorState::default(),
        };
        pp.next_token();
        pp.next_token();
        pp
    }

    pub fn preprocess(mut self) -> Result<TokenList<'s>, PreprocessError> {
        let mut output: TokenList<'s> = Vec::new();
        self.preprocess_loop(&mut output)?;
        let span = self.curr_tok.span();
        output.push(Token::eof(span.start, span.end));
        Ok(output)
    }

    fn preprocess_loop(&mut self, tok_list: &mut TokenList<'s>) -> Result<(), PreprocessError> {
        // Process tokens until the current token is Eof. The canonical trailing
        // Eof is appended by `preprocess`, so we stop before emitting it here.
        loop {
            if matches!(self.curr_tok.toktype(), TokenType::Eof) {
                break;
            }
            self.preprocess_token(tok_list)?;
            self.next_token();
        }
        Ok(())
    }

    fn is_builtin(name: &str, kind: BuiltinKind) -> bool {
        match kind {
            BuiltinKind::Preprocess => token::is_preprocess_builtin(name),
            BuiltinKind::Normal => token::is_builtin(name),
            BuiltinKind::All => token::is_preprocess_builtin(name) || token::is_builtin(name),
        }
    }

    fn preprocess_token(&mut self, tok_list: &mut TokenList<'s>) -> Result<(), PreprocessError> {
        match self.curr_tok.toktype() {
            TokenType::BuiltinFunction(name) => {
                // preprocess-only builtins
                if token::is_preprocess_builtin(name) {
                    return token::dispatch_preprocess_builtin!(
                        self,
                        name,
                        (tok_list),
                        unreachable!("is_preprocess_builtin gated this dispatch")
                    );
                }

                if Self::is_builtin(name, BuiltinKind::Normal)
                    || token::is_function_param(name).is_some()
                {
                    // evaluated later in the parser
                    tok_list.push(self.curr_tok.clone());
                    return Ok(());
                }

                let fnt_loc = self.curr_tok.span();
                self.next_token(); // eat vesti function
                self.eat_whitespaces(false);
                self.preprocess_expand_def(fnt_loc, name, tok_list)
            }
            TokenType::StartDoc => {
                self.state.is_premiere = false;
                tok_list.push(self.curr_tok.clone());
                Ok(())
            }
            _ => {
                tok_list.push(self.curr_tok.clone());
                Ok(())
            }
        }
    }

    fn preprocess_expand_def(
        &mut self,
        fnt_loc: Span,
        fnt_name: &'s str,
        tok_list: &mut TokenList<'s>,
    ) -> Result<(), PreprocessError> {
        let (params_count, contents) = match self.comptime_fnt.get(fnt_name) {
            Some(c) => (c.params, c.contents.clone()),
            None => {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::WrongBuiltin {
                        name: Cow::Owned(fnt_name.to_owned()),
                        note: "builtins is not defined",
                    },
                    Some(fnt_loc),
                );
                return Err(PreprocessError::PreprocessFailed);
            }
        };

        let mut params: Vec<TokenList<'s>> = Vec::with_capacity(params_count);

        if params_count > 0 {
            self.expect_remain(TokenType::Lparen)?;
        }
        for _ in 0..params_count {
            self.parse_parameter(fnt_loc, &mut params)?;
            if self.expect(Which::Peek, &[TokenType::Lparen]) {
                self.next_token();
            }
        }
        if params_count > 0 {
            self.expect_remain(TokenType::Rparen)?;
        }

        self.expand_tokens(&contents, &params, tok_list)?;

        // With no params, the cursor sits on the token after the macro name; the
        // outer loop will skip a token, so tell the lexer to "sleep".
        if params_count == 0 {
            self.state.lex_sleep = true;
        }
        Ok(())
    }

    fn expand_tokens(
        &mut self,
        input_tokens: &TokenList<'s>,
        args: &[TokenList<'s>],
        output: &mut TokenList<'s>,
    ) -> Result<(), PreprocessError> {
        let mut i = 0usize;
        while i < input_tokens.len() {
            let tok = &input_tokens[i];
            match tok.toktype() {
                TokenType::BuiltinFunction(builtin_fnt) => {
                    if Self::is_builtin(builtin_fnt, BuiltinKind::Preprocess) {
                        self.diagnostic.set_parse_error(
                            ParseErrorInfo::WrongBuiltin {
                                name: Cow::Owned(builtin_fnt.to_owned()),
                                note: "there is a builtin function which cannot be used inside of vesti function body",
                            },
                            Some(tok.span()),
                        );
                        return Err(PreprocessError::PreprocessFailed);
                    }

                    if Self::is_builtin(builtin_fnt, BuiltinKind::Normal) {
                        output.push(tok.clone());
                        i += 1;
                        continue;
                    }

                    if let Some(fnt_param) = token::is_function_param(builtin_fnt) {
                        if fnt_param == 0 || fnt_param > args.len() {
                            self.diagnostic.set_parse_error(
                                ParseErrorInfo::InvalidDefunParam(fnt_param),
                                Some(tok.span()),
                            );
                            return Err(PreprocessError::PreprocessFailed);
                        }
                        let param_toks = args[fnt_param - 1].clone();
                        self.expand_tokens(&param_toks, &[], output)?;
                    } else if self.comptime_fnt.contains_key(builtin_fnt) {
                        let nested_params = self.comptime_fnt[builtin_fnt].params;
                        let nested_contents = self.comptime_fnt[builtin_fnt].contents.clone();
                        let (parsed_args, consumed) =
                            self.parse_args(input_tokens, i + 1, nested_params, tok.span())?;

                        let mut resolved_args: Vec<TokenList<'s>> =
                            Vec::with_capacity(nested_params);
                        for raw_arg in &parsed_args {
                            let mut resolved: TokenList<'s> = Vec::new();
                            self.expand_tokens(raw_arg, args, &mut resolved)?;
                            resolved_args.push(resolved);
                        }

                        self.expand_tokens(&nested_contents, &resolved_args, output)?;
                        i += consumed;
                    } else {
                        output.push(tok.clone());
                    }
                }
                _ => output.push(tok.clone()),
            }
            i += 1;
        }
        Ok(())
    }

    /// Returns `(args, consumed)` where `consumed` is the number of tokens taken
    /// past `start_idx`.
    fn parse_args(
        &mut self,
        slice: &TokenList<'s>,
        start_idx: usize,
        params_count: usize,
        loc: Span,
    ) -> Result<(Vec<TokenList<'s>>, usize), PreprocessError> {
        let mut args: Vec<TokenList<'s>> = Vec::with_capacity(params_count);
        let mut idx = start_idx;
        let mut count = 0usize;

        while count < params_count {
            // skip whitespace
            while idx < slice.len()
                && matches!(
                    slice[idx].toktype(),
                    TokenType::Space | TokenType::Tab | TokenType::Newline
                )
            {
                idx += 1;
            }

            if idx >= slice.len() || !matches!(slice[idx].toktype(), TokenType::Lparen) {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::WrongBuiltin {
                        name: Cow::Borrowed("def"),
                        note: "TODO: fill note later",
                    },
                    Some(loc),
                );
                return Err(PreprocessError::PreprocessFailed);
            }

            idx += 1; // consume '('
            let mut content: TokenList<'s> = Vec::new();
            let mut nested = 1usize;
            while idx < slice.len() {
                let t = &slice[idx];
                match t.toktype() {
                    TokenType::Lparen => nested += 1,
                    TokenType::Rparen => {
                        nested -= 1;
                        if nested == 0 {
                            break;
                        }
                    }
                    _ => {}
                }
                content.push(t.clone());
                idx += 1;
            }

            if nested != 0 {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::WrongBuiltin {
                        name: Cow::Borrowed("def"),
                        note: "TODO: fill note later",
                    },
                    Some(loc),
                );
                return Err(PreprocessError::PreprocessFailed);
            }

            args.push(content);
            idx += 1; // consume ')'
            count += 1;
        }

        Ok((args, idx - start_idx))
    }

    fn parse_parameter(
        &mut self,
        loc: Span,
        params: &mut Vec<TokenList<'s>>,
    ) -> Result<(), PreprocessError> {
        let mut contents: TokenList<'s> = Vec::new();
        self.expect_eat(TokenType::Lparen)?;
        let mut nested = 1usize;
        loop {
            let cont = match self.curr_tok.toktype() {
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
                        .set_parse_error(ParseErrorInfo::EofErr, Some(loc));
                    return Err(PreprocessError::PreprocessFailed);
                }
                _ => true,
            };
            if !cont {
                break;
            }

            match self.curr_tok.toktype() {
                TokenType::BuiltinFunction(builtin_fnt) => {
                    if Self::is_builtin(builtin_fnt, BuiltinKind::Preprocess) {
                        self.diagnostic.set_parse_error(
                            ParseErrorInfo::WrongBuiltin {
                                name: Cow::Owned(builtin_fnt.to_owned()),
                                note: "there is a builtin which cannot be used in vesti function parameters",
                            },
                            Some(self.curr_tok.span()),
                        );
                        return Err(PreprocessError::PreprocessFailed);
                    }

                    if Self::is_builtin(builtin_fnt, BuiltinKind::Normal) {
                        contents.push(self.curr_tok.clone());
                        self.next_token();
                        continue;
                    }

                    let fnt_loc = self.curr_tok.span();
                    self.next_token(); // eat vesti function
                    self.eat_whitespaces(false);
                    self.preprocess_expand_def(fnt_loc, builtin_fnt, &mut contents)?;
                }
                _ => contents.push(self.curr_tok.clone()),
            }
            self.next_token();
        }

        self.expect_remain(TokenType::Rparen)?;
        params.push(contents);
        Ok(())
    }

    fn push_makeatletter_like(
        &mut self,
        tok_list: &mut TokenList<'s>,
        fnt: &'static str,
        loc: Span,
    ) {
        if self.expect(Which::Peek, &[TokenType::Space, TokenType::Tab]) {
            self.next_token();
        }
        tok_list.push(synthetic(TokenType::Newline, "\n", loc));
        tok_list.push(synthetic(TokenType::LatexFunction, fnt, loc));
        tok_list.push(synthetic(TokenType::Newline, "\n", loc));
    }

    fn preprocess_at_on(&mut self, tok_list: &mut TokenList<'s>) -> Result<(), PreprocessError> {
        let loc = self.curr_tok.span();
        self.lexer.set_make_at_letter(true);
        self.push_makeatletter_like(tok_list, "\\makeatletter", loc);
        Ok(())
    }

    fn preprocess_at_off(&mut self, tok_list: &mut TokenList<'s>) -> Result<(), PreprocessError> {
        let loc = self.curr_tok.span();
        self.lexer.set_make_at_letter(true);
        self.push_makeatletter_like(tok_list, "\\makeatother", loc);
        Ok(())
    }

    fn preprocess_ltx3_on(&mut self, tok_list: &mut TokenList<'s>) -> Result<(), PreprocessError> {
        let loc = self.curr_tok.span();
        self.lexer.set_latex3(true);
        if self.state.allow_latex3 {
            self.push_makeatletter_like(tok_list, "\\ExplSyntaxOn", loc);
            Ok(())
        } else {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("ltx3_on"),
                    note: "must remove `#noltx3` to use this builtin",
                },
                Some(self.curr_tok.span()),
            );
            Err(PreprocessError::PreprocessFailed)
        }
    }

    fn preprocess_ltx3_off(&mut self, tok_list: &mut TokenList<'s>) -> Result<(), PreprocessError> {
        let loc = self.curr_tok.span();
        self.lexer.set_latex3(true);
        if self.state.allow_latex3 {
            self.push_makeatletter_like(tok_list, "\\ExplSyntaxOff", loc);
            Ok(())
        } else {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("ltx3_off"),
                    note: "must remove `#noltx3` to use this builtin",
                },
                Some(self.curr_tok.span()),
            );
            Err(PreprocessError::PreprocessFailed)
        }
    }

    fn preprocess_noltx3(&mut self, _tok_list: &mut TokenList<'s>) -> Result<(), PreprocessError> {
        if self.state.is_premiere {
            self.state.allow_latex3 = false;
            if self.expect(Which::Peek, &[TokenType::Space, TokenType::Tab]) {
                self.next_token();
            }
            Ok(())
        } else {
            self.diagnostic
                .set_parse_error(ParseErrorInfo::PreambleErr, Some(self.curr_tok.span()));
            Err(PreprocessError::PreprocessFailed)
        }
    }

    fn preprocess_def(&mut self, _tok_list: &mut TokenList<'s>) -> Result<(), PreprocessError> {
        let def_fnt_loc = self.curr_tok.span();
        self.expect_eat(TokenType::BuiltinFunction("def"))?;
        self.eat_whitespaces(false);
        let def_name = match self.curr_tok.toktype() {
            TokenType::BuiltinFunction(name) => {
                self.next_token();
                name
            }
            _ => {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::WrongBuiltin {
                        name: Cow::Borrowed("def"),
                        note: "<builtin> expected here",
                    },
                    Some(self.curr_tok.span()),
                );
                return Err(PreprocessError::PreprocessFailed);
            }
        };
        self.eat_whitespaces(false);

        if Self::is_builtin(def_name, BuiltinKind::All) {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("def"),
                    note: "one tried to change override builtin function",
                },
                Some(def_fnt_loc),
            );
            return Err(PreprocessError::PreprocessFailed);
        }

        let mut contents: TokenList<'s> = Vec::new();
        self.expect_eat(TokenType::Lbrace)?;
        let mut params = 0usize;
        let mut nested = 1usize;
        loop {
            let cont = match self.curr_tok.toktype() {
                TokenType::Lbrace => {
                    nested += 1;
                    true
                }
                TokenType::Rbrace => {
                    nested -= 1;
                    nested != 0
                }
                TokenType::Eof => {
                    self.diagnostic
                        .set_parse_error(ParseErrorInfo::EofErr, Some(def_fnt_loc));
                    return Err(PreprocessError::PreprocessFailed);
                }
                _ => true,
            };
            if !cont {
                break;
            }

            if let TokenType::BuiltinFunction(builtin_fnt) = self.curr_tok.toktype() {
                if Self::is_builtin(builtin_fnt, BuiltinKind::Preprocess) {
                    self.diagnostic.set_parse_error(
                        ParseErrorInfo::WrongBuiltin {
                            name: Cow::Owned(builtin_fnt.to_owned()),
                            note: "there is a builtin function which cannot be used inside of vesti function body",
                        },
                        Some(self.curr_tok.span()),
                    );
                    return Err(PreprocessError::PreprocessFailed);
                }

                if Self::is_builtin(builtin_fnt, BuiltinKind::Normal) {
                    contents.push(self.curr_tok.clone());
                    self.next_token();
                    continue;
                }

                if let Some(fnt_param) = token::is_function_param(builtin_fnt) {
                    if fnt_param == 0 {
                        self.diagnostic.set_parse_error(
                            ParseErrorInfo::InvalidDefunParam(fnt_param),
                            Some(def_fnt_loc),
                        );
                        return Err(PreprocessError::PreprocessFailed);
                    }
                    params = params.max(fnt_param);
                }
            }
            contents.push(self.curr_tok.clone());
            self.next_token();
        }

        self.expect_remain(TokenType::Rbrace)?;
        if self.expect(
            Which::Peek,
            &[TokenType::Space, TokenType::Tab, TokenType::Newline],
        ) {
            self.next_token(); // eat `}`
            while self.expect(Which::Peek, &[TokenType::Space, TokenType::Tab]) {
                self.next_token();
            }
        }

        self.comptime_fnt
            .insert(def_name, ComptimeFunction { params, contents });
        Ok(())
    }

    fn preprocess_undef(&mut self, _tok_list: &mut TokenList<'s>) -> Result<(), PreprocessError> {
        let undef_fnt_loc = self.curr_tok.span();
        self.expect_eat(TokenType::BuiltinFunction("undef"))?;
        self.eat_whitespaces(false);
        let undef_name = match self.curr_tok.toktype() {
            TokenType::BuiltinFunction(name) => {
                self.next_token();
                name
            }
            _ => {
                self.diagnostic.set_parse_error(
                    ParseErrorInfo::WrongBuiltin {
                        name: Cow::Borrowed("undef"),
                        note: "<builtin> expected here",
                    },
                    Some(self.curr_tok.span()),
                );
                return Err(PreprocessError::PreprocessFailed);
            }
        };
        self.eat_whitespaces(false);
        self.expect_remain(TokenType::Newline)?;

        if Self::is_builtin(undef_name, BuiltinKind::All) {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("undef"),
                    note: "cannot undef builtin functions",
                },
                Some(undef_fnt_loc),
            );
            return Err(PreprocessError::PreprocessFailed);
        }

        if !self.comptime_fnt.contains_key(undef_name) {
            self.diagnostic.set_parse_error(
                ParseErrorInfo::WrongBuiltin {
                    name: Cow::Borrowed("undef"),
                    note: "cannot undef undefined vesti function",
                },
                Some(undef_fnt_loc),
            );
            return Err(PreprocessError::PreprocessFailed);
        }

        self.comptime_fnt.remove(undef_name);
        Ok(())
    }

    fn preprocess_include(&mut self, _tok_list: &mut TokenList<'s>) -> Result<(), PreprocessError> {
        // File inclusion is intentionally not implemented in this port (module
        // and include file behavior is out of scope). Report a clear error.
        let include_loc = self.curr_tok.span();
        self.diagnostic.set_parse_error(
            ParseErrorInfo::WrongBuiltin {
                name: Cow::Borrowed("include"),
                note: "`#include` file handling is not supported in this build",
            },
            Some(include_loc),
        );
        Err(PreprocessError::PreprocessFailed)
    }
}

// -- Helper functions ---------------------------------------------------------

fn invalid_token<'s>() -> Token<'s> {
    Token::new(
        TokenType::Illegal,
        Cow::Borrowed(""),
        Cow::Borrowed(""),
        Span::default(),
    )
}

fn synthetic<'s>(toktype: TokenType<'s>, lit: &'static str, loc: Span) -> Token<'s> {
    Token::new(toktype, Cow::Borrowed(lit), Cow::Borrowed(lit), loc)
}

fn toktype_eq(a: &TokenType<'_>, b: &TokenType<'_>) -> bool {
    match (a, b) {
        (TokenType::BuiltinFunction(_), TokenType::BuiltinFunction(_)) => true,
        _ => a == b,
    }
}

// The diagnostic API wants a `'static` slice of expected token types. We only
// ever expect single fixed tokens here, so map each to a static singleton.
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
        TokenType::Newline => s!(TokenType::Newline),
        _ => s!(TokenType::Illegal),
    }
}

// silence unused field warning for `lexer` priming pattern
#[allow(dead_code)]
fn _use_location(_l: Location) {}

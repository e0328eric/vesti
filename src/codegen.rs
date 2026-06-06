use std::collections::HashMap;
use std::fmt::Write as _;

use crate::diagnostic::{Diagnostic, ParseDiagnostic, ParseErrorInfo};
use crate::lua::Lua;
use crate::parser::ParseError;
use crate::parser::ast::{ArgNeed, DelimiterKind, MathState, Stmt};

#[derive(Debug)]
pub enum CodegenError {
    Parse(ParseError),
    LuaLabelNotFound,
    DuplicatedLuaLabel,
    LuaEvalFailed,
    Fmt,
}

impl From<ParseError> for CodegenError {
    fn from(e: ParseError) -> Self {
        CodegenError::Parse(e)
    }
}

impl From<std::fmt::Error> for CodegenError {
    fn from(_: std::fmt::Error) -> Self {
        CodegenError::Fmt
    }
}

pub struct Codegen<'a, 's, 'd> {
    stmts: &'a [Stmt<'s>],
    diagnostic: &'d mut Diagnostic<'s>,
    luacode_exports: HashMap<String, String>,
    is_main: bool,
}

impl<'a, 's, 'd> Codegen<'a, 's, 'd> {
    pub fn new(stmts: &'a [Stmt<'s>], is_main: bool, diagnostic: &'d mut Diagnostic<'s>) -> Self {
        Codegen {
            stmts,
            diagnostic,
            luacode_exports: HashMap::new(),
            is_main,
        }
    }

    pub fn codegen(
        &mut self,
        lua: Option<&Lua>,
        placeholder: Option<&[Stmt<'s>]>,
        w: &mut String,
    ) -> Result<(), CodegenError> {
        for stmt in self.stmts {
            self.codegen_stmt(stmt, lua, placeholder, w)?;
        }
        Ok(())
    }

    fn codegen_stmts(
        &mut self,
        stmts: &[Stmt<'s>],
        lua: Option<&Lua>,
        placeholder: Option<&[Stmt<'s>]>,
        w: &mut String,
    ) -> Result<(), CodegenError> {
        for stmt in stmts {
            self.codegen_stmt(stmt, lua, placeholder, w)?;
        }
        Ok(())
    }

    fn codegen_stmt(
        &mut self,
        stmt: &Stmt<'s>,
        lua: Option<&Lua>,
        placeholder: Option<&[Stmt<'s>]>,
        w: &mut String,
    ) -> Result<(), CodegenError> {
        match stmt {
            Stmt::NopStmt => {}
            Stmt::Placeholder => {
                // Global definitions placeholder. The aggregated global
                // definitions (if any) are emitted between the wrapper comments
                w.push_str("\n%%%    Global Definitions\n");
                if let Some(p) = placeholder {
                    self.codegen_stmts(p, lua, placeholder, w)?;
                }
                w.push_str("\n%%%    End Global Definitions\n");
            }
            Stmt::TextLit(ctx) => {
                write!(w, "{ctx}")?;
            }
            Stmt::MathLit(ctx) => {
                w.push_str(ctx);
            }
            Stmt::MathCtx {
                state,
                inner,
                label,
            } => {
                let (open, close) = match state {
                    MathState::Inline => ("$", "$"),
                    MathState::Display => ("\\[", "\\]"),
                    MathState::Labeled => ("\\begin{equation}", "\\end{equation}"),
                };
                w.push_str(open);
                if let Some(label) = label {
                    write!(w, "\\label{{{label}}}")?;
                }
                self.codegen_stmts(inner, lua, placeholder, w)?;
                w.push_str(close);
            }
            Stmt::Braced {
                unwrap_brace,
                inner,
            } => {
                if !*unwrap_brace {
                    w.push('{');
                }
                self.codegen_stmts(inner, lua, placeholder, w)?;
                if !*unwrap_brace {
                    w.push('}');
                }
            }
            Stmt::Fraction {
                numerator,
                denominator,
            } => {
                w.push_str("\\frac{");
                self.codegen_stmts(numerator, lua, placeholder, w)?;
                w.push_str("}{");
                self.codegen_stmts(denominator, lua, placeholder, w)?;
                w.push('}');
            }
            Stmt::DocumentStart => w.push_str("\n\\begin{document}"),
            Stmt::DocumentEnd => w.push_str("\n\\end{document}\n"),
            Stmt::DocumentClass { name, options } => {
                w.push_str("\\documentclass");
                if let Some(options) = options {
                    write_bracketed_options(w, options)?;
                }
                writeln!(w, "{{{name}}}")?;
                // vesti uses `\text`, which needs at least amstext.
                w.push_str("\\usepackage{amstext}\n");
            }
            Stmt::ImportSinglePkg(usepkg) => {
                w.push_str("\\usepackage");
                if let Some(options) = &usepkg.options {
                    write_bracketed_options(w, options)?;
                }
                writeln!(w, "{{{}}}", usepkg.name)?;
            }
            Stmt::ImportMultiplePkgs(usepkgs) => {
                for usepkg in usepkgs {
                    w.push_str("\\usepackage");
                    if let Some(options) = &usepkg.options {
                        write_bracketed_options(w, options)?;
                    }
                    writeln!(w, "{{{}}}", usepkg.name)?;
                }
            }
            Stmt::PlainTextInMath {
                add_front_space,
                add_back_space,
                inner,
            } => {
                w.push_str("\\text{");
                if *add_front_space {
                    w.push(' ');
                }
                self.codegen_stmts(inner, lua, placeholder, w)?;
                if *add_back_space {
                    w.push(' ');
                }
                w.push('}');
            }
            Stmt::MathDelimiter { delimiter, kind } => match kind {
                DelimiterKind::None => w.push_str(delimiter),
                DelimiterKind::LeftBig => write!(w, "\\left{delimiter}")?,
                DelimiterKind::RightBig => write!(w, "\\right{delimiter}")?,
            },
            Stmt::Environment {
                name,
                args,
                inner,
                label,
            } => {
                write!(w, "\\begin{{{name}}}")?;
                self.codegen_args(args, lua, placeholder, w)?;
                if let Some(label) = label {
                    write!(w, "\\label{{{label}}}")?;
                }
                self.codegen_stmts(inner, lua, placeholder, w)?;
                write!(w, "\\end{{{name}}}")?;
            }
            Stmt::PictureEnvironment {
                width,
                height,
                xoffset,
                yoffset,
                unit_length,
                inner,
            } => {
                if let Some(unit_length) = unit_length {
                    writeln!(w, "\\setlength{{\\unitlength}}{{{unit_length}}}")?;
                }
                match (xoffset, yoffset) {
                    (Some(x), Some(y)) => {
                        write!(w, "\\begin{{picture}}({width},{height})({x},{y})")?;
                    }
                    _ => {
                        write!(w, "\\begin{{picture}}({width},{height})")?;
                    }
                }
                self.codegen_stmts(inner, lua, placeholder, w)?;
                w.push_str("\\end{picture}");
            }
            Stmt::BeginPhantomEnviron {
                name,
                args,
                add_newline,
            } => {
                write!(w, "\\begin{{{name}}}")?;
                self.codegen_args(args, lua, placeholder, w)?;
                if *add_newline {
                    w.push('\n');
                }
            }
            Stmt::EndPhantomEnviron(name) => {
                write!(w, "\\end{{{name}}}")?;
            }
            Stmt::ImportVesti(name) => {
                write!(w, "\\input{{{name}}}")?;
            }
            Stmt::FilePath(name) => {
                write!(w, "{name}")?;
            }
            Stmt::DefunParamList {
                nested,
                arg_num,
                span,
            } => {
                let num_of_sharp = match 2usize.checked_pow(*nested as u32) {
                    Some(v) => v,
                    None => {
                        self.diagnostic.set_parse_error(
                            ParseErrorInfo::DefunParamOverflow(*nested),
                            Some(*span),
                        );
                        return Err(CodegenError::Parse(ParseError::ParseFailed));
                    }
                };
                for _ in 0..num_of_sharp {
                    w.push('#');
                }
                write!(w, "{arg_num}")?;
            }
            Stmt::DefineFunction {
                name,
                param_str,
                kind,
                inner,
            } => {
                kind.prologue(name, w);
                kind.param(param_str.as_deref(), w);

                let mut body = String::new();
                self.codegen_stmts(inner, lua, placeholder, &mut body)?;
                let mut body_content: &str = &body;
                if kind.trim_left {
                    body_content = body_content.trim_start_matches([' ', '\t', '\r', '\n']);
                }
                if kind.trim_right {
                    body_content = body_content.trim_end_matches([' ', '\t', '\r', '\n']);
                }
                w.push_str(body_content);

                kind.epilogue(name, w);
            }
            Stmt::DefineEnv {
                name,
                param_str,
                kind,
                inner_begin,
                inner_end,
            } => {
                kind.prologue(name, w);

                match param_str {
                    Some(param) => write!(w, "{{{param}}}")?,
                    None => w.push_str("{}"),
                }
                w.push('{');

                let mut begin_body = String::new();
                self.codegen_stmts(inner_begin, lua, placeholder, &mut begin_body)?;
                let mut begin_content: &str = &begin_body;
                if kind.begin_trim_left {
                    begin_content = begin_content.trim_start_matches([' ', '\t', '\r', '\n']);
                }
                if kind.begin_trim_right {
                    begin_content = begin_content.trim_end_matches([' ', '\t', '\r', '\n']);
                }
                w.push_str(begin_content);

                w.push_str("}{");

                let mut end_body = String::new();
                self.codegen_stmts(inner_end, lua, placeholder, &mut end_body)?;
                let mut end_content: &str = &end_body;
                if kind.end_trim_left {
                    end_content = end_content.trim_start_matches([' ', '\t', '\r', '\n']);
                }
                if kind.end_trim_right {
                    end_content = end_content.trim_end_matches([' ', '\t', '\r', '\n']);
                }
                w.push_str(end_content);

                w.push_str("}%\n");
            }
            Stmt::LuaCode {
                code_span,
                is_global: _,
                code_import,
                code_export,
                code,
            } => {
                let Some(lua) = lua else {
                    return Ok(());
                };

                // Resolve imports into a combined source.
                let mut new_code = String::with_capacity(code.len());
                if let Some(imports) = code_import {
                    for import_label in imports {
                        match self.luacode_exports.get(*import_label) {
                            Some(import_code) => {
                                new_code.push_str(import_code);
                                new_code.push('\n');
                            }
                            None => {
                                let d =
                                    ParseDiagnostic::lua_label_not_found(*code_span, import_label);
                                self.diagnostic.init_diag_inner(
                                    crate::diagnostic::DiagnosticInner::ParseError(d),
                                );
                                return Err(CodegenError::LuaLabelNotFound);
                            }
                        }
                    }
                }

                // An `export` block only records its source for later imports;
                // it is not evaluated here.
                if let Some(export_label) = code_export {
                    if self.luacode_exports.contains_key(*export_label) {
                        self.diagnostic.set_parse_error(
                            ParseErrorInfo::DuplicatedLuaLabel((*export_label).to_owned()),
                            Some(*code_span),
                        );
                        return Err(CodegenError::DuplicatedLuaLabel);
                    }
                    new_code.push_str(code);
                    self.luacode_exports
                        .insert((*export_label).to_owned(), new_code);
                    return Ok(());
                }

                // Otherwise evaluate the (import-prefixed) code and splice the
                // text emitted via `vesti.print` into the output.
                new_code.push_str(code);
                if lua.eval_code(&new_code).is_err() {
                    let d = ParseDiagnostic::lua_eval_failed(
                        Some(*code_span),
                        "failed to run luacode".to_owned(),
                        "see above lua error message",
                    );
                    self.diagnostic
                        .init_diag_inner(crate::diagnostic::DiagnosticInner::ParseError(d));
                    return Err(CodegenError::LuaEvalFailed);
                }

                let ves_output = lua.take_vesti_output();
                w.push_str(&ves_output);
            }
        }
        Ok(())
    }

    fn codegen_args(
        &mut self,
        args: &[crate::parser::ast::Arg<'s>],
        lua: Option<&Lua>,
        placeholder: Option<&[Stmt<'s>]>,
        w: &mut String,
    ) -> Result<(), CodegenError> {
        for arg in args {
            match arg.needed {
                ArgNeed::MainArg => {
                    w.push('{');
                    self.codegen_stmts(&arg.ctx, lua, placeholder, w)?;
                    w.push('}');
                }
                ArgNeed::Optional => {
                    w.push('[');
                    self.codegen_stmts(&arg.ctx, lua, placeholder, w)?;
                    w.push(']');
                }
                ArgNeed::StarArg => w.push('*'),
            }
        }
        Ok(())
    }
}

fn write_bracketed_options(
    w: &mut String,
    options: &[std::borrow::Cow<'_, str>],
) -> std::fmt::Result {
    if options.is_empty() {
        return Ok(());
    }
    w.push('[');
    let last = options.len() - 1;
    for (i, opt) in options.iter().enumerate() {
        if i == last {
            write!(w, "{opt}]")?;
        } else {
            write!(w, "{opt},")?;
        }
    }
    Ok(())
}

use std::borrow::Cow;
use std::fmt::Write as _;

use crate::lexer::token::TokenType;
use crate::location::Span;

// TODO: Replace this into crossterm one
// Minimal ANSI helpers
mod ansi {
    pub const RESET: &str = "\x1b[0m";
    pub const ERROR: &str = "\x1b[1;31m";
    pub const NOTE: &str = "\x1b[1;36m";
    pub const BOLD: &str = "\x1b[1m";
    pub const BRIGHT_GREEN: &str = "\x1b[92m";
}

#[derive(Default)]
pub struct Diagnostic<'s> {
    pub absolute_filename: Option<Cow<'s, str>>,
    pub source: Option<Cow<'s, str>>,
    pub inner: Option<DiagnosticInner<'s>>,
    /// When set, `main` must not pretty-print the diagnostic again (the
    /// compiler already printed it).
    pub lock_print_at_main: bool,
}

impl<'s> Diagnostic<'s> {
    pub fn new() -> Self {
        Diagnostic::default()
    }

    pub fn init_metadata(
        &mut self,
        absolute_filename: Option<Cow<'s, str>>,
        source: Option<Cow<'s, str>>,
    ) {
        if let Some(af) = absolute_filename {
            self.absolute_filename = Some(af);
        }
        if let Some(s) = source {
            self.source = Some(s);
        }
    }

    pub fn init_diag_inner(&mut self, diag_inner: DiagnosticInner<'s>) {
        self.inner = Some(diag_inner);
    }

    pub fn set_parse_error(&mut self, err_info: ParseErrorInfo<'s>, span: Option<Span>) {
        self.init_diag_inner(DiagnosticInner::ParseError(ParseDiagnostic {
            err_info,
            span,
        }));
    }

    pub fn reset(&mut self) {
        *self = Diagnostic::default();
    }

    /// Render the diagnostic into a string (used both by `pretty_print` and by
    /// tests). Returns `None` when there is no inner diagnostic.
    pub fn render(&self, no_color: bool) -> Option<String> {
        let inner = self.inner.as_ref()?;
        let mut out = String::new();
        inner.render(
            self.absolute_filename.as_deref(),
            self.source.as_deref(),
            no_color,
            &mut out,
        );
        Some(out)
    }

    pub fn pretty_print(&self, no_color: bool) {
        if let Some(text) = self.render(no_color) {
            eprint!("{text}");
        }
    }
}

pub enum DiagnosticInner<'s> {
    ParseError(ParseDiagnostic<'s>),
    IoError(IoDiagnostic),
}

impl<'s> DiagnosticInner<'s> {
    fn render(
        &self,
        absolute_filename: Option<&str>,
        source: Option<&str>,
        no_color: bool,
        out: &mut String,
    ) {
        match self {
            DiagnosticInner::ParseError(d) => d.render(absolute_filename, source, no_color, out),
            DiagnosticInner::IoError(d) => d.render(no_color, out),
        }
    }
}

pub struct IoDiagnostic {
    pub msg: String,
    pub note_msg: Option<String>,
    pub span: Option<Span>,
}

impl IoDiagnostic {
    pub fn new(span: Option<Span>, msg: String) -> Self {
        IoDiagnostic {
            msg,
            note_msg: None,
            span,
        }
    }

    pub fn with_note(span: Option<Span>, msg: String, note: String) -> Self {
        IoDiagnostic {
            msg,
            note_msg: Some(note),
            span,
        }
    }

    fn render(&self, no_color: bool, out: &mut String) {
        if !no_color {
            let _ = write!(out, "{}error: {}{}\n", ansi::ERROR, ansi::RESET, self.msg);
            if let Some(note) = &self.note_msg {
                let _ = write!(out, "{}note: {}{}\n", ansi::NOTE, ansi::RESET, note);
            }
        } else {
            let _ = write!(out, "error: {}\n", self.msg);
            if let Some(note) = &self.note_msg {
                let _ = write!(out, "note: {}\n", note);
            }
        }
    }
}

#[derive(Default)]
pub struct ParseDiagnostic<'s> {
    pub err_info: ParseErrorInfo<'s>,
    pub span: Option<Span>,
}

#[derive(Default)]
pub enum ParseErrorInfo<'s> {
    #[default]
    None,
    BegenvUnderflow,
    ChangeEngineTwice,
    DefunParamOverflow(usize),
    Deprecated(&'static str),
    DisallowLuacode,
    DuplicatedLuaLabel(String),
    EnvInsideDefun,
    EofErr,
    IllegalUseErr(&'static str),
    InvalidBuiltin(String),
    InvalidDefunKind(String),
    InvalidDefunParam(usize),
    InvalidLatexEngine(&'s str),
    InvalidLuacode,
    InvalidTokenFound,
    IsNotClosed {
        open: &'static [TokenType<'static>],
        close: TokenType<'static>,
    },
    IsNotOpened {
        open: &'static [TokenType<'static>],
        close: TokenType<'static>,
    },
    LuaEvalFailed {
        err_msg: String,
        err_detail: String,
    },
    LuaLabelNotFound(String),
    MathmodeInMath,
    ModuleNotFound(String),
    NameMissErr(TokenType<'static>),
    PreambleErr,
    TextmodeInText,
    TokenExpected {
        expected: &'static [TokenType<'static>],
        obtained: Option<TokenType<'s>>,
    },
    TooManyBegenv(u8),
    VestiInternal(&'static str),
    WrongBuiltin {
        name: Cow<'s, str>,
        note: &'static str,
    },
}

impl<'s> ParseDiagnostic<'s> {
    pub fn lua_label_not_found(span: Span, label: &str) -> Self {
        ParseDiagnostic {
            err_info: ParseErrorInfo::LuaLabelNotFound(label.to_owned()),
            span: Some(span),
        }
    }

    pub fn lua_eval_failed(span: Option<Span>, msg: String, detail: &str) -> Self {
        ParseDiagnostic {
            err_info: ParseErrorInfo::LuaEvalFailed {
                err_msg: msg,
                err_detail: detail.to_owned(),
            },
            span,
        }
    }

    fn error_msg(&self) -> String {
        let mut out = String::new();
        match &self.err_info {
            ParseErrorInfo::None => out.push_str("<none>"),
            ParseErrorInfo::EofErr => out.push_str("end of file was detected"),
            ParseErrorInfo::PreambleErr => out.push_str("PremiereErr\n"),
            ParseErrorInfo::TokenExpected { expected, obtained } => {
                if expected.len() == 1 {
                    let _ = write!(
                        out,
                        "{} was expected but got {}",
                        expected[0],
                        opt_tok(obtained.as_ref())
                    );
                } else {
                    let mut tmp = String::from("[");
                    for e in expected.iter() {
                        let _ = write!(tmp, " {e}");
                    }
                    tmp.push_str(" ]");
                    let _ = write!(
                        out,
                        "{tmp} was expected but got {}",
                        opt_tok(obtained.as_ref())
                    );
                }
            }
            ParseErrorInfo::NameMissErr(toktype) => {
                let _ = write!(out, "{toktype} should have a name");
            }
            ParseErrorInfo::IsNotOpened { open, close } => {
                if open.len() == 1 {
                    let _ = write!(out, "either {close} was not opened with {}", open[0]);
                } else {
                    let mut tmp = String::from("[");
                    for o in open.iter() {
                        let _ = write!(tmp, " {o}");
                    }
                    tmp.push_str(" ]");
                    let _ = write!(out, "either {close} was not opened with {tmp}");
                }
            }
            ParseErrorInfo::IsNotClosed { open, close } => {
                if open.len() == 1 {
                    let _ = write!(out, "{} was not closed with {close}", open[0]);
                } else {
                    let mut tmp = String::from("[");
                    for o in open.iter() {
                        let _ = write!(tmp, " {o}");
                    }
                    tmp.push_str(" ]");
                    let _ = write!(out, "either {tmp} was not closed with {close}");
                }
            }
            ParseErrorInfo::TextmodeInText => out.push_str("`#textmode` found in text"),
            ParseErrorInfo::MathmodeInMath => out.push_str("`#mathmode` found in math"),
            ParseErrorInfo::TooManyBegenv(_) => out.push_str("too many `begenv` was found"),
            ParseErrorInfo::BegenvUnderflow => out.push_str("there is no `begenv` to match"),
            ParseErrorInfo::InvalidTokenFound => out.push_str("invalid token was found"),
            ParseErrorInfo::Deprecated(info) => {
                let _ = write!(out, "deprecated token was found. Replace `{info}` instead");
            }
            ParseErrorInfo::ModuleNotFound(mod_path) => {
                let _ = write!(out, "There is no module at {mod_path}");
            }
            ParseErrorInfo::InvalidDefunKind(defun_kind) => {
                let _ = write!(out, "String `{defun_kind}` is not a valid defun attribute");
            }
            ParseErrorInfo::DefunParamOverflow(val) => {
                let _ = write!(
                    out,
                    "2 to the power of {val} exceeds max value of 2^{}",
                    std::mem::size_of::<usize>()
                );
            }
            ParseErrorInfo::InvalidBuiltin(builtin_fnt) => {
                let _ = write!(out, "builtin `#{builtin_fnt}` is not defined");
            }
            ParseErrorInfo::WrongBuiltin { name, .. } => {
                let _ = write!(out, "wrong usage for builtin `#{name}`");
            }
            ParseErrorInfo::InvalidDefunParam(val) => {
                let _ = write!(
                    out,
                    "parameter number `{val}` is wrong one for a function parameter"
                );
            }
            ParseErrorInfo::EnvInsideDefun => {
                out.push_str("`useenv` cannot be used inside `defun` body")
            }
            ParseErrorInfo::IllegalUseErr(info) | ParseErrorInfo::VestiInternal(info) => {
                out.push_str(info)
            }
            ParseErrorInfo::InvalidLuacode => out.push_str("invalid lua code was found"),
            ParseErrorInfo::DisallowLuacode => out.push_str("nested lua code is not allowed"),
            ParseErrorInfo::LuaLabelNotFound(label) => {
                let _ = write!(out, "label `{label}` is not found");
            }
            ParseErrorInfo::DuplicatedLuaLabel(label) => {
                let _ = write!(out, "label `{label}` is duplicated");
            }
            ParseErrorInfo::LuaEvalFailed { err_msg, .. } => {
                let _ = write!(out, "lua exception occured: {err_msg}");
            }
            ParseErrorInfo::ChangeEngineTwice => {
                out.push_str("engine type is tried to changed in twice, which is not allowed")
            }
            ParseErrorInfo::InvalidLatexEngine(engine) => {
                let _ = write!(out, "invalid latex engine name {engine} was found");
            }
        }
        out
    }

    fn note_msg(&self) -> Option<String> {
        match &self.err_info {
            ParseErrorInfo::EofErr => Some(
                "usually, this error occurs when the brace does not match.\n\
                 maybe the chatacter pointed has no pair in the code."
                    .to_owned(),
            ),
            ParseErrorInfo::TooManyBegenv(count) => {
                Some(format!("maximum allowed `begenv` is {count}."))
            }
            ParseErrorInfo::LuaLabelNotFound(_) => {
                Some("labels should be declared before it is used".to_owned())
            }
            ParseErrorInfo::LuaEvalFailed { err_detail, .. } => Some(err_detail.clone()),
            ParseErrorInfo::InvalidLatexEngine(_) => {
                Some("valid ones are `plain`, `pdf`, `xe`, and `lua`".to_owned())
            }
            ParseErrorInfo::WrongBuiltin { note, .. } => Some((*note).to_owned()),
            ParseErrorInfo::InvalidDefunParam(val) => Some(format!(
                "because of the LaTeX and Vesti internal, only values not divisible by 10 are valid for a function parameter. But you gave `{val}`."
            )),
            ParseErrorInfo::EnvInsideDefun => Some(
                "Internally vesti uses \\def family to define latex functions.\n\
                 However, latex hates to use environment inside of \\def.\n\
                 For this reason, vesti emits an error to notice to change."
                    .to_owned(),
            ),
            ParseErrorInfo::ChangeEngineTwice => Some(
                "There are two ways to change latex engine: in `first.lua` and `compty`.\n\
                 Vesti allows to use either of them, not both"
                    .to_owned(),
            ),
            ParseErrorInfo::VestiInternal(_) => Some(
                "Unexpected behavior was found.\n\
                 If this error is raised, please make an issue on github.\n\
                 addr: https://github.com/e0328eric/vesti"
                    .to_owned(),
            ),
            _ => None,
        }
    }

    fn render(
        &self,
        absolute_filename: Option<&str>,
        source: Option<&str>,
        no_color: bool,
        out: &mut String,
    ) {
        let source = source.expect("source must be set for ParseDiagnostic");
        let filename = absolute_filename.unwrap_or("^.^");
        let err_msg = self.error_msg();

        if let Some(span) = self.span {
            let line = source
                .split('\n')
                .nth(span.start.row() - 1)
                .expect("span.start.row is invalid");
            let source_trim = line.trim_end_matches('\r');

            // Build the caret underline.
            let mut underline = String::new();
            for _ in 0..span.start.column().saturating_sub(1) {
                underline.push(' ');
            }
            if span.start.row() == span.end.row() {
                let count = span.end.column().saturating_sub(span.start.column());
                for _ in 0..count {
                    underline.push('^');
                }
            } else {
                let count = source_trim
                    .chars()
                    .count()
                    .saturating_sub(span.start.column().saturating_sub(1));
                for _ in 0..count {
                    underline.push('^');
                }
            }

            if !no_color {
                let _ = write!(
                    out,
                    "{}{}:{}:{}: {}error: {}{}\n    {}\n{}    {}\n{}",
                    ansi::BOLD,
                    filename,
                    span.start.row(),
                    span.start.column(),
                    ansi::ERROR,
                    ansi::RESET,
                    err_msg,
                    source_trim,
                    ansi::BRIGHT_GREEN,
                    underline,
                    ansi::RESET,
                );
                if let Some(nm) = self.note_msg() {
                    let _ = writeln!(out, "{}note: {}{}", ansi::NOTE, ansi::RESET, nm);
                }
            } else {
                let _ = write!(
                    out,
                    "{}:{}:{}: error: {}\n    {}\n    {}\n",
                    filename,
                    span.start.row(),
                    span.start.column(),
                    err_msg,
                    source_trim,
                    underline,
                );
                if let Some(nm) = self.note_msg() {
                    let _ = writeln!(out, "note: {}", nm);
                }
            }
        } else if !no_color {
            let _ = write!(
                out,
                "{}{}: {}error: {}{}\n{}",
                ansi::BOLD,
                filename,
                ansi::ERROR,
                ansi::RESET,
                err_msg,
                ansi::RESET,
            );
            if let Some(nm) = self.note_msg() {
                let _ = writeln!(out, "{}note: {}{}", ansi::NOTE, ansi::RESET, nm);
            }
        } else {
            let _ = writeln!(out, "{}: error: {}", filename, err_msg);
            if let Some(nm) = self.note_msg() {
                let _ = writeln!(out, "note: {}", nm);
            }
        }
    }
}

fn opt_tok(t: Option<&TokenType<'_>>) -> String {
    match t {
        Some(t) => format!("{t}"),
        None => "null".to_owned(),
    }
}

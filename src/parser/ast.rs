use std::borrow::Cow;

use crate::location::Span;
use crate::parser::defkind::{DefenvKind, DefunKind};

#[derive(Clone, Debug)]
pub struct UsePackage<'s> {
    pub name: Cow<'s, str>,
    pub options: Option<Vec<Cow<'s, str>>>,
}

#[derive(Clone, Copy, Debug)]
pub struct TrimWhitespace {
    pub start: bool,
    pub mid: Option<bool>,
    pub end: bool,
}

impl Default for TrimWhitespace {
    fn default() -> Self {
        TrimWhitespace {
            start: true,
            mid: None,
            end: true,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MathState {
    Inline,
    Display,
    Labeled,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DelimiterKind {
    None,
    LeftBig,
    RightBig,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ArgNeed {
    MainArg,
    Optional,
    StarArg,
}

#[derive(Clone, Debug)]
pub struct Arg<'s> {
    pub needed: ArgNeed,
    pub ctx: Vec<Stmt<'s>>,
}

#[derive(Clone, Debug)]
pub enum Stmt<'s> {
    NopStmt,
    Placeholder,
    TextLit(Cow<'s, str>),
    MathLit(&'s str),
    MathCtx {
        state: MathState,
        inner: Vec<Stmt<'s>>,
        label: Option<String>,
    },
    Braced {
        unwrap_brace: bool,
        inner: Vec<Stmt<'s>>,
    },
    Fraction {
        numerator: Vec<Stmt<'s>>,
        denominator: Vec<Stmt<'s>>,
    },
    DocumentStart,
    DocumentEnd,
    DocumentClass {
        name: Cow<'s, str>,
        options: Option<Vec<Cow<'s, str>>>,
    },
    ImportSinglePkg(UsePackage<'s>),
    ImportMultiplePkgs(Vec<UsePackage<'s>>),
    ImportVesti(String),
    PlainTextInMath {
        add_front_space: bool,
        add_back_space: bool,
        inner: Vec<Stmt<'s>>,
    },
    MathDelimiter {
        delimiter: &'s str,
        kind: DelimiterKind,
    },
    DefunParamList {
        nested: usize,  // 0: #, 1: ##, 2: ####, etc.
        arg_num: usize, // must be from 1 to 9
        span: Span,
    },
    DefineFunction {
        name: Cow<'s, str>,
        param_str: Option<Cow<'s, str>>,
        kind: DefunKind,
        inner: Vec<Stmt<'s>>,
    },
    DefineEnv {
        name: Cow<'s, str>,
        param_str: Option<Cow<'s, str>>,
        kind: DefenvKind,
        inner_begin: Vec<Stmt<'s>>,
        inner_end: Vec<Stmt<'s>>,
    },
    Environment {
        name: Cow<'s, str>,
        args: Vec<Arg<'s>>,
        inner: Vec<Stmt<'s>>,
        label: Option<String>,
    },
    /// `picture` environment generated from the `#picture` builtin.
    PictureEnvironment {
        width: usize,
        height: usize,
        xoffset: Option<usize>,
        yoffset: Option<usize>,
        unit_length: Option<String>,
        inner: Vec<Stmt<'s>>,
    },
    BeginPhantomEnviron {
        name: Cow<'s, str>,
        args: Vec<Arg<'s>>,
        add_newline: bool,
    },
    EndPhantomEnviron(Cow<'s, str>),
    FilePath(Cow<'s, str>),
    LuaCode {
        code_span: Span,
        is_global: bool,
        code_import: Option<Vec<&'s str>>,
        code_export: Option<&'s str>,
        code: String,
    },
}

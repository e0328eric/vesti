use std::path::PathBuf;

use crate::lexer::token::FunctionDefKind;

pub type Latex = Vec<Statement>;

#[derive(Debug, PartialEq, Clone)]
pub enum Statement {
    NopStmt,
    NonStopMode,
    MakeAtLetter,
    MakeAtOther,
    Latex3On,
    Latex3Off,
    ImportExpl3Pkg,
    DocumentClass {
        name: String,
        options: Option<Vec<Latex>>,
    },
    Usepackage {
        name: String,
        options: Option<Vec<Latex>>,
    },
    MultiUsepackages {
        pkgs: Latex,
    },
    ImportVesti {
        filename: PathBuf,
    },
    FilePath {
        filename: PathBuf,
    },
    DocumentStart,
    DocumentEnd,
    MainText(String),
    Integer(i64),
    Float(f64),
    RawLatex(String),
    BracedStmt(Latex),
    MathText {
        state: MathState,
        text: Latex,
    },
    MathDelimiter {
        delimiter: String,
        kind: DelimiterKind,
    },
    Fraction {
        numerator: Latex,
        denominator: Latex,
    },
    PlainTextInMath {
        remove_front_space: bool,
        remove_back_space: bool,
        text: Latex,
    },
    LatexFunction {
        name: String,
        args: Vec<(ArgNeed, Latex)>,
    },
    Environment {
        name: String,
        args: Vec<(ArgNeed, Latex)>,
        text: Latex,
    },
    BeginPhantomEnvironment {
        name: String,
        args: Vec<(ArgNeed, Latex)>,
        add_newline: bool,
    },
    EndPhantomEnvironment {
        name: String,
    },
    FunctionDefine {
        kind: FunctionDefKind,
        name: String,
        args: String,
        trim: TrimWhitespace,
        body: Latex,
    },
    // TODO: Does not support mandatory argument
    EnvironmentDefine {
        is_redefine: bool,
        name: String,
        args_num: u8,
        optional_arg: Option<Latex>,
        trim: TrimWhitespace,
        begin_part: Latex,
        end_part: Latex,
    },
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum ArgNeed {
    MainArg,
    Optional,
    StarArg,
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum MathState {
    Text,
    Inline,
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub struct TrimWhitespace {
    pub start: bool,
    pub mid: Option<bool>,
    pub end: bool,
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum DelimiterKind {
    Default,
    LeftBig,
    RightBig,
}

use crate::experimental::lexer::token::TokenType;

pub type Latex = Vec<Statement>;

#[derive(Debug, PartialEq, Clone)]
pub enum Statement {
    NonStopMode,
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
    Fraction {
        numerator: Latex,
        denominator: Latex,
    },
    PlainTextInMath {
        trim: TrimWhitespace,
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
    },
    EndPhantomEnvironment {
        name: String,
    },
    FunctionDefine {
        style: FunctionStyle,
        name: String,
        args: String,
        trim: TrimWhitespace,
        body: Latex,
    },
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

#[derive(Debug, PartialEq, Clone, Copy, Default)]
pub enum FunctionStyle {
    #[default]
    Plain,
    LongPlain,
    OuterPlain,
    LongOuterPlain,
    Expand,
    LongExpand,
    OuterExpand,
    LongOuterExpand,
    Global,
    LongGlobal,
    OuterGlobal,
    LongOuterGlobal,
    ExpandGlobal,
    LongExpandGlobal,
    OuterExpandGlobal,
    LongOuterExpandGlobal,
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub struct TrimWhitespace {
    pub start: bool,
    pub mid: Option<bool>,
    pub end: bool,
}

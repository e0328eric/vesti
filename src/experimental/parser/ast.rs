use crate::experimental::lexer::token::TokenType;

pub type StmtVec = Vec<Statement>;
pub type ExprVec = Vec<Expression>;

#[derive(Debug, PartialEq, Clone)]
pub enum Statement {
    DocumentClass {
        name: String,
        options: Option<Vec<StmtVec>>,
    },
    Packages {
        pkgs: Vec<LtxPackage>,
    },
    // TODO: Implement module system for vesti
    //Module {
    //    name: String,
    //},
    DocumentStart,
    DocumentEnd,
    ExprStmt(ExprVec),
    BlockStmt(StmtVec),
    Environment {
        name: String,
        args: Vec<(ArgNeed, StmtVec)>,
        text: StmtVec,
    },
    BeginPhantomEnvironment {
        name: String,
        args: Vec<(ArgNeed, StmtVec)>,
    },
    EndPhantomEnvironment {
        name: String,
    },
    FunctionDefine {
        style: FunctionStyle,
        name: String,
        args: String,
        trim: TrimWhitespace,
        body: StmtVec,
    },
    EnvironmentDefine {
        is_redefine: bool,
        name: String,
        args_num: u8,
        optional_arg: Option<StmtVec>,
        trim: TrimWhitespace,
        begin_part: StmtVec,
        end_part: StmtVec,
    },
}

#[derive(Debug, PartialEq, Clone)]
pub enum Expression {
    Letter(String),
    Integer(i64),
    Float(f64),
    RawLatex(String),
    MathText {
        state: MathState,
        text: StmtVec,
    },
    Fraction {
        numerator: StmtVec,
        denominator: StmtVec,
    },
    PlainTextInMath {
        trim: TrimWhitespace,
        text: StmtVec,
    },
    LatexFunction {
        name: String,
        args: Vec<(ArgNeed, StmtVec)>,
    },
}

#[derive(Debug, PartialEq, Clone)]
pub struct LtxPackage {
    name: String,
    options: Option<Vec<OptionPair>>,
}

#[derive(Debug, PartialEq, Clone)]
pub struct OptionPair {
    key: Expression,
    value: ExprVec,
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

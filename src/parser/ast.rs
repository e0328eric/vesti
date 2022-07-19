pub type Latex = Vec<Statement>;

#[derive(Debug, PartialEq, Clone)]
pub enum Statement {
    DocumentClass {
        name: String,
        options: Option<Vec<Latex>>,
    },
    Usepackage {
        name: String,
        options: Option<Vec<Latex>>,
    },
    MultiUsepackages {
        pkgs: Vec<Statement>,
    },
    DocumentStart,
    DocumentEnd,
    MainText(String),
    Integer(i64),
    Float(f64),
    RawLatex(String),
    MathText {
        state: MathState,
        text: Vec<Statement>,
    },
    PlainTextInMath(Latex),
    LatexFunction {
        name: String,
        args: Vec<(ArgNeed, Vec<Statement>)>,
    },
    Environment {
        name: String,
        args: Vec<(ArgNeed, Vec<Statement>)>,
        text: Latex,
    },
    FunctionDefinition {
        name: String,
        args: Vec<(ArgNeed, Vec<Statement>)>,
        body: Latex,
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

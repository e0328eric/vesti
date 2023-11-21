use std::path::PathBuf;

use crate::lexer::token::TokenType;

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
    ImportVesti {
        filename: PathBuf,
    },
    ImportFile {
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
    Fraction {
        numerator: Latex,
        denominator: Latex,
    },
    PlainTextInMath {
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
        style: FunctionStyle,
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

impl TryFrom<TokenType> for FunctionStyle {
    type Error = TokenType;
    fn try_from(value: TokenType) -> Result<Self, Self::Error> {
        match value {
            TokenType::FunctionDef => Ok(Self::Plain),
            TokenType::LongFunctionDef => Ok(Self::LongPlain),
            TokenType::OuterFunctionDef => Ok(Self::OuterPlain),
            TokenType::LongOuterFunctionDef => Ok(Self::LongOuterPlain),
            TokenType::EFunctionDef => Ok(Self::Expand),
            TokenType::LongEFunctionDef => Ok(Self::LongExpand),
            TokenType::OuterEFunctionDef => Ok(Self::OuterExpand),
            TokenType::LongOuterEFunctionDef => Ok(Self::LongOuterExpand),
            TokenType::GFunctionDef => Ok(Self::Global),
            TokenType::LongGFunctionDef => Ok(Self::LongGlobal),
            TokenType::OuterGFunctionDef => Ok(Self::OuterGlobal),
            TokenType::LongOuterGFunctionDef => Ok(Self::LongOuterGlobal),
            TokenType::XFunctionDef => Ok(Self::ExpandGlobal),
            TokenType::LongXFunctionDef => Ok(Self::LongExpandGlobal),
            TokenType::OuterXFunctionDef => Ok(Self::OuterExpandGlobal),
            TokenType::LongOuterXFunctionDef => Ok(Self::LongOuterExpandGlobal),
            _ => Err(value),
        }
    }
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub struct TrimWhitespace {
    pub start: bool,
    pub mid: Option<bool>,
    pub end: bool,
}

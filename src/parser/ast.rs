use std::fmt::{self, Debug};
use std::ops::{BitAnd, BitOr};
use std::path::PathBuf;

use crate::location::Span;

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
    PythonCode {
        pycode_span: Span,
        pycode_import: Option<Vec<String>>,
        pycode_export: Option<String>,
        code: String,
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

#[repr(transparent)]
#[derive(Clone, Copy, PartialEq, PartialOrd)]
pub struct FunctionDefKind(u8);

impl FunctionDefKind {
    pub const NONE: Self = Self(0);
    pub const LONG: Self = Self(1 << 0);
    pub const OUTER: Self = Self(1 << 1);
    pub const EXPAND: Self = Self(1 << 2);
    pub const GLOBAL: Self = Self(1 << 3);

    #[inline]
    pub fn has_property(self, rhs: Self) -> bool {
        self & rhs == rhs
    }

    pub fn parse_kind(kind_str: &str) -> Self {
        let long = if kind_str.contains(['l', 'L']) {
            Self::LONG
        } else {
            Self::NONE
        };
        let outer = if kind_str.contains(['o', 'O']) {
            Self::OUTER
        } else {
            Self::NONE
        };
        let expand = if kind_str.contains(['e', 'E']) {
            Self::EXPAND
        } else {
            Self::NONE
        };
        let global = if kind_str.contains(['g', 'G']) {
            Self::GLOBAL
        } else {
            Self::NONE
        };

        long | outer | expand | global
    }
}

impl BitOr for FunctionDefKind {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

impl BitAnd for FunctionDefKind {
    type Output = Self;
    fn bitand(self, rhs: Self) -> Self::Output {
        Self(self.0 & rhs.0)
    }
}

impl Debug for FunctionDefKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.has_property(Self::LONG) {
            write!(f, "long")?;
        }

        Ok(())
    }
}

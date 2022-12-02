pub mod pretty_print;

use crate::experimental::lexer::token::TokenType;
use crate::location::Span;

#[derive(Debug, PartialEq)]
pub enum VestiParseErrKind {
    EOFErr, // EOF found although parsing is not completed
    IllegalCharacterFoundErr,
    TypeMismatch {
        expected: Vec<TokenType>,
        got: TokenType,
    },
    ParseIntErr,
    ParseFloatErr,
    InvalidTokToConvert {
        got: TokenType,
    },
    BracketMismatchErr {
        expected: TokenType,
    },
    BracketNumberMatchedErr,
    IsNotClosedErr {
        open: Vec<TokenType>,
        close: TokenType,
    },
    IsNotOpenedErr {
        open: Vec<TokenType>,
        close: TokenType,
    },
    NameMissErr {
        r#type: TokenType,
    },
    IllegalUseErr {
        got: TokenType,
    },
}

#[derive(Debug, PartialEq)]
pub enum VestiCommandUtilErrKind {
    IOErr(std::io::ErrorKind),
    NoFilenameInputErr,
    TakeFilesErr,
}

#[derive(Debug)]
pub enum VestiErr {
    ParseErr {
        err_kind: VestiParseErrKind,
        location: Span,
    },
    UtilErr {
        err_kind: VestiCommandUtilErrKind,
    },
}

impl VestiErr {
    pub fn make_parse_err(err_kind: VestiParseErrKind, location: Span) -> Self {
        Self::ParseErr { err_kind, location }
    }
}

impl From<std::io::Error> for VestiErr {
    fn from(err: std::io::Error) -> Self {
        Self::UtilErr {
            err_kind: VestiCommandUtilErrKind::IOErr(err.kind()),
        }
    }
}

pub type Result<T> = std::result::Result<T, VestiErr>;

//////////////////////////////////////
// Implementation of Displaying Errors
// by implementing new trait
//////////////////////////////////////
pub trait Error {
    // Error code should display with hex decimal
    fn err_code(&self) -> u16;
    fn err_str(&self) -> String;
    fn err_detail_str(&self) -> Vec<String>;
}

impl Error for VestiErr {
    fn err_code(&self) -> u16 {
        match self {
            Self::ParseErr { err_kind, .. } => err_kind.err_code(),
            Self::UtilErr { err_kind } => err_kind.err_code(),
        }
    }
    fn err_str(&self) -> String {
        match self {
            Self::ParseErr { err_kind, .. } => err_kind.err_str(),
            Self::UtilErr { err_kind } => err_kind.err_str(),
        }
    }
    fn err_detail_str(&self) -> Vec<String> {
        match self {
            Self::ParseErr { err_kind, .. } => err_kind.err_detail_str(),
            Self::UtilErr { err_kind } => err_kind.err_detail_str(),
        }
    }
}

impl Error for VestiParseErrKind {
    fn err_code(&self) -> u16 {
        match self {
            Self::EOFErr => 0x0E0F,
            Self::IllegalCharacterFoundErr => 0x0101,
            Self::TypeMismatch { .. } => 0x0102,
            Self::ParseIntErr => 0x0103,
            Self::ParseFloatErr => 0x0104,
            Self::InvalidTokToConvert { .. } => 0x0105,
            Self::BracketMismatchErr { .. } => 0x0106,
            Self::BracketNumberMatchedErr => 0x0107,
            Self::IsNotClosedErr { .. } => 0x0108,
            Self::IsNotOpenedErr { .. } => 0x0109,
            Self::NameMissErr { .. } => 0x0110,
            Self::IllegalUseErr { .. } => 0x0111,
        }
    }
    fn err_str(&self) -> String {
        match self {
            Self::EOFErr => String::from("EOF found unexpectedly"),
            Self::IllegalCharacterFoundErr => String::from("`ILLEGAL` character found"),
            Self::TypeMismatch { .. } => String::from("Type mismatched"),
            Self::ParseIntErr => String::from("Parsing integer error occurs"),
            Self::ParseFloatErr => String::from("Parsing float error occurs"),
            Self::InvalidTokToConvert { got } => {
                format!("Type `{got:?}` is not convertible into latex")
            }
            Self::BracketMismatchErr { expected } => {
                format!("Cannot find `{expected:?}` delimiter")
            }
            Self::BracketNumberMatchedErr => String::from("Delimiter pair does not matched"),
            Self::IsNotClosedErr { open, .. } => format!("Type `{open:?}` is not closed"),
            Self::IsNotOpenedErr { close, .. } => {
                format!("Type `{close:?}` is used without the opening part")
            }
            Self::NameMissErr { r#type } => format!("Type `{:?}` requires its name", r#type),
            Self::IllegalUseErr { got } => {
                format!("Type `{got:?}` cannot use out of the math block or function definition")
            }
        }
    }
    fn err_detail_str(&self) -> Vec<String> {
        match self {
            Self::EOFErr | Self::IllegalCharacterFoundErr => vec![],
            Self::TypeMismatch { expected, got } => {
                vec![format!("expected `{expected:?}`, got `{got:?}`")]
            }
            Self::ParseIntErr => vec![
                String::from("if this error occurs, this preprocessor has an error"),
                String::from("so let me know when this error occurs"),
            ],
            Self::ParseFloatErr => vec![
                String::from("if this error occurs, this preprocessor has an error"),
                String::from("so let me know when this error occurs"),
            ],
            Self::InvalidTokToConvert { got } => match got {
                TokenType::Etxt => vec![
                    String::from("must use `etxt` only at a math context"),
                    String::from("If `etxt` is in a math mode, then this error can"),
                    String::from("occur when `mtxt` is missing."),
                ],
                _ => Vec::new(),
            },
            Self::BracketMismatchErr { expected } => {
                vec![format!("Cannot find `{:?}` delimiter", expected)]
            }
            Self::BracketNumberMatchedErr => vec![
                String::from("cannot find a bracket that matches with that one"),
                String::from("help: close a bracket with an appropriate one"),
            ],
            Self::IsNotClosedErr { close, .. } => vec![
                format!("cannot find type `{close:?}` to close this environment"),
                format!("check that type `{close:?}` is properly located"),
            ],
            Self::IsNotOpenedErr { open, close } => vec![
                format!("type `{close:?}` is used, but there is no type"),
                format!("     `{open:?}`"),
                format!("to be pair with it.",),
                format!("help: add type `{open:?}` before this `{close:?}` type"),
            ],
            Self::NameMissErr { r#type } => vec![
                format!("type `{:?}` is used in here, but vesti cannot", r#type),
                String::from("find its name part."),
                match r#type {
                    TokenType::BeginEnv => String::from("example: begenv foo"),
                    TokenType::EndEnv => String::from("example: pendenv foo"),
                    TokenType::FunctionDef => String::from("example: defun foo"),
                    _ => unreachable!(),
                },
            ],
            Self::IllegalUseErr { .. } => {
                vec![
                    String::from("wrap the whole expression that uses this"),
                    String::from("symbol using math related warppers like"),
                    String::from("`$`, `\\(`, `\\)`, `\\[`, `\\]` or `defun` like blocks"),
                ]
            }
        }
    }
}

impl Error for VestiCommandUtilErrKind {
    fn err_code(&self) -> u16 {
        match self {
            Self::IOErr(_) => 0x0001,
            Self::NoFilenameInputErr => 0x0002,
            Self::TakeFilesErr => 0x0003,
        }
    }
    fn err_str(&self) -> String {
        match self {
            Self::IOErr(err) => format!("IO error `{:?}` occurs", err),
            Self::NoFilenameInputErr => String::from("No file name or path is given"),
            Self::TakeFilesErr => String::from("Error occurs while taking files"),
        }
    }
    fn err_detail_str(&self) -> Vec<String> {
        match self {
            Self::TakeFilesErr => vec![
                String::from("If there is no reason that error occurs you think,"),
                String::from("it might be a vesti's bug. If so, let me know."),
                String::from("Report it at https://github.com/e0328eric/vesti"),
            ],
            _ => Vec::new(),
        }
    }
}

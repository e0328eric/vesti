#![allow(clippy::needless_raw_string_hashes)]

pub mod pretty_print;

use yaml_rust::scanner::ScanError;

use crate::lexer::token::TokenType;
use crate::location::Span;

#[allow(dead_code)]
#[derive(Debug, PartialEq)]
pub enum DeprecatedKind {
    None,
    InsteadTokenExist(&'static str),
    OtherExplanation(&'static str),
}

#[derive(Debug, PartialEq)]
pub enum VestiParseErrKind {
    EOFErr, // EOF found although parsing is not completed
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
    DeprecatedUseErr {
        instead: DeprecatedKind,
    },
    ParseModuleRonErr(ron::error::SpannedError),
    IllegalUseErr {
        got: TokenType,
        reason: Option<&'static str>,
    },
}

#[derive(Debug)]
pub enum VestiUtilErrKind {
    NoFilenameInputErr,
    TakeFilesErr,
    CompileAllWithoutHasSubVesti,
    InvalidLaTeXEngine,
    LatexCompliationErr,
    IOErr {
        kind: std::io::ErrorKind,
        note_msg: String,
    },
    ScanErr(ScanError),
    #[cfg(feature = "tectonic-backend")]
    #[allow(dead_code)]
    TectonicErr(tectonic::Error),
}

#[derive(Debug)]
pub enum VestiErr {
    ParseErr {
        err_kind: VestiParseErrKind,
        location: Span,
    },
    UtilErr {
        err_kind: VestiUtilErrKind,
    },
}

impl VestiErr {
    pub fn make_parse_err(err_kind: VestiParseErrKind, location: Span) -> Self {
        Self::ParseErr { err_kind, location }
    }

    pub fn make_util_err(err_kind: VestiUtilErrKind) -> Self {
        Self::UtilErr { err_kind }
    }

    pub fn from_io_err(err: std::io::Error, note_msg: impl ToString) -> Self {
        Self::UtilErr {
            err_kind: VestiUtilErrKind::IOErr {
                kind: err.kind(),
                note_msg: note_msg.to_string(),
            },
        }
    }
}

impl From<ScanError> for VestiErr {
    fn from(err: ScanError) -> Self {
        Self::UtilErr {
            err_kind: VestiUtilErrKind::ScanErr(err),
        }
    }
}

#[cfg(feature = "tectonic-backend")]
impl From<tectonic::Error> for VestiErr {
    fn from(err: tectonic::Error) -> Self {
        Self::UtilErr {
            err_kind: VestiUtilErrKind::TectonicErr(err),
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
    fn err_note_str(&self) -> Option<Vec<String>>;
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
    fn err_note_str(&self) -> Option<Vec<String>> {
        match self {
            Self::ParseErr { err_kind, .. } => err_kind.err_note_str(),
            Self::UtilErr { err_kind } => err_kind.err_note_str(),
        }
    }
}

impl Error for VestiParseErrKind {
    fn err_code(&self) -> u16 {
        match self {
            Self::EOFErr => 0x0E0F,
            Self::TypeMismatch { .. } => 0x0101,
            Self::ParseIntErr => 0x0102,
            Self::ParseFloatErr => 0x0103,
            Self::InvalidTokToConvert { .. } => 0x0104,
            Self::BracketMismatchErr { .. } => 0x0105,
            Self::BracketNumberMatchedErr => 0x0106,
            Self::IsNotClosedErr { .. } => 0x0107,
            Self::IsNotOpenedErr { .. } => 0x0108,
            Self::NameMissErr { .. } => 0x0109,
            Self::DeprecatedUseErr { .. } => 0x0110,
            Self::ParseModuleRonErr(_) => 0x0111,
            Self::IllegalUseErr { .. } => 0x0112,
        }
    }
    fn err_str(&self) -> String {
        match self {
            Self::EOFErr => String::from("EOF found unexpectedly"),
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
            Self::DeprecatedUseErr { .. } => "This is deprecated".to_string(),
            Self::ParseModuleRonErr(_) => "Failed to parse vesti module ron file".to_string(),
            Self::IllegalUseErr { got, .. } => {
                format!("Invalid usage of `{got:?}` found")
            }
        }
    }
    fn err_detail_str(&self) -> Vec<String> {
        match self {
            Self::EOFErr => vec![],
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
                TokenType::MathTextEnd => vec![
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
                    TokenType::Begenv => String::from("example: begenv foo"),
                    TokenType::FunctionDef(_) => String::from("example: defun foo"),
                    _ => unreachable!(),
                },
            ],
            Self::DeprecatedUseErr { instead } => match instead {
                DeprecatedKind::None => vec![format!("There is no alternative token")],
                DeprecatedKind::InsteadTokenExist(instead_token) => {
                    vec![format!("Use `{instead_token}` token instead.")]
                }
                DeprecatedKind::OtherExplanation(explain) => vec![format!("{explain}")],
            },
            Self::ParseModuleRonErr(err) => vec![format!("{err}")],
            Self::IllegalUseErr { reason, .. } => {
                if let Some(reason) = reason {
                    vec![String::from(*reason)]
                } else {
                    Vec::new()
                }
            }
        }
    }
    fn err_note_str(&self) -> Option<Vec<String>> {
        None
    }
}

impl Error for VestiUtilErrKind {
    fn err_code(&self) -> u16 {
        match self {
            Self::NoFilenameInputErr => 0x0011,
            Self::TakeFilesErr => 0x0012,
            Self::CompileAllWithoutHasSubVesti => 0x0013,
            Self::InvalidLaTeXEngine => 0x0014,
            Self::LatexCompliationErr => 0x0015,
            Self::IOErr { .. } => 0x0001,
            Self::ScanErr(_) => 0x0002,
            #[cfg(feature = "tectonic-backend")]
            Self::TectonicErr(_) => 0x0003,
        }
    }
    fn err_str(&self) -> String {
        match self {
            Self::NoFilenameInputErr => String::from("No file name or path is given"),
            Self::TakeFilesErr => String::from("Error occurs while taking files"),
            Self::CompileAllWithoutHasSubVesti => {
                String::from("cannot use `--all` flag without `--has-sub` flag")
            }
            Self::InvalidLaTeXEngine => String::from("Invalid LaTeX engine was given."),
            Self::LatexCompliationErr => {
                String::from("Failed to generate pdf from compiled tex files")
            }
            Self::IOErr { kind, .. } => format!("IO error `{kind:?}` occurs"),
            Self::ScanErr(err) => format!("Yaml parsing error `{err:?}` occurs"),
            #[cfg(feature = "tectonic-backend")]
            Self::TectonicErr(_) => format!("Tectonic error occurs"),
        }
    }
    fn err_detail_str(&self) -> Vec<String> {
        Vec::new()
    }
    fn err_note_str(&self) -> Option<Vec<String>> {
        match self {
            Self::TakeFilesErr | Self::InvalidLaTeXEngine => Some(vec![
                String::from("If there is no reason that error occurs you think,"),
                String::from("it might be a vesti's bug. If so, let me know."),
                String::from("Report it at https://github.com/e0328eric/vesti"),
            ]),
            Self::LatexCompliationErr => Some(vec![
                String::from("This error occurs when LaTeX compiler failed."),
                String::from(
                    "For more information, see stdout and stderr files inside vesti-cache.",
                ),
            ]),
            Self::IOErr {
                note_msg: ref msg, ..
            } => Some(vec![msg.clone()]),
            #[cfg(feature = "tectonic-backend")]
            Self::TectonicErr(_) => Some(vec![
                String::from("This error occurs when Tectonic backend failed."),
                String::from("See the detail in the above tectonic emitted error message"),
            ]),
            _ => None,
        }
    }
}

pub mod err_kind;
pub mod pretty_print;

use crate::lexer::token::TokenType;
use crate::location::Span;
use err_kind::{VestiCommandUtilErr, VestiErrKind, VestiParseErr};

#[derive(Debug)]
pub struct VestiErr {
    pub err_kind: VestiErrKind,
    pub location: Option<Span>,
}

// compare two error type are equal if errkinds are same
impl PartialEq for VestiErr {
    fn eq(&self, other: &Self) -> bool {
        self.err_kind == other.err_kind
    }
}

impl VestiErr {
    pub fn make_parse_err(parse_err: VestiParseErr, location: Option<Span>) -> Self {
        Self {
            err_kind: VestiErrKind::ParseErr(parse_err),
            location,
        }
    }
}

impl From<std::io::Error> for VestiErr {
    fn from(err: std::io::Error) -> Self {
        Self {
            err_kind: VestiErrKind::UtilErr(VestiCommandUtilErr::IOErr(err.kind())),
            location: None,
        }
    }
}

pub type Result<T> = std::result::Result<T, VestiErr>;

//////////////////////////////////////
// Implementation of Displaying Errors
// by implementing new trait
//////////////////////////////////////
pub trait VError {
    // Error code should display with hex decimal
    fn err_code(&self) -> u16;
    fn err_str(&self) -> String;
    fn err_detail_str(&self) -> Vec<String>;
}

impl VError for VestiErrKind {
    fn err_code(&self) -> u16 {
        self.map(|errkind| errkind.err_code())
    }
    fn err_str(&self) -> String {
        self.map(|errkind| errkind.err_str())
    }
    fn err_detail_str(&self) -> Vec<String> {
        self.map(|errkind| errkind.err_detail_str())
    }
}

impl VError for VestiParseErr {
    fn err_code(&self) -> u16 {
        match self {
            Self::EOFErr => 0x01FF,
            Self::TypeMismatch { .. } => 0x0101,
            Self::BeforeDocumentErr { .. } => 0x0102,
            Self::ParseIntErr => 0x0103,
            Self::ParseFloatErr => 0x0104,
            Self::InvalidTokToParse { .. } => 0x0105,
            Self::BracketMismatchErr { .. } => 0x0106,
            Self::BracketNumberMatchedErr => 0x0107,
            Self::BegenvIsNotClosedErr => 0x0108,
            Self::EndenvIsUsedWithoutBegenvPairErr => 0x0108,
            Self::BegenvNameMissErr => 0x0109,
        }
    }
    fn err_str(&self) -> String {
        match self {
            Self::EOFErr => String::from("EOF found unexpectively"),
            Self::TypeMismatch { .. } => String::from("Type mismatched"),
            Self::BeforeDocumentErr { got } => {
                format!("Type `{:?}` must be placed after `document`", got)
            }
            Self::ParseIntErr => String::from("Parsing integer error occurs"),
            Self::ParseFloatErr => String::from("Parsing float error occurs"),
            Self::InvalidTokToParse { got } => format!("Type `{:?}` is not parsable", got),
            Self::BracketMismatchErr { expected } => {
                format!("Cannot find `{:?}` delimiter", expected)
            }
            Self::BracketNumberMatchedErr => String::from("Delimiter pair does not matched"),
            Self::BegenvIsNotClosedErr => String::from("`begenv` is not closed"),
            Self::EndenvIsUsedWithoutBegenvPairErr => {
                String::from("`endenv` is used without `begenv` pair")
            }
            Self::BegenvNameMissErr => String::from("Missing environment name"),
        }
    }
    fn err_detail_str(&self) -> Vec<String> {
        match self {
            Self::EOFErr => vec![],
            Self::TypeMismatch { expected, got } => {
                vec![format!("expected `{:?}`, got `{:?}`", expected, got)]
            }
            Self::BeforeDocumentErr { got } => {
                vec![format!("move `{:?}` after `document` keyword", got)]
            }
            Self::ParseIntErr => vec![
                String::from("if this error occures, this preprocessor has an error"),
                String::from("so let me know when this error occures"),
            ],
            Self::ParseFloatErr => vec![
                String::from("if this error occures, this preprocessor has an error"),
                String::from("so let me know when this error occures"),
            ],
            Self::InvalidTokToParse { got } => match got {
                TokenType::Etxt => vec![String::from("must use `etxt` only at the math context")],
                _ => Vec::new(),
            },
            Self::BracketMismatchErr { expected } => {
                vec![format!("Cannot find `{:?}` delimiter", expected)]
            }
            Self::BracketNumberMatchedErr => vec![
                String::from("cannot find a bracket that matches with that one"),
                String::from("help: close a bracket with an appropriate one"),
            ],
            Self::BegenvIsNotClosedErr => vec![
                String::from("cannot find `endenv` to close this environment"),
                String::from("check that `endenv` is properly located"),
            ],
            Self::EndenvIsUsedWithoutBegenvPairErr => vec![
                String::from("`endenv` is used, but there is no `begenv` to be pair with it"),
                String::from("help: add `begenv` before this `endenv` keyword"),
            ],
            Self::BegenvNameMissErr => vec![
                String::from("`begenv` is used in here, but vesti cannot"),
                String::from("find its name part. type its name."),
                String::from("example: begenv foo"),
            ],
        }
    }
}

impl VError for VestiCommandUtilErr {
    fn err_code(&self) -> u16 {
        match self {
            Self::IOErr(_) => 0x0001,
            Self::NoFilenameInputErr => 0x0002,
            Self::TakeFilesErr => 0x0003,
        }
    }
    fn err_str(&self) -> String {
        match self {
            Self::IOErr(err) => format!("IO error `{:?}` occures", err),
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

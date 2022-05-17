use super::VError;
use crate::lexer::token::TokenType;

#[derive(Debug, PartialEq)]
pub enum VestiErrKind {
    ParseErr(VestiParseErr),
    UtilErr(VestiCommandUtilErr),
}

impl VestiErrKind {
    pub(super) fn map<F, R>(&self, f: F) -> R
    where
        F: Fn(&dyn VError) -> R,
    {
        match self {
            Self::ParseErr(errkind) => f(errkind),
            Self::UtilErr(errkind) => f(errkind),
        }
    }
}

#[derive(Debug, PartialEq)]
pub enum VestiParseErr {
    EOFErr, // EOF found although parsing is not completed
    IllegalCharacterFoundErr,
    TypeMismatch {
        expected: Vec<TokenType>,
        got: TokenType,
    },
    BeforeDocumentErr {
        got: TokenType,
    },
    ParseIntErr,
    ParseFloatErr,
    InvalidTokToParse {
        got: TokenType,
    },
    BracketMismatchErr {
        expected: TokenType,
    },
    BracketNumberMatchedErr,
    BegenvIsNotClosedErr,
    EndenvIsUsedWithoutBegenvPairErr,
    BegenvNameMissErr,
    UseOnlyInMathErr {
        got: TokenType,
    },
}

#[derive(Debug, PartialEq)]
pub enum VestiCommandUtilErr {
    IOErr(std::io::ErrorKind),
    NoFilenameInputErr,
    TakeFilesErr,
}

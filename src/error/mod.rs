pub mod err_kind;
pub mod pretty_print;

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

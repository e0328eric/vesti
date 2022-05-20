use std::process::{self, Termination};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ExitCode {
    Success,
    Failure,
}

impl Termination for ExitCode {
    fn report(self) -> process::ExitCode {
        match self {
            Self::Success => process::ExitCode::SUCCESS,
            Self::Failure => process::ExitCode::FAILURE,
        }
    }
}

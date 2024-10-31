use std::process::{self, Termination};

// std::process::ExitCode does not implement PartialEq but we need to compare
// ExitCode, so I made this enum
#[repr(u8)]
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

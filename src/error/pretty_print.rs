use super::err_kind::VError;
use super::VestiErr;
use crate::location::Span;
use std::path::Path;

const BOLD_TEXT: &str = "\x1b[1m";
const ERR_COLOR: &str = "\x1b[38;5;9m";
const ERR_TITLE_COLOR: &str = "\x1b[38;5;15m";
const BLUE_COLOR: &str = "\x1b[38;5;12m";
const RESET_COLOR: &str = "\x1b[0m";

pub fn pretty_print(
    source: Option<&str>,
    vesti_error: VestiErr,
    filepath: Option<&Path>,
) -> String
where
{
    let lines = source.map(|inner| inner.lines());
    let VestiErr {
        ref err_kind,
        ref location,
    } = vesti_error;
    let err_code = err_kind.err_code();
    let err_str = err_kind.err_str();
    let mut output = String::new();

    // Make error code and error title format
    output = output + BOLD_TEXT + ERR_COLOR;
    output += &format!(
        "error[E{0:04X}]{color:}: {1}",
        err_code,
        err_str,
        color = ERR_TITLE_COLOR
    );
    output = output + RESET_COLOR + "\n";

    if let Some(Span { start, end }) = location {
        let start_row_num = format!("{} ", start.row());

        // If the filepath of the given input one is found, print it with error location
        if let Some(m_filepath) = filepath {
            output = output
                + &" ".repeat(start_row_num.len().saturating_sub(1))
                + BOLD_TEXT
                + BLUE_COLOR
                + "--> "
                + RESET_COLOR
                + m_filepath.to_str().unwrap()
                + &format!(":{}:{}\n", start.row(), start.column())
        }

        output = output
            + BOLD_TEXT
            + BLUE_COLOR
            + &" ".repeat(start_row_num.len())
            + "|\n"
            + &start_row_num
            + "|   "
            + RESET_COLOR;
        if let Some(mut inner) = lines {
            output += inner.nth(start.row() - 1).unwrap();
        }
        output += "\n";

        // Print an error message with multiple lines
        let padding_space = end.column().saturating_sub(start.column()) + 1;
        output = output
            + BOLD_TEXT
            + BLUE_COLOR
            + &" ".repeat(start_row_num.len())
            + "|   "
            + &" ".repeat(start.column().saturating_sub(1))
            + ERR_COLOR
            + &"^".repeat(end.column().saturating_sub(start.column()))
            + " ";

        for (i, msg) in err_kind.err_detail_str().iter().enumerate() {
            if i == 0 {
                output = output + msg + "\n";
            } else {
                output = output
                    + BOLD_TEXT
                    + BLUE_COLOR
                    + &" ".repeat(start_row_num.len())
                    + "|   "
                    + &" ".repeat(start.column().saturating_sub(1))
                    + ERR_COLOR
                    + &" ".repeat(padding_space)
                    + msg
                    + "\n";
            }
        }
    }
    output += RESET_COLOR;

    output
}

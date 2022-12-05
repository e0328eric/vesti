use std::io::{self, BufWriter, Write};
use std::path::Path;

use crossterm::{
    queue,
    style::{Attribute, Color, ContentStyle, Print, SetAttribute, SetForegroundColor, SetStyle},
};

use super::{Error, VestiErr};
use crate::location::Span;

const BOLD_TEXT: SetAttribute = SetAttribute(Attribute::Bold);
const ERR_COLOR: SetForegroundColor = SetForegroundColor(Color::Red);
const BLUE_COLOR: SetForegroundColor = SetForegroundColor(Color::DarkBlue);
const RESET_STYLE: SetAttribute = SetAttribute(Attribute::Reset);

pub fn pretty_print(
    source: Option<&str>,
    vesti_error: VestiErr,
    filepath: Option<&Path>,
) -> io::Result<()> {
    let mut stdout = BufWriter::new(io::stdout());
    let err_title_color: SetStyle = SetStyle(ContentStyle {
        foreground_color: Some(Color::White),
        attributes: Attribute::Bold.into(),
        ..Default::default()
    });

    let lines = source.map(|inner| inner.lines());
    let err_code = vesti_error.err_code();
    let err_str = vesti_error.err_str();

    queue!(
        stdout,
        BOLD_TEXT,
        ERR_COLOR,
        Print(format!(" error[E{0:04X}]", err_code)),
        err_title_color,
        Print(format!(": {}\n", err_str)),
        RESET_STYLE,
    )?;

    if let VestiErr::ParseErr {
        location: Span { start, end },
        ..
    } = &vesti_error
    {
        let start_row_num = format!("{} ", start.row());

        // If the filepath of the given input one is found, print it with error location
        if let Some(m_filepath) = filepath {
            queue!(
                stdout,
                Print(" ".repeat(start_row_num.len())),
                BOLD_TEXT,
                BLUE_COLOR,
                Print("--> "),
                RESET_STYLE,
                Print(m_filepath.to_str().unwrap()),
                Print(format!(":{}:{}\n", start.row(), start.column())),
            )?;
        }

        queue!(
            stdout,
            BOLD_TEXT,
            BLUE_COLOR,
            Print(" ".repeat(start_row_num.len().saturating_add(1))),
            Print("|\n "),
            Print(&start_row_num),
            Print("|   "),
            RESET_STYLE,
        )?;
        if let Some(mut inner) = lines {
            queue!(stdout, Print(inner.nth(start.row() - 1).unwrap()))?;
        }
        queue!(stdout, Print("\n"))?;

        // Print an error message with multiple lines
        let padding_space = end.column().saturating_sub(start.column()) + 1;
        queue!(
            stdout,
            BOLD_TEXT,
            BLUE_COLOR,
            Print(" ".repeat(start_row_num.len().saturating_add(1))),
            Print("|   "),
            Print(" ".repeat(start.column().saturating_sub(1))),
            ERR_COLOR,
            Print("^".repeat(end.column().saturating_sub(start.column()))),
            Print(" "),
        )?;

        for (i, msg) in vesti_error.err_detail_str().iter().enumerate() {
            if i == 0 {
                queue!(stdout, Print(msg), Print("\n"))?;
            } else {
                queue!(
                    stdout,
                    BOLD_TEXT,
                    BLUE_COLOR,
                    Print(" ".repeat(start_row_num.len().saturating_add(1))),
                    Print("|   "),
                    Print(" ".repeat(start.column().saturating_sub(1))),
                    ERR_COLOR,
                    Print(" ".repeat(padding_space)),
                    Print(msg),
                    Print("\n"),
                )?;
            }
        }
    }
    queue!(stdout, RESET_STYLE)?;

    stdout.flush()?;

    Ok(())
}

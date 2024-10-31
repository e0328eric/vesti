#[derive(Clone, Copy, PartialEq, Default, Debug)]
pub struct Span {
    pub start: Location,
    pub end: Location,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Location {
    row: usize,
    col: usize,
}

impl Location {
    pub fn row(&self) -> usize {
        self.row
    }

    pub fn column(&self) -> usize {
        self.col
    }

    pub fn move_right(&mut self, current_char: Option<&char>) {
        match current_char {
            Some(chr) => {
                self.col += unicode_width::UnicodeWidthChar::width(*chr).unwrap_or_default()
            }
            _ => self.col += 1,
        }
    }

    pub fn move_next_line(&mut self) {
        self.row += 1;
        self.col = 1;
    }

    pub fn reset_location(&mut self) {
        self.row = 1;
        self.col = 1;
    }
}

impl Default for Location {
    fn default() -> Self {
        Self { row: 1, col: 1 }
    }
}

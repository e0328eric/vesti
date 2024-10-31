use std::str::Chars;

#[derive(Clone)]
pub struct Newlinehandler<'a> {
    source: Chars<'a>,
    chr0: Option<char>,
    chr1: Option<char>,
}

impl<'a> Newlinehandler<'a> {
    pub fn new<T: AsRef<str> + ?Sized>(source: &'a T) -> Self {
        let mut nlh = Self {
            source: source.as_ref().chars(),
            chr0: None,
            chr1: None,
        };
        nlh.next_char();
        nlh.next_char();
        nlh
    }

    fn next_char(&mut self) {
        self.chr0 = self.chr1;
        self.chr1 = self.source.next();
    }
}

impl<'a> Iterator for Newlinehandler<'a> {
    type Item = char;
    fn next(&mut self) -> Option<Self::Item> {
        let output = match (self.chr0, self.chr1) {
            (Some('\r'), Some('\n')) => {
                self.next_char();
                self.chr0
            }
            (Some('\r'), _) => Some('\n'),
            _ => self.chr0,
        };
        self.next_char();
        output
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_newline_handler() {
        let input = Newlinehandler::new("\t\r\r\n\r\r\n\n\r").collect::<String>();
        let expected = "\t\n\n\n\n\n\n";
        assert_eq!(input.as_str(), expected);
    }
}

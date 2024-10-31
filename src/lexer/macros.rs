macro_rules! tokenize {
    ($self: ident: $toktype: ident, $literal: expr; $start: expr) => {{
        $self.next_char();
        Token {
            toktype: TokenType::$toktype,
            literal: String::from($literal),
            span: Span {
                start: $start,
                end: $self.current_loc,
            },
        }
    }};
}

macro_rules! unwrap {
    ($self: ident: $char: ident, $loc: expr) => {
        match $self.$char {
            Some(chr) => chr,
            None => return Token::eof($loc, $self.current_loc),
        }
    };
}

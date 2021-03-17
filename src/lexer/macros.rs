#[macro_export]
macro_rules! tokenize {
    ($self: ident | $toktype: ident, $literal: expr; $start: expr) => {{
        $self.next_char();
        Some(LexToken {
            token: Token {
                toktype: TokenType::$toktype,
                literal: String::from($literal),
            },
            span: Span {
                start: $start,
                end: $self.current_loc,
            },
        })
    }};
}

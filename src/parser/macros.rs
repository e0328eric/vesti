macro_rules! expect_peek {
    ($self: ident: $expect: expr; $span: expr) => {
        let tok_tmp = $self.next_tok();
        if tok_tmp.toktype != $expect {
            return Err(VestiErr::ParseErr {
                err_kind: VestiParseErrKind::TypeMismatch {
                    expected: vec![$expect],
                    got: tok_tmp.toktype,
                },
                location: $span,
            });
        }
    };
}

macro_rules! take_name {
    (let $name: ident: String = $self: ident) => {
        let mut tmp = String::new();
        while $self.peek_tok().can_pkg_name() {
            tmp += &match $self.peek_tok() {
                TokenType::Text => $self.next_tok().literal,
                TokenType::Minus => $self.next_tok().literal,
                TokenType::Integer => $self.next_tok().literal,
                TokenType::Eof => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::EOFErr,
                        $self.peek_tok_location(),
                    ));
                }
                toktype => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErrKind::TypeMismatch {
                            expected: vec![TokenType::Text, TokenType::Minus, TokenType::Integer],
                            got: toktype,
                        },
                        $self.peek_tok_location(),
                    ));
                }
            };
        }
        let $name = tmp;
    };
}

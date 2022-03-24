macro_rules! expect_peek {
    ($self:ident | $($expect: expr),+; $span: expr) => {
        let tok_tmp = if let Some(tok) = $self.next_tok() {
            tok
        } else {
            return Err(VestiErr {
                err_kind: VestiErrKind::ParseErr(VestiParseErr::EOFErr),
                location: $span,
            });
        };
        let mut expected = false;
        $( if tok_tmp.token.toktype == $expect { expected = true; })+
        if !expected {
            return Err(VestiErr {
                err_kind: VestiErrKind::ParseErr(VestiParseErr::TypeMismatch {
                    expected: vec![$($expect),+],
                    got: tok_tmp.token.toktype,
                }),
                location: $span,
            });
        }
    };
}

macro_rules! take_name {
    ($self: ident | define $name: ident) => {
        let mut tmp = String::new();
        while $self
            .peek_tok()
            .map_or(false, |toktype| toktype.can_pkg_name())
        {
            tmp += &match $self.peek_tok() {
                Some(TokenType::Text) => $self.next_tok().unwrap().token.literal,
                Some(TokenType::Minus) => $self.next_tok().unwrap().token.literal,
                Some(TokenType::Integer) => $self.next_tok().unwrap().token.literal,
                Some(toktype) => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErr::TypeMismatch {
                            expected: vec![TokenType::Text],
                            got: toktype,
                        },
                        $self.peek_tok_location(),
                    ));
                }
                None => {
                    return Err(VestiErr::make_parse_err(
                        VestiParseErr::ParseFloatErr,
                        $self.peek_tok_location(),
                    ));
                }
            };
        }
        let $name = tmp;
    };
    ($self: ident | define $name: ident as mut; $location: expr) => {
        let mut $name = if $self.peek_tok() == Some(TokenType::Text) {
            $self.next_tok().unwrap().token.literal
        } else if let Some(_) = $self.peek_tok() {
            return Err(VestiErr::make_parse_err(
                VestiParseErr::BegenvNameMissErr,
                $location,
            ));
        } else {
            return Err(VestiErr::make_parse_err(VestiParseErr::EOFErr, $location));
        };
    };
}

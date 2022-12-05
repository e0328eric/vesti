// Copyright (c) 2022 Sungbae Jeong
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

use super::*;

macro_rules! expected {
    ($source: ident should be $expected: ident) => {{
        let mut parser = Parser::new(Lexer::new($source));
        assert_eq!($expected, make_latex_format::<true>(&mut parser).unwrap());
    }};
}

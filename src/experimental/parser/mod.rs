// Copyright (c) 2022 Sungbae Jeong
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

#[cfg(test)]
// mod parser_test;
#[macro_use]
mod macros;
pub mod ast;

// const ENV_MATH_IDENT: [&str; 6] = [
//     "equation", "align", "array", "eqnarray", "gather", "multline",
// ];

use std::mem::MaybeUninit;

use crate::experimental::error::{self, VestiErr, VestiParseErrKind};
use crate::experimental::lexer::token::Token;
use crate::experimental::lexer::token::TokenType;
use crate::experimental::lexer::Lexer;
use crate::location::Span;
use ast::*;

//! Proc-macros for vesti.
//!
//! [`builtin_set!`] takes a single list of builtin names (the source of truth,
//! kept in `token.rs`) and generates, at compile time:
//!
//! 1. `const <NAMES>: &[&str]` — the names as data.
//! 2. `fn <is_fn>(name: &str) -> bool` — a `matches!` membership test.
//! 3. `macro_rules! <dispatch>` — a dispatcher whose arms map each name to a
//!    method call `recv.<prefix><name>(args...)`, re-exported with
//!    `pub(crate) use` so the dispatch site can invoke it.
//!
//! See the crate-level docs. Example:
//!
//! ```ignore
//! vesti_macros::builtin_set!(
//!     pub is_builtin, BUILTIN_NAMES, dispatch_builtin, parse_builtin_,
//!     [ "chardef", "label", "eq" ]
//! );
//! ```
//!
//! generates `BUILTIN_NAMES`, `is_builtin`, and a `dispatch_builtin!` macro so
//! that
//!
//! ```ignore
//! crate::lexer::token::dispatch_builtin!(self, name, (), { /* default */ })
//! ```
//!
//! expands to `match name { "chardef" => self.parse_builtin_chardef(), … }`.

use proc_macro::TokenStream;
use std::collections::HashMap;

use quote::{format_ident, quote};
use syn::parse::{Parse, ParseStream};
use syn::punctuated::Punctuated;
use syn::{Ident, LitStr, Token, Visibility, bracketed};

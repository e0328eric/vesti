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
use std::collections::HashSet;

use quote::{format_ident, quote};
use syn::parse::{Parse, ParseStream};
use syn::punctuated::Punctuated;
use syn::{Ident, LitStr, Token, Visibility, bracketed};

/// Parsed form of
/// `builtin_set!(<vis> is_fn, CONST, dispatch, method_prefix, ["a", "b", …])`.
struct BuiltinSet {
    vis: Visibility,
    is_fn: Ident,
    const_name: Ident,
    dispatch_name: Ident,
    method_prefix: Ident,
    names: Vec<LitStr>,
}

impl Parse for BuiltinSet {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        let vis: Visibility = input.parse()?;
        let is_fn: Ident = input.parse()?;
        input.parse::<Token![,]>()?;
        let const_name: Ident = input.parse()?;
        input.parse::<Token![,]>()?;
        let dispatch_name: Ident = input.parse()?;
        input.parse::<Token![,]>()?;
        let method_prefix: Ident = input.parse()?;
        input.parse::<Token![,]>()?;

        let content;
        bracketed!(content in input);
        let punct: Punctuated<LitStr, Token![,]> =
            content.parse_terminated(<LitStr as Parse>::parse, Token![,])?;
        let _ = input.parse::<Token![,]>(); // optional trailing comma

        Ok(BuiltinSet {
            vis,
            is_fn,
            const_name,
            dispatch_name,
            method_prefix,
            names: punct.into_iter().collect(),
        })
    }
}

#[proc_macro]
pub fn builtin_set(input: TokenStream) -> TokenStream {
    let BuiltinSet {
        vis,
        is_fn,
        const_name,
        dispatch_name,
        method_prefix,
        names,
    } = syn::parse_macro_input!(input as BuiltinSet);

    if names.is_empty() {
        return syn::Error::new(is_fn.span(), "builtin_set! needs at least one name")
            .to_compile_error()
            .into();
    }

    // Reject duplicate names at compile time, pointing at the repeat.
    let mut seen: HashSet<String> = HashSet::with_capacity(names.len());
    for lit in &names {
        if !seen.insert(lit.value()) {
            return syn::Error::new(
                lit.span(),
                format!("duplicate builtin name `{}`", lit.value()),
            )
            .to_compile_error()
            .into();
        }
    }

    let lits = &names;

    // One match arm per name: `"chardef" => $recv.parse_builtin_chardef( $($arg),* ),`
    // The `$recv` / `$arg` tokens are literal macro-variable references emitted
    // into the generated `macro_rules!` (quote leaves `$` untouched).
    let arms = names.iter().map(|lit| {
        let method = format_ident!("{}_{}", method_prefix, lit.value());
        quote! { #lit => $recv.#method( $($arg),* ), }
    });

    let is_doc = format!("True if `name` is one of the `{const_name}` builtins.");
    let dispatch_doc = format!(
        "Dispatch on a `{const_name}` builtin name. \
         Usage: `{dispatch_name}!(recv, scrutinee, (args...), default_expr)`."
    );

    let expanded = quote! {
        #[doc = #is_doc]
        #vis const #const_name: &[&str] = &[ #( #lits ),* ];

        #[inline]
        #vis fn #is_fn(name: &str) -> bool {
            matches!(name, #( #lits )|* )
        }

        #[doc = #dispatch_doc]
        macro_rules! #dispatch_name {
            ($recv:expr, $scrut:expr, ( $($arg:expr),* $(,)? ), $default:expr) => {
                match $scrut {
                    #( #arms )*
                    _ => $default,
                }
            };
        }
        pub(crate) use #dispatch_name;
    };

    expanded.into()
}

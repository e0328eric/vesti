use super::*;

#[test]
fn test_lexing_symbols() {
    let source = "+-/*!@&^;:.`|'~";
    let expected_toktype = vec![
        TokenType::Plus,
        TokenType::Minus,
        TokenType::Slash,
        TokenType::Star,
        TokenType::Bang,
        TokenType::At,
        TokenType::Ampersand,
        TokenType::Superscript,
        TokenType::Semicolon,
        TokenType::Colon,
        TokenType::Period,
        TokenType::Quote2,
        TokenType::Vert,
        TokenType::Quote,
        TokenType::Tilde,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, source.to_string());
}

#[test]
fn test_lexing_whitespaces() {
    let source = "\t  \t\n\r\n \t\r";
    let expected_toktype = vec![
        TokenType::Tab,
        TokenType::Space,
        TokenType::Space,
        TokenType::Tab,
        TokenType::Newline,
        TokenType::Newline,
        TokenType::Space,
        TokenType::Tab,
        TokenType::Newline,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, "\t  \t\n\n \t\n");
}

#[test]
fn test_lexing_comment() {
    let source = r#"
# This is a comment!
----
#* This is also a comment.
The difference is that multiple commenting is possible.
*#+"#;
    let expected_toktype = vec![
        TokenType::Newline,
        TokenType::Minus,
        TokenType::Minus,
        TokenType::Minus,
        TokenType::Minus,
        TokenType::Newline,
        TokenType::Plus,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    assert_eq!(lexed_token, expected_toktype);
}

#[test]
fn test_text_raw_latex() {
    let source = "#-\\TeX and \\LaTeX-##-foo 3.14-#";
    let expected_toktype = vec![TokenType::RawLatex, TokenType::RawLatex];
    let expected_literal = "\\TeX and \\LaTeXfoo 3.14";
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, expected_literal);
}

#[test]
fn test_inline_raw_latex() {
    let source = r#"##-
\begin{center}
  the \TeX
\end{center}
-##"#;
    let expected_toktype = vec![TokenType::RawLatex];
    let expected_literal = r#"
\begin{center}
  the \TeX
\end{center}
"#;
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, expected_literal);
}

#[test]
fn test_lexing_ascii_string() {
    let source = "This is a string!";
    let expected_toktype = vec![
        TokenType::MainString,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Bang,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, source.to_string());
}

#[test]
fn test_lexing_unicode_string() {
    let source = "????????? ?????????????";
    let expected_toktype = vec![
        TokenType::MainString,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Question,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, source.to_string());
}

#[test]
fn test_lex_number() {
    let source = "1 32 -8432 3.2 0.3 32.00";
    let expected_toktype = vec![
        TokenType::Integer,
        TokenType::Space,
        TokenType::Integer,
        TokenType::Space,
        TokenType::Integer,
        TokenType::Space,
        TokenType::Float,
        TokenType::Space,
        TokenType::Float,
        TokenType::Space,
        TokenType::Float,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, source.to_string());
}

#[test]
fn lexing_keywords() {
    let source = "docclass begenv document mtxt import etxt endenv";
    let expected_toktype = vec![
        TokenType::Docclass,
        TokenType::Space,
        TokenType::Begenv,
        TokenType::Space,
        TokenType::Document,
        TokenType::Space,
        TokenType::Mtxt,
        TokenType::Space,
        TokenType::Import,
        TokenType::Space,
        TokenType::Etxt,
        TokenType::Space,
        TokenType::Endenv,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, source.to_string());
}

#[test]
fn test_lexing_math_delimiter() {
    let source = "$ $ $$ $$ $ $$ $ \\) \\[ \\] \\( $";
    let expected_toktype = vec![
        TokenType::TextMathStart,
        TokenType::Space,
        TokenType::TextMathEnd,
        TokenType::Space,
        TokenType::InlineMathStart,
        TokenType::Space,
        TokenType::InlineMathEnd,
        TokenType::Space,
        TokenType::TextMathStart,
        TokenType::Space,
        TokenType::InlineMathEnd,
        TokenType::Space,
        TokenType::TextMathStart,
        TokenType::Space,
        TokenType::TextMathEnd,
        TokenType::Space,
        TokenType::InlineMathStart,
        TokenType::Space,
        TokenType::InlineMathEnd,
        TokenType::Space,
        TokenType::TextMathStart,
        TokenType::Space,
        TokenType::TextMathEnd,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, "$ $ \\[ \\] $ \\] $ $ \\[ \\] $ $");
}

#[test]
fn lexing_latex_functions() {
    let source = "\\foo \\bar@hand";
    let expected_toktype = vec![
        TokenType::LatexFunction,
        TokenType::Space,
        TokenType::LatexFunction,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, "foo bar@hand");
}

#[test]
fn basic_vesti() {
    let source = r#"docclass coprime (tikz, korean)
import {
    geometry (a4paper, margin = 0.4in),
    amsmath,
}

document

This is a \LaTeX!
$$
    1 + 1 = \sum_{j=1}^\infty f(x),\qquad mtxt foobar etxt
$$
begenv center
    The TeX
endenv"#;
    let expected_literal = r#"docclass coprime (tikz, korean)
import {
    geometry (a4paper, margin = 0.4in),
    amsmath,
}

document

This is a LaTeX!
\[
    1 + 1 = sum_{j=1}^infty f(x),qquad mtxt foobar etxt
\]
begenv center
    The TeX
endenv"#;
    let expected_toktype = vec![
        TokenType::Docclass,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Space,
        TokenType::Lparen,
        TokenType::MainString,
        TokenType::Comma,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Rparen,
        TokenType::Newline,
        TokenType::Import,
        TokenType::Space,
        TokenType::Lbrace,
        TokenType::Newline,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Space,
        TokenType::Lparen,
        TokenType::MainString,
        TokenType::Comma,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Space,
        TokenType::Equal,
        TokenType::Space,
        TokenType::Float,
        TokenType::MainString,
        TokenType::Rparen,
        TokenType::Comma,
        TokenType::Newline,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Comma,
        TokenType::Newline,
        TokenType::Rbrace,
        TokenType::Newline,
        TokenType::Newline,
        TokenType::Document,
        TokenType::Newline,
        TokenType::Newline,
        TokenType::MainString,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Space,
        TokenType::LatexFunction,
        TokenType::Bang,
        TokenType::Newline,
        TokenType::InlineMathStart,
        TokenType::Newline,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::Integer,
        TokenType::Space,
        TokenType::Plus,
        TokenType::Space,
        TokenType::Integer,
        TokenType::Space,
        TokenType::Equal,
        TokenType::Space,
        TokenType::LatexFunction,
        TokenType::Subscript,
        TokenType::Lbrace,
        TokenType::MainString,
        TokenType::Equal,
        TokenType::Integer,
        TokenType::Rbrace,
        TokenType::Superscript,
        TokenType::LatexFunction,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Lparen,
        TokenType::MainString,
        TokenType::Rparen,
        TokenType::Comma,
        TokenType::LatexFunction,
        TokenType::Space,
        TokenType::Mtxt,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Space,
        TokenType::Etxt,
        TokenType::Newline,
        TokenType::InlineMathEnd,
        TokenType::Newline,
        TokenType::Begenv,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Newline,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Space,
        TokenType::MainString,
        TokenType::Newline,
        TokenType::Endenv,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.token.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.token.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, expected_literal);
}

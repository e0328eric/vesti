use super::*;

#[test]
fn test_lexing_single_symbols() {
    let source = "+*;:\"'`|=<?!,.~#";
    let expected_toktype = vec![
        TokenType::Plus,
        TokenType::Star,
        TokenType::Semicolon,
        TokenType::Colon,
        TokenType::DoubleQuote,
        TokenType::RightQuote,
        TokenType::LeftQuote,
        TokenType::Vert,
        TokenType::Equal,
        TokenType::Less,
        TokenType::Question,
        TokenType::Bang,
        TokenType::Comma,
        TokenType::Period,
        TokenType::Tilde,
        TokenType::FntParam,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, source.to_string());
}

#[test]
fn test_lexing_double_symbols() {
    let source = "$!-->$->$<-$<-$>=<=@!%!";
    let expected_toktype = vec![
        TokenType::Dollar,
        TokenType::Minus,
        TokenType::Minus,
        TokenType::Great,
        TokenType::TextMathStart,
        TokenType::RightArrow,
        TokenType::TextMathEnd,
        TokenType::Less,
        TokenType::Minus,
        TokenType::TextMathStart,
        TokenType::LeftArrow,
        TokenType::TextMathEnd,
        TokenType::GreatEq,
        TokenType::LessEq,
        TokenType::At,
        TokenType::LatexComment,
    ];
    let expected_literal = "$-->$\\rightarrow $<-$\\leftarrow $>=<=@%";
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, expected_literal.to_string());
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
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, "\t  \t\n\n \t\n");
}

#[test]
fn test_lexing_comment() {
    let source = r#"
% This is a comment!
----
%* This is also a comment.
The difference is that multiple commenting is possible.
*%+"#;
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
    let lexed_token = lex.map(|lextok| lextok.toktype).collect::<Vec<TokenType>>();
    assert_eq!(lexed_token, expected_toktype);
}

#[test]
fn test_text_raw_latex() {
    let source = "%-\\TeX and \\LaTeX-%%-foo 3.14-%";
    let expected_toktype = vec![TokenType::RawLatex, TokenType::RawLatex];
    let expected_literal = "\\TeX and \\LaTeXfoo 3.14";
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, expected_literal);
}

#[test]
fn test_inline_raw_latex() {
    let source = r#"%-
\begin{center}
  the \TeX
\end{center}
-%"#;
    let expected_toktype = vec![TokenType::RawLatex];
    let expected_literal = r#"
\begin{center}
  the \TeX
\end{center}
"#;
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, expected_literal);
}

#[test]
fn test_lexing_ascii_string() {
    let source = "This is a string!";
    let expected_toktype = vec![
        TokenType::Text,
        TokenType::Space,
        TokenType::Text,
        TokenType::Space,
        TokenType::Text,
        TokenType::Space,
        TokenType::Text,
        TokenType::Bang,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, source.to_string());
}

#[test]
fn test_lexing_unicode_string() {
    let source = "이것은 무엇인가?";
    let expected_toktype = vec![
        TokenType::Text,
        TokenType::Space,
        TokenType::Text,
        TokenType::Question,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
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
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, source.to_string());
}

#[test]
fn lexing_keywords() {
    let source = "docclass begenv startdoc mtxt import etxt endenv";
    let expected_toktype = vec![
        TokenType::Docclass,
        TokenType::Space,
        TokenType::Begenv,
        TokenType::Space,
        TokenType::StartDoc,
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
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, source.to_string());
}

#[test]
fn lexing_backslash() {
    let source = "\\#\\$\\)\\%";
    let expected_toktype = vec![
        TokenType::Sharp,
        TokenType::Dollar,
        TokenType::TextMathEnd,
        TokenType::Percent,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    assert_eq!(lexed_token, expected_toktype);
}

#[test]
fn lexing_latex_functions() {
    let source = "\\foo \\bar@hand \\frac{a @ b}";
    let expected_toktype = vec![
        TokenType::LatexFunction,
        TokenType::Space,
        TokenType::LatexFunction,
        TokenType::Space,
        TokenType::LatexFunction,
        TokenType::Lbrace,
        TokenType::Text,
        TokenType::ArgSpliter,
        TokenType::Space,
        TokenType::Text,
        TokenType::Rbrace,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, "\\foo \\bar@hand \\frac{a b}");
}

#[test]
fn basic_vesti() {
    let source = r#"docclass coprime (tikz, korean)
import {
    geometry (a4paper, margin = 0.4in),
    amsmath,
}

startdoc

This is a \LaTeX!
\[
    1 + 1 = \sum_{j=1}^\infty f(x),\qquad mtxt foobar etxt
\]
begenv center %[adadasdawd]
    The TeX
endenv"#;
    let expected_literal = r#"docclass coprime (tikz, korean)
import {
    geometry (a4paper, margin = 0.4in),
    amsmath,
}

startdoc

This is a \LaTeX!
\[
    1 + 1 = \sum_{j=1}^\infty f(x),\qquad mtxt foobar etxt
\]
begenv center     The TeX
endenv"#;
    let expected_toktype = vec![
        TokenType::Docclass,
        TokenType::Space,
        TokenType::Text,
        TokenType::Space,
        TokenType::Lparen,
        TokenType::Text,
        TokenType::Comma,
        TokenType::Space,
        TokenType::Text,
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
        TokenType::Text,
        TokenType::Space,
        TokenType::Lparen,
        TokenType::Text,
        TokenType::Comma,
        TokenType::Space,
        TokenType::Text,
        TokenType::Space,
        TokenType::Equal,
        TokenType::Space,
        TokenType::Float,
        TokenType::Text,
        TokenType::Rparen,
        TokenType::Comma,
        TokenType::Newline,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::Text,
        TokenType::Comma,
        TokenType::Newline,
        TokenType::Rbrace,
        TokenType::Newline,
        TokenType::Newline,
        TokenType::StartDoc,
        TokenType::Newline,
        TokenType::Newline,
        TokenType::Text,
        TokenType::Space,
        TokenType::Text,
        TokenType::Space,
        TokenType::Text,
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
        TokenType::Text,
        TokenType::Equal,
        TokenType::Integer,
        TokenType::Rbrace,
        TokenType::Superscript,
        TokenType::LatexFunction,
        TokenType::Space,
        TokenType::Text,
        TokenType::Lparen,
        TokenType::Text,
        TokenType::Rparen,
        TokenType::Comma,
        TokenType::LatexFunction,
        TokenType::Space,
        TokenType::Mtxt,
        TokenType::Space,
        TokenType::Text,
        TokenType::Space,
        TokenType::Etxt,
        TokenType::Newline,
        TokenType::InlineMathEnd,
        TokenType::Newline,
        TokenType::Begenv,
        TokenType::Space,
        TokenType::Text,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::Space,
        TokenType::Text,
        TokenType::Space,
        TokenType::Text,
        TokenType::Newline,
        TokenType::Endenv,
    ];
    let lex = Lexer::new(source);
    let lexed_token = lex
        .clone()
        .map(|lextok| lextok.toktype)
        .collect::<Vec<TokenType>>();
    let lexed_literal = lex
        .map(|lextok| lextok.literal)
        .collect::<Vec<String>>()
        .concat();
    assert_eq!(lexed_token, expected_toktype);
    assert_eq!(lexed_literal, expected_literal);
}

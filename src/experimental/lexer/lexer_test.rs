// Copyright (c) 2022 Sungbae Jeong
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

use super::*;

macro_rules! lexing {
    ($lex: ident) => {{
        let mut lexed = Vec::new();
        let mut token;
        loop {
            token = $lex.next();
            match token.toktype {
                TokenType::Eof => break lexed,
                TokenType::Illegal => panic!(
                    "illegal token {:?} was found on {:?}",
                    $lex.chr0, token.span
                ),
                _ => {}
            }
            lexed.push(token);
        }
    }};
}

macro_rules! token {
    ($toktype: expr, $literal: literal) => {
        Token {
            toktype: $toktype,
            literal: $literal.to_string(),
            span: Span::default(),
        }
    };
}

fn check_same(toks1: Vec<Token>, toks2: Vec<Token>) -> bool {
    if toks1.len() != toks2.len() {
        println!("length expected {:?}, got {:?}", toks1.len(), toks2.len());
        return false;
    }

    for (tok1, tok2) in toks1.into_iter().zip(toks2) {
        if tok1.toktype != tok2.toktype {
            println!("token expected {:?}, got {:?}", tok1.toktype, tok2.toktype);
            return false;
        }
        if tok1.literal != tok2.literal {
            println!(
                "literal expected {:?}, got {:?}",
                tok1.literal, tok2.literal
            );
            return false;
        }
    }

    true
}

#[test]
fn test_lexing_single_symbols() {
    let source = "+*;:\"'`|=<?!,.~#";
    let expected = vec![
        token!(TokenType::Plus, "+"),
        token!(TokenType::Star, "*"),
        token!(TokenType::Semicolon, ";"),
        token!(TokenType::Colon, ":"),
        token!(TokenType::DoubleQuote, "\""),
        token!(TokenType::RightQuote, "'"),
        token!(TokenType::LeftQuote, "`"),
        token!(TokenType::Vert, "|"),
        token!(TokenType::Equal, "="),
        token!(TokenType::Less, "<"),
        token!(TokenType::Question, "?"),
        token!(TokenType::Bang, "!"),
        token!(TokenType::Comma, ","),
        token!(TokenType::Period, "."),
        token!(TokenType::Tilde, "~"),
        token!(TokenType::FntParam, "#"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn test_lexing_double_symbols() {
    let source = "$!-->$->$<-$<-$>=<=@!%!";
    let expected = vec![
        token!(TokenType::RawDollar, "$"),
        token!(TokenType::Minus, "-"),
        token!(TokenType::Minus, "-"),
        token!(TokenType::Great, ">"),
        token!(TokenType::TextMathStart, "$"),
        token!(TokenType::RightArrow, "\\rightarrow "),
        token!(TokenType::TextMathEnd, "$"),
        token!(TokenType::Less, "<"),
        token!(TokenType::Minus, "-"),
        token!(TokenType::TextMathStart, "$"),
        token!(TokenType::LeftArrow, "\\leftarrow "),
        token!(TokenType::TextMathEnd, "$"),
        token!(TokenType::GreatEq, "\\geq "),
        token!(TokenType::LessEq, "\\leq "),
        token!(TokenType::At, "@"),
        token!(TokenType::LatexComment, "%"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn test_lexing_whitespaces() {
    let source = "\t  \t\n\r\n \t\r";
    let expected = vec![
        token!(TokenType::Tab, "\t"),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Tab, "\t"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Space, " "),
        token!(TokenType::Tab, "\t"),
        token!(TokenType::Newline, "\n"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn test_lexing_comment() {
    let source = r#"
% This is a comment!
----
%* This is also a comment.
The difference is that multiple commenting is possible.
*%+"#;
    let expected = vec![
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Minus, "-"),
        token!(TokenType::Minus, "-"),
        token!(TokenType::Minus, "-"),
        token!(TokenType::Minus, "-"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Plus, "+"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn test_text_raw_latex() {
    let source = "%-\\TeX and \\LaTeX-%%-foo 3.14-%";
    let expected = vec![
        token!(TokenType::RawLatex, "\\TeX and \\LaTeX"),
        token!(TokenType::RawLatex, "foo 3.14"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn test_inline_raw_latex() {
    let source = r#"%-
\begin{center}
  the \TeX
\end{center}
-%"#;
    let expected = vec![token!(
        TokenType::RawLatex,
        r#"
\begin{center}
  the \TeX
\end{center}
"#
    )];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn test_lexing_ascii_string() {
    let source = "This is a string!";
    let expected = vec![
        token!(TokenType::Text, "This"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "is"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "a"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "string"),
        token!(TokenType::Bang, "!"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn test_lexing_math_character() {
    let source = "$ $\\[\\]\\[[\\]";
    let expected = vec![
        token!(TokenType::TextMathStart, "$"),
        token!(TokenType::Space, " "),
        token!(TokenType::TextMathEnd, "$"),
        token!(TokenType::InlineMathStart, "\\["),
        token!(TokenType::InlineMathEnd, "\\]"),
        token!(TokenType::InlineMathStart, "\\["),
        token!(TokenType::LeftSquareBrace, "["),
        token!(TokenType::InlineMathEnd, "\\]"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn test_lexing_unicode_string() {
    let source = "이것은 무엇인가?";
    let expected = vec![
        token!(TokenType::Text, "이것은"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "무엇인가"),
        token!(TokenType::Question, "?"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn test_lex_number() {
    let source = "1 32 -8432 3.2 0.3 32.00 3.20";
    let expected = vec![
        token!(TokenType::Integer, "1"),
        token!(TokenType::Space, " "),
        token!(TokenType::Integer, "32"),
        token!(TokenType::Space, " "),
        token!(TokenType::Integer, "-8432"),
        token!(TokenType::Space, " "),
        token!(TokenType::Float, "3.2"),
        token!(TokenType::Space, " "),
        token!(TokenType::Float, "0.3"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "32.00"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "3.20"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn lexing_keywords() {
    let source = "docclass begenv startdoc mtxt vesmod etxt endenv";
    let expected = vec![
        token!(TokenType::Docclass, "docclass"),
        token!(TokenType::Space, " "),
        token!(TokenType::BeginEnv, "begenv"),
        token!(TokenType::Space, " "),
        token!(TokenType::StartDoc, "startdoc"),
        token!(TokenType::Space, " "),
        token!(TokenType::Mtxt, "mtxt"),
        token!(TokenType::Space, " "),
        token!(TokenType::VestiMod, "vesmod"),
        token!(TokenType::Space, " "),
        token!(TokenType::Etxt, "etxt"),
        token!(TokenType::Space, " "),
        token!(TokenType::EndEnv, "endenv"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn lexing_backslash() {
    let source = "\\#\\$\\)\\%";
    let expected = vec![
        token!(TokenType::Sharp, "\\#"),
        token!(TokenType::Dollar, "\\$"),
        token!(TokenType::TextMathEnd, "$"),
        token!(TokenType::Percent, "\\%"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn lexing_latex_functions() {
    let source = "\\foo \\bar@hand \\frac{a; b}";
    let expected = vec![
        token!(TokenType::LatexFunction, "\\foo"),
        token!(TokenType::Space, " "),
        token!(TokenType::LatexFunction, "\\bar@hand"),
        token!(TokenType::Space, " "),
        token!(TokenType::LatexFunction, "\\frac"),
        token!(TokenType::LeftBrace, "{"),
        token!(TokenType::Text, "a"),
        token!(TokenType::Semicolon, ";"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "b"),
        token!(TokenType::RightBrace, "}"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn basic_vesti() {
    let source = r#"docclass coprime (tikz, korean)
ltxpkg {
    geometry (a4paper, margin = 0.4in),
    amsmath,
}

startdoc

This is a \LaTeX!
\[
    1 + 1 = \sum_{j=1}^\infty f(x),\qquad mtxt foobar etxt
\]
begenv center % [adadasdawd]
    The TeX
endenv"#;
    let expected = vec![
        token!(TokenType::Docclass, "docclass"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "coprime"),
        token!(TokenType::Space, " "),
        token!(TokenType::LeftParen, "("),
        token!(TokenType::Text, "tikz"),
        token!(TokenType::Comma, ","),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "korean"),
        token!(TokenType::RightParen, ")"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::LatexPkg, "ltxpkg"),
        token!(TokenType::Space, " "),
        token!(TokenType::LeftBrace, "{"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "geometry"),
        token!(TokenType::Space, " "),
        token!(TokenType::LeftParen, "("),
        token!(TokenType::Text, "a4paper"),
        token!(TokenType::Comma, ","),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "margin"),
        token!(TokenType::Space, " "),
        token!(TokenType::Equal, "="),
        token!(TokenType::Space, " "),
        token!(TokenType::Float, "0.4"),
        token!(TokenType::Text, "in"),
        token!(TokenType::RightParen, ")"),
        token!(TokenType::Comma, ","),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "amsmath"),
        token!(TokenType::Comma, ","),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::RightBrace, "}"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::StartDoc, "startdoc"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Text, "This"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "is"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "a"),
        token!(TokenType::Space, " "),
        token!(TokenType::LatexFunction, "\\LaTeX"),
        token!(TokenType::Bang, "!"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::InlineMathStart, "\\["),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Integer, "1"),
        token!(TokenType::Space, " "),
        token!(TokenType::Plus, "+"),
        token!(TokenType::Space, " "),
        token!(TokenType::Integer, "1"),
        token!(TokenType::Space, " "),
        token!(TokenType::Equal, "="),
        token!(TokenType::Space, " "),
        token!(TokenType::LatexFunction, "\\sum"),
        token!(TokenType::Subscript, "_"),
        token!(TokenType::LeftBrace, "{"),
        token!(TokenType::Text, "j"),
        token!(TokenType::Equal, "="),
        token!(TokenType::Integer, "1"),
        token!(TokenType::RightBrace, "}"),
        token!(TokenType::Superscript, "^"),
        token!(TokenType::LatexFunction, "\\infty"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "f"),
        token!(TokenType::LeftParen, "("),
        token!(TokenType::Text, "x"),
        token!(TokenType::RightParen, ")"),
        token!(TokenType::Comma, ","),
        token!(TokenType::LatexFunction, "\\qquad"),
        token!(TokenType::Space, " "),
        token!(TokenType::Mtxt, "mtxt"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "foobar"),
        token!(TokenType::Space, " "),
        token!(TokenType::Etxt, "etxt"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::InlineMathEnd, "\\]"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::BeginEnv, "begenv"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "center"),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "The"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "TeX"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::EndEnv, "endenv"),
    ];
    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}
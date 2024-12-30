#![allow(clippy::needless_raw_string_hashes)]

use super::*;

macro_rules! lexing {
    ($lex: ident) => {{
        let mut lexed = Vec::new();
        let mut token;
        loop {
            token = $lex.next();
            match token.toktype {
                TokenType::Eof => break lexed,
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
        panic!("length expected {:?}, got {:?}", toks1.len(), toks2.len());
    }

    for (tok1, tok2) in toks1.into_iter().zip(toks2) {
        if tok1.toktype != tok2.toktype {
            panic!("token expected {:?}, got {:?}", tok1.toktype, tok2.toktype);
        }
        if tok1.literal != tok2.literal {
            panic!(
                "literal expected {:?}, got {:?}",
                tok1.literal, tok2.literal
            );
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
    let source = "$!-->$->-->$<-$<->=<=$%!||$||>}<==>$";
    let expected = vec![
        token!(TokenType::RawDollar, "$"),
        token!(TokenType::Minus, "-"),
        token!(TokenType::Minus, "-"),
        token!(TokenType::Great, ">"),
        token!(TokenType::InlineMathStart, "$"),
        token!(TokenType::RightArrow, "\\rightarrow "),
        token!(TokenType::LongRightArrow, "\\longrightarrow "),
        token!(TokenType::InlineMathEnd, "$"),
        token!(TokenType::Less, "<"),
        token!(TokenType::Minus, "-"),
        token!(TokenType::InlineMathStart, "$"),
        token!(TokenType::LeftRightArrow, "\\leftrightarrow "),
        token!(TokenType::Equal, "="),
        token!(TokenType::LessEq, "\\leq "),
        token!(TokenType::InlineMathEnd, "$"),
        token!(TokenType::LatexComment, "%"),
        token!(TokenType::Vert, "|"),
        token!(TokenType::Vert, "|"),
        token!(TokenType::InlineMathStart, "$"),
        token!(TokenType::Norm, "\\|"),
        token!(TokenType::Rangle, "\\rangle "),
        token!(TokenType::LongDoubleLeftRightArrow, "\\Longleftrightarrow "),
        token!(TokenType::InlineMathEnd, "$"),
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
        token!(TokenType::InlineMathStart, "$"),
        token!(TokenType::Space, " "),
        token!(TokenType::InlineMathEnd, "$"),
        token!(TokenType::DisplayMathStart, "\\["),
        token!(TokenType::DisplayMathEnd, "\\]"),
        token!(TokenType::DisplayMathStart, "\\["),
        token!(TokenType::Lsqbrace, "["),
        token!(TokenType::DisplayMathEnd, "\\]"),
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
    let source = "docclass begenv startdoc importpkg endenv ltx3off";
    let expected = vec![
        token!(TokenType::Docclass, "docclass"),
        token!(TokenType::Space, " "),
        token!(TokenType::Begenv, "begenv"),
        token!(TokenType::Space, " "),
        token!(TokenType::StartDoc, "startdoc"),
        token!(TokenType::Space, " "),
        token!(TokenType::ImportPkg, "importpkg"),
        token!(TokenType::Space, " "),
        token!(TokenType::Endenv, "endenv"),
        token!(TokenType::Space, " "),
        token!(TokenType::Latex3Off, "ltx3off"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn lexing_backslash() {
    let source = "\\#\\$\\%";
    let expected = vec![
        token!(TokenType::Sharp, "\\#"),
        token!(TokenType::Dollar, "\\$"),
        token!(TokenType::Percent, "\\%"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn lexing_latex_functions() {
    let source = "\\foo \\bar_hand makeatletter \\bar_hand makeatother \\frac{a}{b}";
    let expected = vec![
        token!(TokenType::LatexFunction, "\\foo"),
        token!(TokenType::Space, " "),
        token!(TokenType::LatexFunction, "\\bar"),
        token!(TokenType::Subscript, "_"),
        token!(TokenType::Text, "hand"),
        token!(TokenType::Space, " "),
        token!(TokenType::MakeAtLetter, "makeatletter"),
        token!(TokenType::Space, " "),
        token!(TokenType::LatexFunction, "\\bar@hand"),
        token!(TokenType::Space, " "),
        token!(TokenType::MakeAtOther, "makeatother"),
        token!(TokenType::Space, " "),
        token!(TokenType::LatexFunction, "\\frac"),
        token!(TokenType::Lbrace, "{"),
        token!(TokenType::Text, "a"),
        token!(TokenType::Rbrace, "}"),
        token!(TokenType::Lbrace, "{"),
        token!(TokenType::Text, "b"),
        token!(TokenType::Rbrace, "}"),
    ];

    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

#[test]
fn basic_vesti() {
    let source = r#"docclass coprime (tikz, korean)
importpkg {
    geometry (a4paper, margin = 0.4in),
    amsmath,
}

startdoc

This is a \LaTeX!
\[
    1 + 1 = \sum_{j=1}^\infty f(x),\qquad "foobar"
\]
begenv center % [adadasdawd]
    The TeX
endenv"#;
    let expected = vec![
        token!(TokenType::Docclass, "docclass"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "coprime"),
        token!(TokenType::Space, " "),
        token!(TokenType::Lparen, "("),
        token!(TokenType::Text, "tikz"),
        token!(TokenType::Comma, ","),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "korean"),
        token!(TokenType::Rparen, ")"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::ImportPkg, "importpkg"),
        token!(TokenType::Space, " "),
        token!(TokenType::Lbrace, "{"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "geometry"),
        token!(TokenType::Space, " "),
        token!(TokenType::Lparen, "("),
        token!(TokenType::Text, "a4paper"),
        token!(TokenType::Comma, ","),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "margin"),
        token!(TokenType::Space, " "),
        token!(TokenType::Equal, "="),
        token!(TokenType::Space, " "),
        token!(TokenType::Float, "0.4"),
        token!(TokenType::Text, "in"),
        token!(TokenType::Rparen, ")"),
        token!(TokenType::Comma, ","),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "amsmath"),
        token!(TokenType::Comma, ","),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Rbrace, "}"),
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
        token!(TokenType::DisplayMathStart, "\\["),
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
        token!(TokenType::Lbrace, "{"),
        token!(TokenType::Text, "j"),
        token!(TokenType::Equal, "="),
        token!(TokenType::Integer, "1"),
        token!(TokenType::Rbrace, "}"),
        token!(TokenType::Superscript, "^"),
        token!(TokenType::LatexFunction, "\\infty"),
        token!(TokenType::Space, " "),
        token!(TokenType::Text, "f"),
        token!(TokenType::Lparen, "("),
        token!(TokenType::Text, "x"),
        token!(TokenType::Rparen, ")"),
        token!(TokenType::Comma, ","),
        token!(TokenType::LatexFunction, "\\qquad"),
        token!(TokenType::Space, " "),
        token!(TokenType::MathTextStart, "\""),
        token!(TokenType::Text, "foobar"),
        token!(TokenType::MathTextEnd, "\""),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::DisplayMathEnd, "\\]"),
        token!(TokenType::Newline, "\n"),
        token!(TokenType::Begenv, "begenv"),
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
        token!(TokenType::Endenv, "endenv"),
    ];
    let mut lex = Lexer::new(source);
    let lexed = lexing!(lex);

    assert!(check_same(lexed, expected));
}

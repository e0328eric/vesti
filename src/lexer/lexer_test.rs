use super::*;

fn types(src: &str) -> Vec<String> {
    let mut lx = Lexer::new(src);
    let mut out = Vec::new();
    loop {
        let t = lx.next();
        let done = matches!(t.toktype(), TokenType::Eof);
        out.push(format!("{:?}", t.toktype()));
        if done {
            break;
        }
    }
    out
}

#[test]
fn keywords_and_text() {
    let mut lx = Lexer::new("docclass useenv foo");
    assert!(matches!(lx.next().toktype(), TokenType::Docclass));
    assert!(matches!(lx.next().toktype(), TokenType::Space));
    assert!(matches!(lx.next().toktype(), TokenType::Useenv));
    assert!(matches!(lx.next().toktype(), TokenType::Space));
    let foo = lx.next();
    assert!(matches!(foo.toktype(), TokenType::Text));
    assert_eq!(foo.in_text(), "foo");
    assert!(matches!(lx.next().toktype(), TokenType::Eof));
}

#[test]
fn arrows_pick_longest() {
    let mut lx = Lexer::new("<==>");
    let t = lx.next();
    assert!(matches!(t.toktype(), TokenType::LongDoubleLeftRightArrow));
    assert_eq!(t.in_math(), "\\Longleftrightarrow ");
    assert!(matches!(lx.next().toktype(), TokenType::Eof));
}

#[test]
fn infinity_vs_text() {
    let mut lx = Lexer::new("oo");
    assert!(matches!(lx.next().toktype(), TokenType::InfinitySym));
    let mut lx = Lexer::new("oox");
    assert!(matches!(lx.next().toktype(), TokenType::Text));
}

#[test]
fn builtin_and_luacode() {
    let mut lx = Lexer::new("#label x");
    let b = lx.next();
    match b.toktype() {
        TokenType::BuiltinFunction(name) => assert_eq!(name, "label"),
        other => panic!("expected builtin, got {other:?}"),
    }
    // the separating space is absorbed into the literal
    assert_eq!(b.in_text(), "#label ");

    let mut lx = Lexer::new("#:: ::#");
    assert!(matches!(lx.next().toktype(), TokenType::LuaCodeStart));
    assert!(matches!(lx.next().toktype(), TokenType::Space));
    assert!(matches!(lx.next().toktype(), TokenType::LuaCodeEnd));
}

#[test]
fn line_comment_is_skipped() {
    let mut lx = Lexer::new("a -- a comment\nb");
    assert_eq!(lx.next().in_text(), "a");
    assert!(matches!(lx.next().toktype(), TokenType::Space));
    // comment skipped, newline consumed by the comment, next real token is `b`
    assert_eq!(lx.next().in_text(), "b");
}

#[test]
fn multiline_comment_is_skipped() {
    let toks = types("x--[==[ hidden ]==]y");
    // x, then y, then Eof (comment fully skipped)
    assert_eq!(toks.len(), 3);
    assert!(toks[0].contains("Text"));
    assert!(toks[1].contains("Text"));
    assert!(toks[2].contains("Eof"));
}

#[test]
fn backslash_forms() {
    let mut lx = Lexer::new(r"\alpha \[ \\");
    assert!(matches!(lx.next().toktype(), TokenType::LatexFunction));
    assert!(matches!(lx.next().toktype(), TokenType::Space));
    assert!(matches!(lx.next().toktype(), TokenType::DisplayMathStart));
    assert!(matches!(lx.next().toktype(), TokenType::Space));
    assert!(matches!(lx.next().toktype(), TokenType::BackSlash));
}

#[test]
fn percent_verbatim() {
    let mut lx = Lexer::new("%- raw \\latex -%rest");
    let t = lx.next();
    assert!(matches!(t.toktype(), TokenType::RawLatex));
    assert_eq!(t.in_text(), " raw \\latex ");
    assert_eq!(lx.next().in_text(), "rest");
}

#[test]
fn numbers() {
    let mut lx = Lexer::new("123 4.5 .5");
    assert!(matches!(lx.next().toktype(), TokenType::Integer));
    assert!(matches!(lx.next().toktype(), TokenType::Space));
    let f = lx.next();
    assert!(matches!(f.toktype(), TokenType::Float));
    assert_eq!(f.in_text(), "4.5");
    assert!(matches!(lx.next().toktype(), TokenType::Space));
    let f = lx.next();
    assert!(matches!(f.toktype(), TokenType::Float));
    assert_eq!(f.in_text(), ".5");
}

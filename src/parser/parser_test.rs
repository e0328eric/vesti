use super::*;

#[test]
fn test_parse_docclass() {
    let source1 = "docclass article";
    let source2 = "docclass standalone (tikz)";
    let source3 = "docclass standalone ( tikz  )";
    let source4 = "docclass coprime (korean, tikz, tcolorbox)";
    let source5 = r#"docclass coprime (
    korean,
    tikz,
    tcolorbox
)"#;
    let source6 = r#"docclass coprime (
    korean,
    tikz,
    tcolorbox,
)"#;

    let expected1 = "\\documentclass{article}\n";
    let expected2 = "\\documentclass[tikz]{standalone}\n";
    let expected3 = "\\documentclass[korean,tikz,tcolorbox]{coprime}\n";

    let mut parser1 = Parser::new(Lexer::new(source1));
    let mut parser2 = Parser::new(Lexer::new(source2));
    let mut parser3 = Parser::new(Lexer::new(source3));
    let mut parser4 = Parser::new(Lexer::new(source4));
    let mut parser5 = Parser::new(Lexer::new(source5));
    let mut parser6 = Parser::new(Lexer::new(source6));
    assert_eq!(expected1, parser1.make_latex_format::<true>().unwrap());
    assert_eq!(expected2, parser2.make_latex_format::<true>().unwrap());
    assert_eq!(expected2, parser3.make_latex_format::<true>().unwrap());
    assert_eq!(expected3, parser4.make_latex_format::<true>().unwrap());
    assert_eq!(expected3, parser5.make_latex_format::<true>().unwrap());
    assert_eq!(expected3, parser6.make_latex_format::<true>().unwrap());
}

#[test]
fn test_parse_usepackage() {
    let source1 = "import kotex";
    let source2 = "import tcolorbox (many)";
    let source3 = "import tcolorbox ( many )";
    let source4 = "import foo (bar1, bar2)";
    let source5 = "import geometry (a4paper, margin = 0.4in)";
    let source6 = r#"import {
        kotex
        tcolorbox (many)
        foo (bar1, bar2, bar3)
        geometry (a4paper, margin = 0.4in)
    }"#;
    let source7 = r#"import {
        kotex
        tcolorbox (many)
        foo (bar1, bar2, bar3)
        geometry (a4paper, margin = 0.4in)
    }"#;
    let source8 = r#"import {
        kotex
        tcolorbox (many)
        foo (
          bar1, bar2,
          bar3
        )
        geometry (a4paper, margin = 0.4in)
    }"#;
    let source9 = r#"import {
        kotex
        tcolorbox (many)
        foo (
          bar1,
          bar2,
          bar3,
        )
        geometry (a4paper, margin = 0.4in)
    }"#;
    let expected1 = "\\usepackage{kotex}\n";
    let expected2 = "\\usepackage[many]{tcolorbox}\n";
    let expected3 = "\\usepackage[bar1,bar2]{foo}\n";
    let expected4 = "\\usepackage[a4paper,margin=0.4in]{geometry}\n";
    let expected5 = r#"\usepackage{kotex}
\usepackage[many]{tcolorbox}
\usepackage[bar1,bar2,bar3]{foo}
\usepackage[a4paper,margin=0.4in]{geometry}
"#;

    let mut parser1 = Parser::new(Lexer::new(source1));
    let mut parser2 = Parser::new(Lexer::new(source2));
    let mut parser3 = Parser::new(Lexer::new(source3));
    let mut parser4 = Parser::new(Lexer::new(source4));
    let mut parser5 = Parser::new(Lexer::new(source5));
    let mut parser6 = Parser::new(Lexer::new(source6));
    let mut parser7 = Parser::new(Lexer::new(source7));
    let mut parser8 = Parser::new(Lexer::new(source8));
    let mut parser9 = Parser::new(Lexer::new(source9));
    assert_eq!(expected1, parser1.make_latex_format::<true>().unwrap());
    assert_eq!(expected2, parser2.make_latex_format::<true>().unwrap());
    assert_eq!(expected2, parser3.make_latex_format::<true>().unwrap());
    assert_eq!(expected3, parser4.make_latex_format::<true>().unwrap());
    assert_eq!(expected4, parser5.make_latex_format::<true>().unwrap());
    assert_eq!(expected5, parser6.make_latex_format::<true>().unwrap());
    assert_eq!(expected5, parser7.make_latex_format::<true>().unwrap());
    assert_eq!(expected5, parser8.make_latex_format::<true>().unwrap());
    assert_eq!(expected5, parser9.make_latex_format::<true>().unwrap());
}

#[test]
fn parse_main_string() {
    let source1 = "startdoc This is vesti";
    let source2 = "startdoc docclass";

    let expected_ast1 = vec![
        Statement::DocumentStart,
        Statement::MainText(String::from("This")),
        Statement::MainText(String::from(" ")),
        Statement::MainText(String::from("is")),
        Statement::MainText(String::from(" ")),
        Statement::MainText(String::from("vesti")),
        Statement::DocumentEnd,
    ];
    let expected_ast2 = vec![
        Statement::DocumentStart,
        Statement::MainText(String::from("docclass")),
        Statement::DocumentEnd,
    ];

    let mut parser1 = Parser::new(Lexer::new(source1));
    let mut parser2 = Parser::new(Lexer::new(source2));
    assert_eq!(expected_ast1, parser1.parse_latex().unwrap());
    assert_eq!(expected_ast2, parser2.parse_latex().unwrap());
}

#[test]
fn parse_environment() {
    let source1 = r#"startdoc begenv center
    The Document.
endenv"#;
    let source2 = r#"startdoc begenv minipage (0.7\pagewidth)
    The Document.
endenv"#;
    let source3 = r#"startdoc begenv minipage(0.7\pagewidth)
    The Document.
endenv"#;
    let source4 = r#"startdoc begenv figure [ht]
    The Document.
endenv"#;
    let source5 = r#"startdoc begenv foo (bar1)[bar2](bar3)(bar4)[bar5]
    The Document.
endenv"#;
    let source6 = r#"startdoc begenv foo* (bar1 @ bar2)
    The Document.
endenv"#;
    let source7 = r#"startdoc begenv foo *(bar1 @ bar2)
    The Document.
endenv"#;

    let expected1 = r#"\begin{document}
\begin{center}
    The Document.
\end{center}

\end{document}
"#;
    let expected2 = r#"\begin{document}
\begin{minipage}{0.7\pagewidth}
    The Document.
\end{minipage}

\end{document}
"#;
    let expected3 = r#"\begin{document}
\begin{figure}[ht]
    The Document.
\end{figure}

\end{document}
"#;
    let expected4 = r#"\begin{document}
\begin{foo}{bar1}[bar2]{bar3}{bar4}[bar5]
    The Document.
\end{foo}

\end{document}
"#;
    let expected5 = r#"\begin{document}
\begin{foo*}{bar1}{bar2}
    The Document.
\end{foo*}

\end{document}
"#;
    let expected6 = r#"\begin{document}
\begin{foo}*{bar1}{bar2}
    The Document.
\end{foo}

\end{document}
"#;

    let mut parser1 = Parser::new(Lexer::new(source1));
    let mut parser2 = Parser::new(Lexer::new(source2));
    let mut parser3 = Parser::new(Lexer::new(source3));
    let mut parser4 = Parser::new(Lexer::new(source4));
    let mut parser5 = Parser::new(Lexer::new(source5));
    let mut parser6 = Parser::new(Lexer::new(source6));
    let mut parser7 = Parser::new(Lexer::new(source7));
    assert_eq!(expected1, parser1.make_latex_format::<true>().unwrap());
    assert_eq!(expected2, parser2.make_latex_format::<true>().unwrap());
    assert_eq!(expected2, parser3.make_latex_format::<true>().unwrap());
    assert_eq!(expected3, parser4.make_latex_format::<true>().unwrap());
    assert_eq!(expected4, parser5.make_latex_format::<true>().unwrap());
    assert_eq!(expected5, parser6.make_latex_format::<true>().unwrap());
    assert_eq!(expected6, parser7.make_latex_format::<true>().unwrap());
}

#[test]
fn parse_latex_functions() {
    let source1 = "startdoc \\foo";
    let source2 = "startdoc \\foo{bar1}";
    let source3 = "startdoc \\foo[bar1]";
    let source4 = "startdoc \\foo {bar1}[bar2]";
    let source5 = "startdoc \\foo{bar1}[bar2]";
    let source6 = "startdoc \\foo*[bar1]{bar2}{bar3}";
    let source7 = "startdoc \\foo*{bar1 @ bar2}";
    let source8 = "startdoc \\foo[bar3 @ bar2 @ bar1]{bar4 @ bar5 @ bar6 @ bar7}";
    let source9 = "startdoc \\foo*[bar1]{bar2}**{bar3}";
    let source10 = r#"startdoc \textbf{
    Hallo!\TeX and \foo{bar1 @ bar2{a}{}}; today}"#;

    let expected1 = r#"\begin{document}
\foo
\end{document}
"#;
    let expected2 = r#"\begin{document}
\foo{bar1}
\end{document}
"#;
    let expected3 = r#"\begin{document}
\foo[bar1]
\end{document}
"#;
    let expected4 = r#"\begin{document}
\foo{bar1}[bar2]
\end{document}
"#;
    let expected5 = r#"\begin{document}
\foo*[bar1]{bar2}{bar3}
\end{document}
"#;
    let expected6 = r#"\begin{document}
\foo*{bar1}{bar2}
\end{document}
"#;
    let expected7 = r#"\begin{document}
\foo[bar3][bar2][bar1]{bar4}{bar5}{bar6}{bar7}
\end{document}
"#;
    let expected8 = r#"\begin{document}
\foo*[bar1]{bar2}**{bar3}
\end{document}
"#;
    let expected9 = r#"\begin{document}
\textbf{
    Hallo!\TeX and \foo{bar1}{bar2{a}{}}; today}
\end{document}
"#;

    let mut parser1 = Parser::new(Lexer::new(source1));
    let mut parser2 = Parser::new(Lexer::new(source2));
    let mut parser3 = Parser::new(Lexer::new(source3));
    let mut parser4 = Parser::new(Lexer::new(source4));
    let mut parser5 = Parser::new(Lexer::new(source5));
    let mut parser6 = Parser::new(Lexer::new(source6));
    let mut parser7 = Parser::new(Lexer::new(source7));
    let mut parser8 = Parser::new(Lexer::new(source8));
    let mut parser9 = Parser::new(Lexer::new(source9));
    let mut parser10 = Parser::new(Lexer::new(source10));
    assert_eq!(expected1, parser1.make_latex_format::<true>().unwrap());
    assert_eq!(expected2, parser2.make_latex_format::<true>().unwrap());
    assert_eq!(expected3, parser3.make_latex_format::<true>().unwrap());
    assert_eq!(expected4, parser4.make_latex_format::<true>().unwrap());
    assert_eq!(expected4, parser5.make_latex_format::<true>().unwrap());
    assert_eq!(expected5, parser6.make_latex_format::<true>().unwrap());
    assert_eq!(expected6, parser7.make_latex_format::<true>().unwrap());
    assert_eq!(expected7, parser8.make_latex_format::<true>().unwrap());
    assert_eq!(expected8, parser9.make_latex_format::<true>().unwrap());
    assert_eq!(expected9, parser10.make_latex_format::<true>().unwrap());
}

#[test]
fn test_parse_math_stmt() {
    let source1 = "startdoc \\(\\sum_1^\\infty f(x)\\)";
    let source2 = "startdoc \\[\\sum_1^\\infty f(x)\\]";

    let expected1 = r#"\begin{document}
$\sum_1^\infty f(x)$
\end{document}
"#;
    let expected2 = r#"\begin{document}
\[\sum_1^\infty f(x)\]
\end{document}
"#;

    let mut parser1 = Parser::new(Lexer::new(source1));
    let mut parser2 = Parser::new(Lexer::new(source2));
    assert_eq!(expected1, parser1.make_latex_format::<true>().unwrap());
    assert_eq!(expected2, parser2.make_latex_format::<true>().unwrap());
}

#[test]
fn test_parse_function_definition_basic() {
    let source1 = "defun foo (#1) \\overline{#1} endfun";
    let source2 = "defun foo(#1) \\overline{#1} endfun";
    let source3 = "defun foo (#1)\\overline{#1} endfun";
    let source4 = "defun foo(#1)\\overline{#1} endfun";
    let source5 = r#"defun foo (#1)
        \overline{#1}
endfun"#;
    let source6 = r#"defun foo(#1)
        \overline{#1}
endfun"#;

    let expected = "\\def\\foo#1{\\overline{#1}}\n";

    let mut parser1 = Parser::new(Lexer::new(source1));
    let mut parser2 = Parser::new(Lexer::new(source2));
    let mut parser3 = Parser::new(Lexer::new(source3));
    let mut parser4 = Parser::new(Lexer::new(source4));
    let mut parser5 = Parser::new(Lexer::new(source5));
    let mut parser6 = Parser::new(Lexer::new(source6));
    assert_eq!(expected, parser1.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser2.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser3.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser4.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser5.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser6.make_latex_format::<true>().unwrap());
}

#[test]
fn test_parse_function_definition_name() {
    let source1 = "defun bar@foo (#1#2) \\overline{#1} and #2 endfun";
    let source2 = "defun bar@foo(#1#2) \\overline{#1} and #2 endfun";
    let source3 = "defun bar@foo (#1#2)\\overline{#1} and #2 endfun";
    let source4 = "defun bar@foo(#1#2)\\overline{#1} and #2 endfun";
    let source5 = r#"defun bar@foo (#1#2)
        \overline{#1} and #2
endfun"#;
    let source6 = r#"defun bar@foo(#1#2)
        \overline{#1} and #2
endfun"#;

    let expected = "\\def\\bar@foo#1#2{\\overline{#1} and #2}\n";

    let mut parser1 = Parser::new(Lexer::new(source1));
    let mut parser2 = Parser::new(Lexer::new(source2));
    let mut parser3 = Parser::new(Lexer::new(source3));
    let mut parser4 = Parser::new(Lexer::new(source4));
    let mut parser5 = Parser::new(Lexer::new(source5));
    let mut parser6 = Parser::new(Lexer::new(source6));
    assert_eq!(expected, parser1.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser2.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser3.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser4.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser5.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser6.make_latex_format::<true>().unwrap());
}

#[test]
fn test_parse_function_definition_arguments() {
    let source1 = "defun barfoo (import #1 and #2) \\overline{#1} and #2 endfun";
    let source2 = "defun barfoo(import #1 and #2) \\overline{#1} and #2 endfun";
    let source3 = "defun barfoo (import #1 and #2)\\overline{#1} and #2 endfun";
    let source4 = "defun barfoo(import #1 and #2)\\overline{#1} and #2 endfun";
    let source5 = r#"defun barfoo (import #1 and #2)
        \overline{#1} and #2
endfun"#;
    let source6 = r#"defun barfoo(import #1 and #2)
        \overline{#1} and #2
endfun"#;

    let expected = "\\def\\barfoo import #1 and #2{\\overline{#1} and #2}\n";

    let mut parser1 = Parser::new(Lexer::new(source1));
    let mut parser2 = Parser::new(Lexer::new(source2));
    let mut parser3 = Parser::new(Lexer::new(source3));
    let mut parser4 = Parser::new(Lexer::new(source4));
    let mut parser5 = Parser::new(Lexer::new(source5));
    let mut parser6 = Parser::new(Lexer::new(source6));
    assert_eq!(expected, parser1.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser2.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser3.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser4.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser5.make_latex_format::<true>().unwrap());
    assert_eq!(expected, parser6.make_latex_format::<true>().unwrap());
}

#[test]
fn test_parse_function_definition_trim() {
    let source1_trim_both = "defun foo (#1) \\overline{#1} endfun";
    let source2_trim_both = "defun foo (#1)\\overline{#1} endfun";
    let source3_trim_both = "defun foo (#1) \\overline{#1}endfun";
    let source4_trim_both = "defun foo (#1)\\overline{#1}endfun";

    let source1_trim_left = "defun foo (#1) \\overline{#1} endfun*";
    let source2_trim_left = "defun foo (#1)\\overline{#1} endfun*";
    let source3_trim_left = "defun foo (#1) \\overline{#1}endfun*";
    let source4_trim_left = "defun foo (#1)\\overline{#1}endfun*";

    let source1_trim_right = "defun* foo (#1) \\overline{#1} endfun";
    let source2_trim_right = "defun* foo (#1)\\overline{#1} endfun";
    let source3_trim_right = "defun* foo (#1) \\overline{#1}endfun";
    let source4_trim_right = "defun* foo (#1)\\overline{#1}endfun";

    let source1_no_trim = "defun* foo (#1) \\overline{#1} endfun*";
    let source2_no_trim = "defun* foo (#1)\\overline{#1} endfun*";
    let source3_no_trim = "defun* foo (#1) \\overline{#1}endfun*";
    let source4_no_trim = "defun* foo (#1)\\overline{#1}endfun*";

    let expected_trim_both = "\\def\\foo#1{\\overline{#1}}\n";
    let expected_trim_left = "\\def\\foo#1{\\overline{#1} }\n";
    let expected_trim_right = "\\def\\foo#1{ \\overline{#1}}\n";
    let expected_no_trim = "\\def\\foo#1{ \\overline{#1} }\n";

    let mut parser1_trim_both = Parser::new(Lexer::new(source1_trim_both));
    let mut parser2_trim_both = Parser::new(Lexer::new(source2_trim_both));
    let mut parser3_trim_both = Parser::new(Lexer::new(source3_trim_both));
    let mut parser4_trim_both = Parser::new(Lexer::new(source4_trim_both));

    let mut parser1_trim_left = Parser::new(Lexer::new(source1_trim_left));
    let mut parser2_trim_left = Parser::new(Lexer::new(source2_trim_left));
    let mut parser3_trim_left = Parser::new(Lexer::new(source3_trim_left));
    let mut parser4_trim_left = Parser::new(Lexer::new(source4_trim_left));

    let mut parser1_trim_right = Parser::new(Lexer::new(source1_trim_right));
    let mut parser2_trim_right = Parser::new(Lexer::new(source2_trim_right));
    let mut parser3_trim_right = Parser::new(Lexer::new(source3_trim_right));
    let mut parser4_trim_right = Parser::new(Lexer::new(source4_trim_right));

    let mut parser1_no_trim = Parser::new(Lexer::new(source1_no_trim));
    let mut parser2_no_trim = Parser::new(Lexer::new(source2_no_trim));
    let mut parser3_no_trim = Parser::new(Lexer::new(source3_no_trim));
    let mut parser4_no_trim = Parser::new(Lexer::new(source4_no_trim));

    // Check trim_both
    assert_eq!(
        expected_trim_both,
        parser1_trim_both.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_both,
        parser2_trim_both.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_both,
        parser3_trim_both.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_both,
        parser4_trim_both.make_latex_format::<true>().unwrap()
    );

    // Check trim_left
    assert_eq!(
        expected_trim_left,
        parser1_trim_left.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_left,
        parser2_trim_left.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_both,
        parser3_trim_left.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_both,
        parser4_trim_left.make_latex_format::<true>().unwrap()
    );

    // Check trim_right
    assert_eq!(
        expected_trim_right,
        parser1_trim_right.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_both,
        parser2_trim_right.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_right,
        parser3_trim_right.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_both,
        parser4_trim_right.make_latex_format::<true>().unwrap()
    );

    // Check no_trim
    assert_eq!(
        expected_no_trim,
        parser1_no_trim.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_left,
        parser2_no_trim.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_right,
        parser3_no_trim.make_latex_format::<true>().unwrap()
    );
    assert_eq!(
        expected_trim_both,
        parser4_no_trim.make_latex_format::<true>().unwrap()
    );
}

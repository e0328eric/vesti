use super::*;
use crate::codegen::make_latex_format;

macro_rules! expected {
    ($source: ident should be $expected: ident) => {{
        let mut parser = Parser::new(Lexer::new($source));
        assert_eq!($expected, make_latex_format::<true>(&mut parser).unwrap());
    }};
}

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

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
    expected!(source3 should be expected2);
    expected!(source4 should be expected3);
    expected!(source5 should be expected3);
    expected!(source6 should be expected3);
}

#[test]
fn test_parse_usepackage() {
    let source1 = "import kotex";
    let source2 = "import tcolorbox (many)";
    let source3 = "import tcolorbox ( many )";
    let source4 = "import foo (bar1, bar2)";
    let source5 = "import geometry (a4paper, margin = 0.4in)";
    let source6 = r#"import {
        kotex,
        tcolorbox (many),
        foo (bar1, bar2, bar3),
        geometry (a4paper, margin = 0.4in),
    }"#;
    let source7 = r#"import {
        kotex,
        tcolorbox (many),
        foo (
          bar1, bar2,
          bar3
        ),
        geometry (a4paper, margin = 0.4in),
    }"#;
    let source8 = r#"import {
        kotex,
        tcolorbox (many),
        foo (
          bar1,
          bar2,
          bar3,
        ),
        geometry (a4paper, margin = 0.4in),
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

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
    expected!(source3 should be expected2);
    expected!(source4 should be expected3);
    expected!(source5 should be expected4);
    expected!(source6 should be expected5);
    expected!(source7 should be expected5);
    expected!(source8 should be expected5);
}

#[test]
fn parse_main_string() {
    let source1 = "startdoc This is vesti";
    let source2 = "startdoc docclass";

    let expected1 = "\\begin{document}\nThis is vesti\n\\end{document}\n";
    let expected2 = "\\begin{document}\ndocclass\n\\end{document}\n";

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
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

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
    expected!(source3 should be expected2);
    expected!(source4 should be expected3);
    expected!(source5 should be expected4);
    expected!(source6 should be expected5);
    expected!(source7 should be expected6);
}

#[test]
fn parse_latex_functions() {
    let source1 = "startdoc \\foo";
    let source2 = "startdoc \\foo{bar1}";
    let source3 = "startdoc \\foo%[bar1]";
    let source4 = "startdoc \\foo{bar1}%[bar2]";
    let source5 = "startdoc \\foo*%[bar1]{bar2}{bar3}";
    let source6 = "startdoc \\foo*{bar1 @ bar2}";
    let source7 = "startdoc \\foo%[bar3 @ bar2 @ bar1]{bar4 @ bar5 @ bar6 @ bar7}";
    let source8 = "startdoc \\foo*%[bar1]{bar2}**{bar3}";
    let source9 = r#"startdoc \textbf{
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

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
    expected!(source3 should be expected3);
    expected!(source4 should be expected4);
    expected!(source5 should be expected5);
    expected!(source6 should be expected6);
    expected!(source7 should be expected7);
    expected!(source8 should be expected8);
    expected!(source9 should be expected9);
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

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
}

#[test]
fn test_brace() {
    let source1 = "${\nabcd\n}$";
    let source2 = "$\\sum_{j=1}$";

    expected!(source1 should be source1);
    expected!(source2 should be source2);
}

#[test]
fn test_fraction() {
    let source1 = "${1//2}$";
    let source2 = "${\\alpha+\\beta//c+d-e}$";

    let expected1 = "$\\frac{1}{2}$";
    let expected2 = "$\\frac{\\alpha+\\beta}{c+d-e}$";

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
}

#[test]
fn test_complicated_fraction() {
    let source = "${{2//3}+\\alpha//5-{x+y//c-d}}$";
    let expected = "$\\frac{\\frac{2}{3}+\\alpha}{5-\\frac{x+y}{c-d}}$";

    expected!(source should be expected);
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

    expected!(source1 should be expected);
    expected!(source2 should be expected);
    expected!(source3 should be expected);
    expected!(source4 should be expected);
    expected!(source5 should be expected);
    expected!(source6 should be expected);
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

    expected!(source1 should be expected);
    expected!(source2 should be expected);
    expected!(source3 should be expected);
    expected!(source4 should be expected);
    expected!(source5 should be expected);
    expected!(source6 should be expected);
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

    expected!(source1 should be expected);
    expected!(source2 should be expected);
    expected!(source3 should be expected);
    expected!(source4 should be expected);
    expected!(source5 should be expected);
    expected!(source6 should be expected);
}

#[test]
fn test_parse_function_definition_kind() {
    let source1 = "defun foo(#1\\over#2) bar endfun";
    let source2 = "edefun foo(#1\\over#2) bar endfun";
    let source3 = "odefun foo(#1\\over#2) bar endfun";
    let source4 = "loxdefun foo(#1\\over#2) bar endfun";
    let source5 = "lgdefun foo(#1\\over#2) bar endfun";
    let source6 = "lodefun foo(#1\\over#2) bar endfun";

    let expected1 = "\\def\\foo#1\\over#2{bar}\n";
    let expected2 = "\\edef\\foo#1\\over#2{bar}\n";
    let expected3 = "\\outer\\def\\foo#1\\over#2{bar}\n";
    let expected4 = "\\long\\outer\\xdef\\foo#1\\over#2{bar}\n";
    let expected5 = "\\long\\gdef\\foo#1\\over#2{bar}\n";
    let expected6 = "\\long\\outer\\def\\foo#1\\over#2{bar}\n";

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
    expected!(source3 should be expected3);
    expected!(source4 should be expected4);
    expected!(source5 should be expected5);
    expected!(source6 should be expected6);
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

    // Check trim_both
    expected!(source1_trim_both should be expected_trim_both);
    expected!(source2_trim_both should be expected_trim_both);
    expected!(source3_trim_both should be expected_trim_both);
    expected!(source4_trim_both should be expected_trim_both);

    // Check trim_left
    expected!(source1_trim_left should be expected_trim_left);
    expected!(source2_trim_left should be expected_trim_left);
    expected!(source3_trim_left should be expected_trim_both);
    expected!(source4_trim_left should be expected_trim_both);

    // Check trim_right
    expected!(source1_trim_right should be expected_trim_right);
    expected!(source2_trim_right should be expected_trim_both);
    expected!(source3_trim_right should be expected_trim_right);
    expected!(source4_trim_right should be expected_trim_both);

    // Check no_trim
    expected!(source1_no_trim should be expected_no_trim);
    expected!(source2_no_trim should be expected_trim_left);
    expected!(source3_no_trim should be expected_trim_right);
    expected!(source4_no_trim should be expected_trim_both);
}

#[test]
fn test_parse_define_environment() {
    let source = r#"defenv foo
\vskip 1pc\noindent
endswith
\vskip 1pc
endenv
"#;
    let expected = "\\newenvironment{foo}{\\vskip 1pc\\noindent}{\\vskip 1pc}\n";

    expected!(source should be expected);
}

#[test]
fn test_parse_define_environment_with_argument() {
    let source = r#"defenv foo [1]
\vskip 1pc\noindent #1
endswith
\vskip 1pc
endenv
"#;
    let expected = "\\newenvironment{foo}[1]{\\vskip 1pc\\noindent #1}{\\vskip 1pc}\n";

    expected!(source should be expected);
}

#[test]
fn test_parse_define_environment_with_optional_argument() {
    let source1 = r#"defenv foo [1,basd]
\vskip 1pc\noindent #1
endswith
\vskip 1pc
endenv
"#;
    let source2 = r#"defenv foo [1, basd]
\vskip 1pc\noindent #1
endswith
\vskip 1pc
endenv
"#;
    let source3 = r#"defenv foo [1,  basd]
\vskip 1pc\noindent #1
endswith
\vskip 1pc
endenv
"#;

    let expected1 = "\\newenvironment{foo}[1][basd]{\\vskip 1pc\\noindent #1}{\\vskip 1pc}\n";
    let expected2 = "\\newenvironment{foo}[1][ basd]{\\vskip 1pc\\noindent #1}{\\vskip 1pc}\n";

    expected!(source1 should be expected1);
    expected!(source2 should be expected1);
    expected!(source3 should be expected2);
}

#[test]
fn parse_nested_define_environment() {
    let source = r#"defenv* foo [1,basd]
  defenv bar
      give a number
  endswith
      and foo
  endenv
begenv bar
  \noindent #1
endenv
endswith*
\vskip 1pc
endenv"#;

    let expected = r#"\newenvironment{foo}[1][basd]{
  \newenvironment{bar}{give a number}{and foo}
\begin{bar}
  \noindent #1
\end{bar}
}{
\vskip 1pc}
"#;
    expected!(source should be expected);
}

#[test]
fn parse_phantom_environment() {
    let source = r#"defenv newminipage [1]
    pbegenv minipage (0.4\textwidth)
endswith
    pendenv minipage
endenv"#;

    let expected =
        "\\newenvironment{newminipage}[1]{\\begin{minipage}{0.4\\textwidth}}{\\end{minipage}}\n";
    expected!(source should be expected);
}

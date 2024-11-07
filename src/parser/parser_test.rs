#![allow(clippy::needless_raw_string_hashes)]

use super::*;
use crate::codegen::make_latex_format;
use crate::commands::LatexEngineType;

macro_rules! expected {
    ($source: ident should be $expected: ident) => {{
        let mut parser = Parser::new(Lexer::new($source), true);
        assert_eq!(
            $expected,
            make_latex_format::<true>(&mut parser, LatexEngineType::Invalid).unwrap()
        );
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
    let source1 = "importpkg kotex";
    let source2 = "importpkg tcolorbox (many)";
    let source3 = "importpkg tcolorbox ( many )";
    let source4 = "importpkg foo (bar1, bar2)";
    let source5 = "importpkg geometry (a4paper, margin = 0.4in)";
    let source6 = r#"importpkg {
        kotex,
        tcolorbox (many),
        foo (bar1, bar2, bar3),
        geometry (a4paper, margin = 0.4in),
    }"#;
    let source7 = r#"importpkg {
        kotex,
        tcolorbox (many),
        foo (
          bar1, bar2,
          bar3
        ),
        geometry (a4paper, margin = 0.4in),
    }"#;
    let source8 = r#"importpkg {
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
    let source1 = r#"startdoc useenv center {
    The Document.
}"#;
    let source2 = r#"startdoc useenv minipage (0.7\pagewidth) {
    The Document.
}"#;
    let source3 = r#"startdoc useenv minipage(0.7\pagewidth) {
    The Document.
}"#;
    let source4 = r#"startdoc useenv figure [ht] {
    The Document.
}"#;
    let source5 = r#"startdoc useenv foo (bar1)[bar2](bar3)(bar4)[bar5] {
    The Document.
}"#;
    let source6 = r#"startdoc useenv foo* (bar1)(bar2) {
    The Document.
}"#;
    let source7 = r#"startdoc useenv foo *(bar1)(bar2) {
    The Document.
}"#;

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
    let source3 = "startdoc \\foo[bar1]";
    let source4 = "startdoc \\foo{bar1}[bar2]";
    let source5 = "startdoc \\foo*[bar1]{bar2}{bar3}";
    let source6 = "startdoc \\foo*{bar1}{bar2}";
    let source7 = "startdoc \\foo[bar3][bar2][bar1]{bar4}{bar5}{bar6}{bar7}";
    let source8 = "startdoc \\foo*[bar1]{bar2}**{bar3}";
    let source9 = r#"startdoc \textbf{
    Hallo!\TeX and \foo{bar1}{bar2{a}{}}; today}"#;

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
    let source1 = "startdoc $\\sum_1^\\infty f(x)$";
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
fn test_other_character() {
    let source1 = "これて、何ですか？";

    expected!(source1 should be source1);
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
    let source1 = "defun foo (#1) \\overline{#1} enddef";
    let source2 = "defun foo(#1) \\overline{#1} enddef";
    let source3 = "defun foo (#1)\\overline{#1} enddef";
    let source4 = "defun foo(#1)\\overline{#1} enddef";
    let source5 = r#"defun foo (#1)
        \overline{#1}
enddef"#;
    let source6 = r#"defun foo(#1)
        \overline{#1}
enddef"#;

    let expected = "\\def\\foo#1{%\n\\overline{#1}%\n}\n";

    expected!(source1 should be expected);
    expected!(source2 should be expected);
    expected!(source3 should be expected);
    expected!(source4 should be expected);
    expected!(source5 should be expected);
    expected!(source6 should be expected);
}

#[test]
fn test_parse_function_definition_name() {
    let source1 = "defun bar_foo (#1#2) \\overline{#1} and #2 enddef";
    let source2 = "defun bar_foo(#1#2) \\overline{#1} and #2 enddef";
    let source3 = "defun bar_foo (#1#2)\\overline{#1} and #2 enddef";
    let source4 = "defun bar_foo(#1#2)\\overline{#1} and #2 enddef";
    let source5 = r#"defun bar_foo (#1#2)
        \overline{#1} and #2
enddef"#;
    let source6 = r#"defun bar_foo(#1#2)
        \overline{#1} and #2
enddef"#;

    let expected = "\\def\\bar@foo#1#2{%\n\\overline{#1} and #2%\n}\n";

    expected!(source1 should be expected);
    expected!(source2 should be expected);
    expected!(source3 should be expected);
    expected!(source4 should be expected);
    expected!(source5 should be expected);
    expected!(source6 should be expected);
}

#[test]
fn test_parse_function_definition_arguments() {
    let source1 = "defun barfoo (import #1 and #2) \\overline{#1} and #2 enddef";
    let source2 = "defun barfoo(import #1 and #2) \\overline{#1} and #2 enddef";
    let source3 = "defun barfoo (import #1 and #2)\\overline{#1} and #2 enddef";
    let source4 = "defun barfoo(import #1 and #2)\\overline{#1} and #2 enddef";
    let source5 = r#"defun barfoo (import #1 and #2)
        \overline{#1} and #2
enddef"#;
    let source6 = r#"defun barfoo(import #1 and #2)
        \overline{#1} and #2
enddef"#;

    let expected = "\\def\\barfoo import #1 and #2{%\n\\overline{#1} and #2%\n}\n";

    expected!(source1 should be expected);
    expected!(source2 should be expected);
    expected!(source3 should be expected);
    expected!(source4 should be expected);
    expected!(source5 should be expected);
    expected!(source6 should be expected);
}

#[test]
fn test_parse_function_definition_kind() {
    let source1 = "defun foo(#1\\over#2) bar enddef";
    let source2 = "ldefun foo(#1\\over#2) bar enddef";
    let source3 = "odefun foo(#1\\over#2) bar enddef";
    let source4 = "lodefun foo(#1\\over#2) bar enddef";
    let source5 = "edefun foo(#1\\over#2) bar enddef";
    let source6 = "ledefun foo(#1\\over#2) bar enddef";
    let source7 = "oedefun foo(#1\\over#2) bar enddef";
    let source8 = "loedefun foo(#1\\over#2) bar enddef";
    let source9 = "gdefun foo(#1\\over#2) bar enddef";
    let source10 = "lgdefun foo(#1\\over#2) bar enddef";
    let source11 = "ogdefun foo(#1\\over#2) bar enddef";
    let source12 = "logdefun foo(#1\\over#2) bar enddef";
    let source13 = "xdefun foo(#1\\over#2) bar enddef";
    let source14 = "lxdefun foo(#1\\over#2) bar enddef";
    let source15 = "oxdefun foo(#1\\over#2) bar enddef";
    let source16 = "loxdefun foo(#1\\over#2) bar enddef";

    let expected1 = "\\def\\foo#1\\over#2{%\nbar%\n}\n";
    let expected2 = "\\long\\def\\foo#1\\over#2{%\nbar%\n}\n";
    let expected3 = "\\outer\\def\\foo#1\\over#2{%\nbar%\n}\n";
    let expected4 = "\\long\\outer\\def\\foo#1\\over#2{%\nbar%\n}\n";
    let expected5 = "\\edef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected6 = "\\long\\edef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected7 = "\\outer\\edef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected8 = "\\long\\outer\\edef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected9 = "\\gdef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected10 = "\\long\\gdef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected11 = "\\outer\\gdef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected12 = "\\long\\outer\\gdef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected13 = "\\xdef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected14 = "\\long\\xdef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected15 = "\\outer\\xdef\\foo#1\\over#2{%\nbar%\n}\n";
    let expected16 = "\\long\\outer\\xdef\\foo#1\\over#2{%\nbar%\n}\n";

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
    expected!(source3 should be expected3);
    expected!(source4 should be expected4);
    expected!(source5 should be expected5);
    expected!(source6 should be expected6);
    expected!(source7 should be expected7);
    expected!(source8 should be expected8);
    expected!(source9 should be expected9);
    expected!(source10 should be expected10);
    expected!(source11 should be expected11);
    expected!(source12 should be expected12);
    expected!(source13 should be expected13);
    expected!(source14 should be expected14);
    expected!(source15 should be expected15);
    expected!(source16 should be expected16);
}

#[test]
fn test_parse_function_definition_trim() {
    let source1_trim_both = "defun foo (#1) \\overline{#1} enddef";
    let source2_trim_both = "defun foo (#1)\\overline{#1} enddef";
    let source3_trim_both = "defun foo (#1) \\overline{#1}enddef";
    let source4_trim_both = "defun foo (#1)\\overline{#1}enddef";

    let source1_trim_left = "defun foo (#1) \\overline{#1} enddef*";
    let source2_trim_left = "defun foo (#1)\\overline{#1} enddef*";
    let source3_trim_left = "defun foo (#1) \\overline{#1}enddef*";
    let source4_trim_left = "defun foo (#1)\\overline{#1}enddef*";

    let source1_trim_right = "defun* foo (#1) \\overline{#1} enddef";
    let source2_trim_right = "defun* foo (#1)\\overline{#1} enddef";
    let source3_trim_right = "defun* foo (#1) \\overline{#1}enddef";
    let source4_trim_right = "defun* foo (#1)\\overline{#1}enddef";

    let source1_no_trim = "defun* foo (#1) \\overline{#1} enddef*";
    let source2_no_trim = "defun* foo (#1)\\overline{#1} enddef*";
    let source3_no_trim = "defun* foo (#1) \\overline{#1}enddef*";
    let source4_no_trim = "defun* foo (#1)\\overline{#1}enddef*";

    let case1 = "\\def\\foo#1{%\n\\overline{#1}%\n}\n";
    let case2 = "\\def\\foo#1{%\n\\overline{#1} %\n}\n";
    let case3 = "\\def\\foo#1{\\overline{#1}%\n}\n";
    let case4 = "\\def\\foo#1{ \\overline{#1}%\n}\n";
    let case5 = "\\def\\foo#1{\\overline{#1} %\n}\n";
    let case6 = "\\def\\foo#1{ \\overline{#1} %\n}\n";

    // Check trim_both
    expected!(source1_trim_both should be case1);
    expected!(source2_trim_both should be case1);
    expected!(source3_trim_both should be case1);
    expected!(source4_trim_both should be case1);

    // Check trim_left
    expected!(source1_trim_left should be case2);
    expected!(source2_trim_left should be case2);
    expected!(source3_trim_left should be case1);
    expected!(source4_trim_left should be case1);

    // Check trim_right
    expected!(source1_trim_right should be case4);
    expected!(source2_trim_right should be case3);
    expected!(source3_trim_right should be case4);
    expected!(source4_trim_right should be case3);

    // Check no_trim
    expected!(source1_no_trim should be case6);
    expected!(source2_no_trim should be case5);
    expected!(source3_no_trim should be case4);
    expected!(source4_no_trim should be case3);
}

#[test]
fn test_parse_define_environment() {
    let source = r#"defenv foo
\vskip 1pc\noindent
endswith
\vskip 1pc
enddef
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
enddef
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
enddef
"#;
    let source2 = r#"defenv foo [1, basd]
\vskip 1pc\noindent #1
endswith
\vskip 1pc
enddef
"#;
    let source3 = r#"defenv foo [1,  basd]
\vskip 1pc\noindent #1
endswith
\vskip 1pc
enddef
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
  enddef
begenv* bar
  \noindent #1
endenv bar
endswith*
\vskip 1pc
enddef"#;

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
    begenv minipage (0.4\textwidth)
endswith
    endenv minipage
enddef"#;

    let expected =
        "\\newenvironment{newminipage}[1]{\\begin{minipage}{0.4\\textwidth}}{\\end{minipage}}\n";
    expected!(source should be expected);
}

#[test]
fn parse_math_delimiters() {
    let source1 = "$(?)?{@?\\{?|?||?$";
    let source2 = "$?)?(?@}?\\}?|?||$";

    let expected1 = "$\\left(\\left)\\left\\langle \\left\\{\\left|\\left\\|$";
    let expected2 = "$\\right)\\right(\\right\\rangle \\right\\}\\right|\\right\\|$";

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
}

#[test]
fn parse_text_in_math() {
    let source1 = "$\"foo\"$";
    let source2 = "$#\"foo\"$";
    let source3 = "$\"foo\"#$";
    let source4 = "$#\"foo\"#$";

    let expected1 = "$\\text{ foo }$";
    let expected2 = "$\\text{foo }$";
    let expected3 = "$\\text{ foo}$";
    let expected4 = "$\\text{foo}$";

    expected!(source1 should be expected1);
    expected!(source2 should be expected2);
    expected!(source3 should be expected3);
    expected!(source4 should be expected4);
}

// Actual bugs encountered in previous versions

#[test]
fn parsing_bug_fix001() {
    let source = r#"
makeatletter
defun ps_solution()
    \let\_oddfoot=\_empty\let\_evenfoot=\_empty
    defun _oddhead() \the\titlename\hfill\thepage enddef
    defun _evenhead() \thepage\hfill\the\titlename enddef
enddef
makeatother
"#;
    let expected = r#"
\makeatletter
\def\ps@solution{%
\let\@oddfoot=\@empty\let\@evenfoot=\@empty
    \def\@oddhead{%
\the\titlename\hfill\thepage%
}
    \def\@evenhead{%
\thepage\hfill\the\titlename%
}%
}
\makeatother
"#;
    expected!(source should be expected);
}

#[test]
// This example shows that vesti prefer to use "..." syntax in math instead of
// using raw \text LaTeX command.
fn parsing_bug_fix002() {
    let source = "$oo\\text{oo}$ oo $oo\"oo\"$";
    let expected = r"$\infty \text{\infty }$ oo $\infty \text{ oo }$";

    expected!(source should be expected);
}

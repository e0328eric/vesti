use crate::codegen::Codegen;
use crate::diagnostic::Diagnostic;
use crate::parser::{LatexEngine, Parser, ParserAllows};

fn compile(source: &str) -> String {
    let mut diagnostic = Diagnostic::new();
    let mut parser = Parser::new(
        source,
        &mut diagnostic,
        ParserAllows {
            luacode: false,
            global_def: false,
            is_main: false,
            change_engine: true,
        },
        (None, LatexEngine::PdfLatex),
    )
    .expect("preprocess/parse init failed");

    let stmts = match parser.parse() {
        Ok(s) => s,
        Err(e) => {
            if let Some(text) = diagnostic.render(true) {
                panic!("parse failed: {e:?}\n{text}");
            }
            panic!("parse failed: {e:?}");
        }
    };

    let mut out = String::new();
    {
        let mut cg = Codegen::new(&stmts, false, &mut diagnostic);
        if let Err(e) = cg.codegen(None, None, &mut out) {
            if let Some(text) = diagnostic.render(true) {
                panic!("codegen failed: {e:?}\n{text}");
            }
            panic!("codegen failed: {e:?}");
        }
    }
    out
}

fn with_amstext(s: &str) -> String {
    format!("{s}\n\\usepackage{{amstext}}\n")
}

fn trim_nl(s: &str) -> &str {
    s.trim_matches('\n')
}

#[test]
fn docclass_plain() {
    assert_eq!(
        compile("docclass book"),
        with_amstext("\\documentclass{book}")
    );
}

#[test]
fn docclass_one_option() {
    assert_eq!(
        compile("docclass book (twocolumn)"),
        with_amstext("\\documentclass[twocolumn]{book}")
    );
}

#[test]
fn docclass_many_options_messy_spacing() {
    let src = "docclass memoir (a5paper,\n   draft , final-x ,\n)";
    assert_eq!(
        compile(src),
        with_amstext("\\documentclass[a5paper,draft,final-x]{memoir}")
    );
}

#[test]
fn importpkg_single_no_options() {
    assert_eq!(compile("importpkg hyperref"), "\\usepackage{hyperref}\n");
}

#[test]
fn importpkg_single_options() {
    assert_eq!(
        compile("importpkg geometry (margin-1in,a4paper)"),
        "\\usepackage[margin-1in,a4paper]{geometry}\n"
    );
}

#[test]
fn importpkg_multiple_mixed_options() {
    let src = "importpkg { amsmath, mathtools (fixfrac), tikz }";
    let expected = "\\usepackage{amsmath}\n\\usepackage[fixfrac]{mathtools}\n\\usepackage{tikz}\n";
    assert_eq!(compile(src), expected);
}

#[test]
fn importpkg_multiple_trailing_comma_and_newlines() {
    let src = "importpkg {\n  amsmath,\n  xcolor (dvipsnames),\n}";
    let expected = "\\usepackage{amsmath}\n\\usepackage[dvipsnames]{xcolor}\n";
    assert_eq!(compile(src), expected);
}

#[test]
fn importpkg_multiple_trailing_comma_and_newlines_except_last() {
    let src = "importpkg {\n  amsmath,\n  xcolor (dvipsnames)\n}";
    let expected = "\\usepackage{amsmath}\n\\usepackage[dvipsnames]{xcolor}\n";
    assert_eq!(compile(src), expected);
}

#[test]
fn useenv_basic() {
    let src = "startdoc\nuseenv quote { Hold fast. }";
    let expected = "\\begin{document}\n\\begin{quote} Hold fast. \\end{quote}\n\\end{document}";
    assert_eq!(trim_nl(&compile(src)), trim_nl(expected));
}

#[test]
fn useenv_optional_and_main_args() {
    let src = "startdoc\nuseenv thm [Pythagoras] { a^2 + b^2 = c^2 }";
    let expected =
        "\\begin{document}\n\\begin{thm}[Pythagoras] a^2 + b^2 = c^2 \\end{thm}\n\\end{document}";
    assert_eq!(trim_nl(&compile(src)), trim_nl(expected));
}

#[test]
fn useenv_star_keeps_in_name() {
    let src = "startdoc\nuseenv align* { x &= y }";
    let expected = "\\begin{document}\n\\begin{align*} x &= y \\end{align*}\n\\end{document}";
    assert_eq!(trim_nl(&compile(src)), trim_nl(expected));
}

#[test]
fn begenv_endenv_pair() {
    let src = "startdoc\nbegenv itemize\n\\item a\nendenv";
    let expected = "\\begin{document}\n\\begin{itemize}\n\\item a\n\\end{itemize}\n\\end{document}";
    assert_eq!(trim_nl(&compile(src)), trim_nl(expected));
}

#[test]
fn inline_math_infinity_and_arrow() {
    let src = "startdoc\n$f: A -> B, n -> oo$";
    let out = compile(src);
    assert_eq!(
        trim_nl(&out),
        "\\begin{document}\n$f: A \\rightarrow  B, n \\rightarrow  \\infty $\n\\end{document}"
    );
}

#[test]
fn display_math_geq() {
    let src = "startdoc\n$$x >= 0$$";
    let out = compile(src);
    assert_eq!(
        trim_nl(&out),
        "\\begin{document}\n\\[x \\geq  0\\]\n\\end{document}"
    );
}

#[test]
fn fraction_in_math() {
    let src = "startdoc\n${a + 1 // b}$";
    let out = compile(src);
    assert_eq!(
        trim_nl(&out),
        "\\begin{document}\n$\\frac{a + 1 }{ b}$\n\\end{document}"
    );
}

#[test]
fn def_macro_no_params() {
    let src = "#def #RR {\\mathbb{R}}\nstartdoc\n$x \\in #RR$";
    let out = compile(src);
    assert_eq!(
        trim_nl(&out),
        "\\begin{document}\n$x \\in \\mathbb{R}$\n\\end{document}"
    );
}

#[test]
fn def_macro_with_params() {
    let src = "#def #pair {(#1, #2)}\nstartdoc\n#pair(a)(b)";
    let out = compile(src);
    assert_eq!(trim_nl(&out), "\\begin{document}\n(a, b)\n\\end{document}");
}

#[test]
fn label_before_useenv() {
    let src = "startdoc\n#label(sec:intro) useenv center { hi }";
    let out = compile(src);
    assert_eq!(
        trim_nl(&out),
        "\\begin{document}\n\\begin{center}\\label{sec:intro} hi \\end{center}\n\\end{document}"
    );
}

#[test]
fn eq_labeled_equation() {
    let src = "startdoc\n#eq (eq:1) { a = b }";
    let out = compile(src);
    assert_eq!(
        trim_nl(&out),
        "\\begin{document}\n\\begin{equation}\\label{eq:1} a = b \\end{equation}\n\\end{document}"
    );
}

#[test]
fn defun_redef_protected_def() {
    let src = "#raw_tex defun [r] foo {bar}\nstartdoc";
    let out = compile(src);
    assert!(
        out.contains("\\protected\\def\\foo"),
        "unexpected output: {out}"
    );
    assert!(out.contains("bar"));
}

#[test]
fn defenv_basic_xparse() {
    let src = "defenv myenv { \\begingroup }{ \\endgroup }";
    let out = compile(src);
    assert!(
        out.contains("\\NewDocumentEnvironment{myenv}"),
        "unexpected output: {out}"
    );
    assert!(out.contains("\\begingroup"));
    assert!(out.contains("\\endgroup"));
}

#[test]
fn textmode_inside_math() {
    let src = "startdoc\n$x #textmode{ if } y$";
    let out = compile(src);
    assert_eq!(
        trim_nl(&out),
        "\\begin{document}\n$x  if  y$\n\\end{document}"
    );
}

#[test]
fn quoted_text_in_math() {
    let src = "startdoc\n$\\mathop{\"Re\"}$";
    let out = compile(src);
    assert_eq!(
        trim_nl(&out),
        "\\begin{document}\n$\\mathop{\\text{Re}}$\n\\end{document}"
    );
}

#[test]
fn example_definition_opening_matches_compiled_tex() {
    // Mirrors the opening of half_space/chapter1/definition.ves (macros + first
    // sentence + the #label/#defin/#eq block), checked against the structure of
    // the compiled @vesti__*.tex. Built by hand, not copied from the fixture.
    let src = "\
#def #distrib { \\Dc(\\R^d_+)}
#def #Coo { C_0^oo(\\R_+)}
#def #defin {useenv defin}
#def #eqn {#eq}

By $#distrib$ we denote the space.
#label(defin:1.1)
#defin {
    Let $\\zeta\\in#Coo$ hold.
}";
    let out = compile(src);
    // \Dc(\R^d_+) pasted; C_0^oo -> C_0^\infty ; #label attaches to the env.
    assert!(
        out.contains("By $ \\Dc(\\R^d_+)$ we denote the space."),
        "got: {out}"
    );
    assert!(
        out.contains("\\begin{defin}\\label{defin:1.1}"),
        "got: {out}"
    );
    assert!(out.contains("\\zeta\\in C_0^\\infty (\\R_+)"), "got: {out}");
    assert!(out.contains("\\end{defin}"), "got: {out}");
}

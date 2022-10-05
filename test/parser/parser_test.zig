const std = @import("std");
const codegen = @import("vesti_test").codegen;

const test_allocator = std.testing.allocator;
const expectFmt = std.testing.expectFmt;
const Parser = @import("vesti_test").parser.Parser;

// A helper function to testing Parser
fn expect(comptime source: []const u8, comptime expected: []const u8) !void {
    var parser = Parser.init(source, test_allocator);
    const parsed_data = parser.parse() catch {
        if (parser.error_info) |info| {
            const err_str = try info.errStr(test_allocator);
            defer err_str.deinit();
            std.debug.print("{s}\n", .{err_str.items});
        } else {
            std.debug.print("BUG: error occurs but there is no error info\n", .{});
        }
        @panic("parse failed!!");
    };
    defer parsed_data.deinit();

    const got_string = try codegen.latexToString(&parsed_data, test_allocator);
    defer got_string.deinit();

    try expectFmt(expected, "{s}", .{got_string.items});
}

test "parse document class with no option" {
    const source = "docclass coprime";
    const expected = "\\documentclass{coprime}\n";

    try expect(source, expected);
}

test "parse document class with options" {
    const source1 = "docclass coprime (korean, tikz, item)";
    const source2 = "docclass coprime (korean,tikz,item)";
    const source3 = "docclass coprime (korean, tikz,item)";
    const source4 =
        \\docclass coprime (
        \\  korean,
        \\  tikz,
        \\  item,
        \\)
    ;
    const expected = "\\documentclass[korean,tikz,item]{coprime}\n";

    try expect(source1, expected);
    try expect(source2, expected);
    try expect(source3, expected);
    try expect(source4, expected);
}

test "parse import with no options (single package)" {
    const source = "import kotex";
    const expected = "\\usepackage{kotex}\n";

    try expect(source, expected);
}

test "parse import with options (single package)" {
    const source1 = "import geometry (a4paper, margin = 0.4in)";
    const source2 =
        \\import geometry (
        \\  a4paper,
        \\  margin = 0.4in,
        \\)
    ;
    const expected = "\\usepackage[a4paper,margin = 0.4in]{geometry}\n";

    try expect(source1, expected);
    try expect(source2, expected);
}

test "parse import with multiple packages at once" {
    const source1 =
        \\import {
        \\  kotex
        \\  tcolorbox (many)
        \\  foo(bar1, bar2, bar3)
        \\  geometry (a4paper, margin = 0.4in)
        \\}
    ;
    const source2 =
        \\import {
        \\  kotex
        \\  tcolorbox (many)
        \\  foo (
        \\      bar1, bar2,
        \\      bar3,
        \\  )
        \\  geometry (a4paper, margin = 0.4in)
        \\}
    ;
    const source3 =
        \\import {
        \\  kotex
        \\  tcolorbox (many)
        \\  foo (
        \\      bar1,
        \\      bar2,
        \\      bar3,
        \\  )
        \\  geometry (a4paper, margin = 0.4in)
        \\}
    ;
    const expected =
        \\\usepackage{kotex}
        \\\usepackage[many]{tcolorbox}
        \\\usepackage[bar1,bar2,bar3]{foo}
        \\\usepackage[a4paper,margin = 0.4in]{geometry}
        \\
    ;

    try expect(source1, expected);
    try expect(source2, expected);
    try expect(source3, expected);
}

test "parse main string" {
    const source1 = "startdoc This is vesti";
    const source2 = "startdoc docclass";

    const expected1 = "\\begin{document}\nThis is vesti\n\\end{document}\n";
    const expected2 = "\\begin{document}\ndocclass\n\\end{document}\n";

    try expect(source1, expected1);
    try expect(source2, expected2);
}

test "parse environment" {
    const source1 =
        \\startdoc begenv center
        \\  The Document.
        \\endenv
    ;
    const source2 =
        \\startdoc begenv minipage (0.7\pagewidth)
        \\  The Document.
        \\endenv
    ;
    const source3 =
        \\startdoc begenv minipage(0.7\pagewidth)
        \\  The Document.
        \\endenv
    ;
    const source4 =
        \\startdoc begenv figure [ht]
        \\  The Document.
        \\endenv
    ;
    const source5 =
        \\startdoc begenv foo (bar1)[bar2](bar3)(bar4)[bar5]
        \\  The Document.
        \\endenv
    ;
    const source6 =
        \\startdoc begenv foo (bar1)[bar2](bar3 @ bar4)[bar5]
        \\  The Document.
        \\endenv
    ;
    const source7 =
        \\startdoc begenv foo (bar1@bar2)
        \\  The Document.
        \\endenv
    ;
    const source8 =
        \\startdoc begenv foo (bar1 @bar2)
        \\  The Document.
        \\endenv
    ;
    const source9 =
        \\startdoc begenv foo (bar1@ bar2)
        \\  The Document.
        \\endenv
    ;
    const source10 =
        \\startdoc begenv foo (bar1 @ bar2)
        \\  The Document.
        \\endenv
    ;
    const source11 =
        \\startdoc begenv foo* (bar1 @ bar2)
        \\  The Document.
        \\endenv
    ;
    const source12 =
        \\startdoc begenv foo *(bar1 @ bar2)
        \\  The Document.
        \\endenv
    ;

    const expected1 =
        \\\begin{document}
        \\\begin{center}
        \\  The Document.
        \\\end{center}
        \\
        \\\end{document}
        \\
    ;
    const expected2 =
        \\\begin{document}
        \\\begin{minipage}{0.7\pagewidth}
        \\  The Document.
        \\\end{minipage}
        \\
        \\\end{document}
        \\
    ;
    const expected3 =
        \\\begin{document}
        \\\begin{figure}[ht]
        \\  The Document.
        \\\end{figure}
        \\
        \\\end{document}
        \\
    ;
    const expected4 =
        \\\begin{document}
        \\\begin{foo}{bar1}[bar2]{bar3}{bar4}[bar5]
        \\  The Document.
        \\\end{foo}
        \\
        \\\end{document}
        \\
    ;
    const expected5 =
        \\\begin{document}
        \\\begin{foo}{bar1}{bar2}
        \\  The Document.
        \\\end{foo}
        \\
        \\\end{document}
        \\
    ;
    const expected6 =
        \\\begin{document}
        \\\begin{foo*}{bar1}{bar2}
        \\  The Document.
        \\\end{foo*}
        \\
        \\\end{document}
        \\
    ;
    const expected7 =
        \\\begin{document}
        \\\begin{foo}*{bar1}{bar2}
        \\  The Document.
        \\\end{foo}
        \\
        \\\end{document}
        \\
    ;

    try expect(source1, expected1);
    try expect(source2, expected2);
    try expect(source3, expected2);
    try expect(source4, expected3);
    try expect(source5, expected4);
    try expect(source6, expected4);
    try expect(source7, expected5);
    try expect(source8, expected5);
    try expect(source9, expected5);
    try expect(source10, expected5);
    try expect(source11, expected6);
    try expect(source12, expected7);
}

test "parse latex functions" {
    const source1 = "startdoc \\foo";
    const source2 = "startdoc \\foo{bar1}";
    const source3 = "startdoc \\foo[bar1]";
    const source4 = "startdoc \\foo {bar1}[bar2]";
    const source5 = "startdoc \\foo{bar1}[bar2]";
    const source6 = "startdoc \\foo*[bar1]{bar2}{bar3}";
    const source7 = "startdoc \\foo*{bar1 @ bar2}";
    const source8 = "startdoc \\foo[bar3 @ bar2 @ bar1]{bar4 @ bar5 @ bar6 @ bar7}";
    const source9 = "startdoc \\foo*[bar1]{bar2}**{bar3}";
    const source10 =
        \\startdoc \textbf{
        \\  Hallo!\TeX and \foo{bar1 @ bar2{a}{}}; today}
    ;

    const expected1 =
        \\\begin{document}
        \\\foo
        \\\end{document}
        \\
    ;
    const expected2 =
        \\\begin{document}
        \\\foo{bar1}
        \\\end{document}
        \\
    ;
    const expected3 =
        \\\begin{document}
        \\\foo[bar1]
        \\\end{document}
        \\
    ;
    const expected4 =
        \\\begin{document}
        \\\foo{bar1}[bar2]
        \\\end{document}
        \\
    ;
    const expected5 =
        \\\begin{document}
        \\\foo*[bar1]{bar2}{bar3}
        \\\end{document}
        \\
    ;
    const expected6 =
        \\\begin{document}
        \\\foo*{bar1}{bar2}
        \\\end{document}
        \\
    ;
    const expected7 =
        \\\begin{document}
        \\\foo[bar3][bar2][bar1]{bar4}{bar5}{bar6}{bar7}
        \\\end{document}
        \\
    ;
    const expected8 =
        \\\begin{document}
        \\\foo*[bar1]{bar2}**{bar3}
        \\\end{document}
        \\
    ;
    const expected9 =
        \\\begin{document}
        \\\textbf{
        \\  Hallo!\TeX and \foo{bar1}{bar2{a}{}}; today}
        \\\end{document}
        \\
    ;

    try expect(source1, expected1);
    try expect(source2, expected2);
    try expect(source3, expected3);
    try expect(source4, expected4);
    try expect(source5, expected4);
    try expect(source6, expected5);
    try expect(source7, expected6);
    try expect(source8, expected7);
    try expect(source9, expected8);
    try expect(source10, expected9);
}

test "parse math statement" {
    const source1 = "startdoc \\(\\sum_1^\\infty f(x)\\)";
    const source2 = "startdoc \\[\\sum_1^\\infty f(x)\\]";

    const expected1 =
        \\\begin{document}
        \\$\sum_1^\infty f(x)$
        \\\end{document}
        \\
    ;
    const expected2 =
        \\\begin{document}
        \\\[\sum_1^\infty f(x)\]
        \\\end{document}
        \\
    ;

    try expect(source1, expected1);
    try expect(source2, expected2);
}

test "parse function definition (basic)" {
    const source1 = "defun foo (#1) \\overline{#1} endfun";
    const source2 = "defun foo(#1) \\overline{#1} endfun";
    const source3 = "defun foo (#1)\\overline{#1} endfun";
    const source4 = "defun foo(#1)\\overline{#1} endfun";
    const source5 =
        \\defun foo (#1)
        \\\overline{#1}
        \\endfun
    ;
    const source6 =
        \\defun foo(#1)
        \\\overline{#1}
        \\endfun
    ;

    const expected = "\\def\\foo#1{\\overline{#1}}\n";

    try expect(source1, expected);
    try expect(source2, expected);
    try expect(source3, expected);
    try expect(source4, expected);
    try expect(source5, expected);
    try expect(source6, expected);
}

test "parse function definition (name)" {
    const source1 = "defun bar@foo (#1#2) \\overline{#1} and #2 endfun";
    const source2 = "defun bar@foo(#1#2) \\overline{#1} and #2 endfun";
    const source3 = "defun bar@foo (#1#2)\\overline{#1} and #2 endfun";
    const source4 = "defun bar@foo(#1#2)\\overline{#1} and #2 endfun";
    const source5 =
        \\defun bar@foo (#1#2)
        \\\overline{#1} and #2
        \\endfun
    ;
    const source6 =
        \\defun bar@foo(#1#2)
        \\\overline{#1} and #2
        \\endfun
    ;

    const expected = "\\def\\bar@foo#1#2{\\overline{#1} and #2}\n";

    try expect(source1, expected);
    try expect(source2, expected);
    try expect(source3, expected);
    try expect(source4, expected);
    try expect(source5, expected);
    try expect(source6, expected);
}

test "parse function definition (kind)" {
    const source1 = "defun foo(#1\\over#2) bar endfun";
    const source2 = "edefun foo(#1\\over#2) bar endfun";
    const source3 = "odefun foo(#1\\over#2) bar endfun";
    const source4 = "loxdefun foo(#1\\over#2) bar endfun";
    const source5 = "lgdefun foo(#1\\over#2) bar endfun";
    const source6 = "lodefun foo(#1\\over#2) bar endfun";

    const expected1 = "\\def\\foo#1\\over#2{bar}\n";
    const expected2 = "\\edef\\foo#1\\over#2{bar}\n";
    const expected3 = "\\outer\\def\\foo#1\\over#2{bar}\n";
    const expected4 = "\\long\\outer\\xdef\\foo#1\\over#2{bar}\n";
    const expected5 = "\\long\\gdef\\foo#1\\over#2{bar}\n";
    const expected6 = "\\long\\outer\\def\\foo#1\\over#2{bar}\n";

    try expect(source1, expected1);
    try expect(source2, expected2);
    try expect(source3, expected3);
    try expect(source4, expected4);
    try expect(source5, expected5);
    try expect(source6, expected6);
}

test "parse function definition (trim)" {
    const source1_trim_both = "defun foo (#1) \\overline{#1} endfun";
    const source2_trim_both = "defun foo (#1)\\overline{#1} endfun";
    const source3_trim_both = "defun foo (#1) \\overline{#1}endfun";
    const source4_trim_both = "defun foo (#1)\\overline{#1}endfun";

    const source1_trim_left = "defun foo (#1) \\overline{#1} endfun*";
    const source2_trim_left = "defun foo (#1)\\overline{#1} endfun*";
    const source3_trim_left = "defun foo (#1) \\overline{#1}endfun*";
    const source4_trim_left = "defun foo (#1)\\overline{#1}endfun*";

    const source1_trim_right = "defun* foo (#1) \\overline{#1} endfun";
    const source2_trim_right = "defun* foo (#1)\\overline{#1} endfun";
    const source3_trim_right = "defun* foo (#1) \\overline{#1}endfun";
    const source4_trim_right = "defun* foo (#1)\\overline{#1}endfun";
    const source5_trim_right = "defun*foo (#1)\\overline{#1}endfun";

    const source1_no_trim = "defun* foo (#1) \\overline{#1} endfun*";
    const source2_no_trim = "defun* foo (#1)\\overline{#1} endfun*";
    const source3_no_trim = "defun* foo (#1) \\overline{#1}endfun*";
    const source4_no_trim = "defun* foo (#1)\\overline{#1}endfun*";
    const source5_no_trim = "defun*foo (#1)\\overline{#1}endfun*";

    const expected_trim_both = "\\def\\foo#1{\\overline{#1}}\n";
    const expected_trim_left = "\\def\\foo#1{\\overline{#1} }\n";
    const expected_trim_right = "\\def\\foo#1{ \\overline{#1}}\n";
    const expected_no_trim = "\\def\\foo#1{ \\overline{#1} }\n";

    // Check trim_both
    try expect(source1_trim_both, expected_trim_both);
    try expect(source2_trim_both, expected_trim_both);
    try expect(source3_trim_both, expected_trim_both);
    try expect(source4_trim_both, expected_trim_both);

    // Check trim_left
    try expect(source1_trim_left, expected_trim_left);
    try expect(source2_trim_left, expected_trim_left);
    try expect(source3_trim_left, expected_trim_both);
    try expect(source4_trim_left, expected_trim_both);

    // Check trim_right
    try expect(source1_trim_right, expected_trim_right);
    try expect(source2_trim_right, expected_trim_both);
    try expect(source3_trim_right, expected_trim_right);
    try expect(source4_trim_right, expected_trim_both);
    try expect(source5_trim_right, expected_trim_both);

    // Check no_trim
    try expect(source1_no_trim, expected_no_trim);
    try expect(source2_no_trim, expected_trim_left);
    try expect(source3_no_trim, expected_trim_right);
    try expect(source4_no_trim, expected_trim_both);
    try expect(source5_no_trim, expected_trim_both);
}

test "parse define environment" {
    const source =
        \\defenv foo
        \\\vskip 1pc\noindent
        \\endswith
        \\\vskip 1pc
        \\endenv
    ;
    const expected = "\\newenvironment{foo}{\\vskip 1pc\\noindent}{\\vskip 1pc}\n";

    try expect(source, expected);
}

test "parse define environment with argument" {
    const source =
        \\defenv foo [1]
        \\\vskip 1pc\noindent #1
        \\endswith
        \\\vskip 1pc
        \\endenv
    ;
    const expected = "\\newenvironment{foo}[1]{\\vskip 1pc\\noindent #1}{\\vskip 1pc}\n";

    try expect(source, expected);
}

test "parse define environment with optional argument" {
    const source1 =
        \\defenv foo [1,basd]
        \\\vskip 1pc\noindent #1
        \\endswith
        \\\vskip 1pc
        \\endenv
    ;
    const source2 =
        \\defenv foo [1, basd]
        \\\vskip 1pc\noindent #1
        \\endswith
        \\\vskip 1pc
        \\endenv
    ;
    const source3 =
        \\defenv foo [1,  basd]
        \\\vskip 1pc\noindent #1
        \\endswith
        \\\vskip 1pc
        \\endenv
    ;

    const expected1 = "\\newenvironment{foo}[1][basd]{\\vskip 1pc\\noindent #1}{\\vskip 1pc}\n";
    const expected2 = "\\newenvironment{foo}[1][ basd]{\\vskip 1pc\\noindent #1}{\\vskip 1pc}\n";

    try expect(source1, expected1);
    try expect(source2, expected1);
    try expect(source3, expected2);
}

test "parse nested define environment" {
    const source =
        \\defenv* foo [1,basd]
        \\  defenv bar
        \\      give a number
        \\  endswith
        \\      and foo
        \\  endenv
        \\begenv bar
        \\  \noindent #1
        \\endenv
        \\endswith*
        \\\vskip 1pc
        \\endenv
    ;

    const expected =
        \\\newenvironment{foo}[1][basd]{
        \\  \newenvironment{bar}{give a number}{and foo}
        \\\begin{bar}
        \\  \noindent #1
        \\\end{bar}
        \\}{
        \\\vskip 1pc}
        \\
    ;
    try expect(source, expected);
}

test "parse phantom environment" {
    const source =
        \\defenv newminipage [1]
        \\  pbegenv minipage (0.4\textwidth)
        \\endswith
        \\  pendenv minipage
        \\endenv
    ;

    const expected =
        "\\newenvironment{newminipage}[1]{\\begin{minipage}{0.4\\textwidth}}{\\end{minipage}}\n";
    try expect(source, expected);
}

test "parse plain text in math" {
    const source1 =
        \\\[
        \\    X = E\cup F,\quad E\cap F=\emptyset,\quad
        \\    E mtxt is null for etxt \nu,\quad
        \\    F mtxt is null for etxt \mu.
        \\\]
    ;
    const source2 =
        \\\[
        \\    X = E\cup F,\quad E\cap F=\emptyset,\quad
        \\    E mtxt is null for etxt \nu,\quad
        \\    F mtxt* is null for etxt \mu.
        \\\]
    ;
    const source3 =
        \\\[
        \\    X = E\cup F,\quad E\cap F=\emptyset,\quad
        \\    E mtxt is null for etxt \nu,\quad
        \\    F mtxt is null for etxt* \mu.
        \\\]
    ;
    const source4 =
        \\\[
        \\    X = E\cup F,\quad E\cap F=\emptyset,\quad
        \\    E mtxt is null for etxt \nu,\quad
        \\    F mtxt* is null for etxt* \mu.
        \\\]
    ;
    const expected1 =
        \\\[
        \\    X = E\cup F,\quad E\cap F=\emptyset,\quad
        \\    E \text{ is null for } \nu,\quad
        \\    F \text{ is null for } \mu.
        \\\]
    ;
    const expected2 =
        \\\[
        \\    X = E\cup F,\quad E\cap F=\emptyset,\quad
        \\    E \text{ is null for } \nu,\quad
        \\    F \text{is null for } \mu.
        \\\]
    ;
    const expected3 =
        \\\[
        \\    X = E\cup F,\quad E\cap F=\emptyset,\quad
        \\    E \text{ is null for } \nu,\quad
        \\    F \text{ is null for} \mu.
        \\\]
    ;
    const expected4 =
        \\\[
        \\    X = E\cup F,\quad E\cap F=\emptyset,\quad
        \\    E \text{ is null for } \nu,\quad
        \\    F \text{is null for} \mu.
        \\\]
    ;

    try expect(source1, expected1);
    try expect(source2, expected2);
    try expect(source3, expected3);
    try expect(source4, expected4);
}

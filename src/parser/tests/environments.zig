const std = @import("std");

const expect = @import("utility.zig").expect;

fn trim(output: []const u8) []const u8 {
    return std.mem.trim(u8, output, "\n");
}

test "basic useenv statements 1" {
    const source =
        \\startdoc
        \\useenv center { The Document. }
    ;
    const expected =
        \\\begin{document}
        \\\begin{center} The Document. \end{center}
        \\\end{document}
    ;
    try expect(source, expected, trim);
}

test "basic useenv statements 2" {
    const source =
        \\startdoc
        \\useenv center { The Document. }
    ;
    const expected =
        \\\begin{document}
        \\\begin{center} The Document. \end{center}
        \\\end{document}
    ;
    try expect(source, expected, trim);
}

test "useenv with parameters" {
    const source1 =
        \\startdoc
        \\useenv minipage (0.7\pagewidth) {
        \\    The Document.
        \\}
    ;
    const source2 =
        \\startdoc
        \\useenv minipage(0.7\pagewidth) {
        \\    The Document.
        \\}
    ;
    const expected1 =
        \\\begin{document}
        \\\begin{minipage}{0.7\pagewidth}
        \\    The Document.
        \\\end{minipage}
        \\\end{document}
    ;

    try expect(source1, expected1, trim);
    try expect(source2, expected1, trim);

    const source4 =
        \\startdoc
        \\useenv figure [ht] {
        \\    The Document.
        \\}
    ;
    const source5 =
        \\startdoc
        \\useenv foo (bar1)[bar2](bar3)(bar4)[bar5] {
        \\    The Document.
        \\}
    ;
    const source6 =
        \\startdoc
        \\useenv foo* (bar1)(bar2) {
        \\    The Document.
        \\}
    ;
    const source7 =
        \\startdoc
        \\useenv foo *(bar1)(bar2) {
        \\    The Document.
        \\}
    ;

    const expected2 =
        \\\begin{document}
        \\\begin{figure}[ht]
        \\    The Document.
        \\\end{figure}
        \\\end{document}
    ;
    const expected3 =
        \\\begin{document}
        \\\begin{foo}{bar1}[bar2]{bar3}{bar4}[bar5]
        \\    The Document.
        \\\end{foo}
        \\\end{document}
    ;
    const expected4 =
        \\\begin{document}
        \\\begin{foo*}{bar1}{bar2}
        \\    The Document.
        \\\end{foo*}
        \\\end{document}
    ;
    const expected5 =
        \\\begin{document}
        \\\begin{foo}*{bar1}{bar2}
        \\    The Document.
        \\\end{foo}
        \\\end{document}
    ;

    try expect(source4, expected2, trim);
    try expect(source5, expected3, trim);
    try expect(source6, expected4, trim);
    try expect(source7, expected5, trim);
}

test "begenv statements" {
    const source =
        \\begenv center#1
        \\begenv center a
        \\begenv center* a
        \\begenv center*        a
        \\begenv center*a
        \\begenv center** a
        \\begenv center**    a
        \\begenv center**a
        \\begenv center [asd](caewa)a
        \\begenv center     [asd](caewa) a
        \\begenv center[asd](caewa) a
        \\begenv center* [asd](caewa) a
        \\begenv center*         [asd](caewa) a
        \\begenv center*[asd](caewa) a
        \\begenv center** [asd](caewa) a
        \\begenv center**     [asd](caewa) a
        \\begenv center**[asd](caewa) a
        \\begenv center *a
        \\begenv center* *[asd](caewa) a
    ;
    const expected =
        \\\begin{center}#1
        \\\begin{center}a
        \\\begin{center*}a
        \\\begin{center*}a
        \\\begin{center*}a
        \\\begin{center**}a
        \\\begin{center**}a
        \\\begin{center**}a
        \\\begin{center}[asd]{caewa}a
        \\\begin{center}[asd]{caewa} a
        \\\begin{center}[asd]{caewa} a
        \\\begin{center*}[asd]{caewa} a
        \\\begin{center*}[asd]{caewa} a
        \\\begin{center*}[asd]{caewa} a
        \\\begin{center**}[asd]{caewa} a
        \\\begin{center**}[asd]{caewa} a
        \\\begin{center**}[asd]{caewa} a
        \\\begin{center}*a
        \\\begin{center*}*[asd](caewa) a
    ;
    try expect(source, expected, trim);
}

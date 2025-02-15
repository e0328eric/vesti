const std = @import("std");
const mem = std.mem;

const expect = @import("./utility.zig").expect;

test "text math statement" {
    const source = "startdoc $\\sum_1^oo f(x)$";
    const expected =
        \\\begin{document} $\sum_1^\infty  f(x)$
        \\\end{document}
    ;

    // codegen add newline before \begin{document} and after \end{document}
    // so we need to trim output.items to get the "inner" contents to compare
    try expect(source, expected, struct {
        pub fn trim(output: []const u8) []const u8 {
            return mem.trim(u8, output, "\n");
        }
    }.trim);
}

test "inline math statement" {
    const source = "startdoc $$\\int_0^->f(x)$$";
    const expected =
        \\\begin{document} \[\int_0^\rightarrow f(x)\]
        \\\end{document}
    ;

    try expect(source, expected, struct {
        pub fn trim(output: []const u8) []const u8 {
            return mem.trim(u8, output, "\n");
        }
    }.trim);
}

test "simple latex document with math 1" {
    const source =
        \\docclass coprime (tikz, geometry)
        \\importpkg {
        \\    fontenc (T1),
        \\    inputenc (utf-8),
        \\}startdoc
        \\$\sum_1^oo f(x) $a b c d
    ;
    const expected =
        \\\documentclass[tikz,geometry]{coprime}
        \\
        \\\usepackage[T1]{fontenc}
        \\\usepackage[utf-8]{inputenc}
        \\
        \\\begin{document}
        \\$\sum_1^\infty  f(x) $a b c d
        \\\end{document}
        \\
    ;

    try expect(source, expected, null);
}

test "simple latex document with math 2" {
    const source =
        \\docclass coprime (tikz, geometry)importpkg {
        \\    fontenc (T1),
        \\    inputenc (utf-8),
        \\}startdoc
        \\$\sum_1^oo f(x) $a b c d
    ;
    const expected =
        \\\documentclass[tikz,geometry]{coprime}
        \\\usepackage[T1]{fontenc}
        \\\usepackage[utf-8]{inputenc}
        \\
        \\\begin{document}
        \\$\sum_1^\infty  f(x) $a b c d
        \\\end{document}
        \\
    ;

    try expect(source, expected, null);
}

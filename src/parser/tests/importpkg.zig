const std = @import("std");

const expect = @import("utility.zig").expect;

test "single importpkg statement without any options" {
    const source = "importpkg tikz";
    const expected = "\\usepackage{tikz}\n";
    try expect(source, expected, null);
}

test "single importpkg with single option" {
    const source = "importpkg foo (bar)";
    const expected = "\\usepackage[bar]{foo}\n";
    try expect(source, expected, null);
}

test "single importpkg with several options" {
    const source = "importpkg foo (bar,baz-f3,oomoom)";
    const expected = "\\usepackage[bar,baz-f3,oomoom]{foo}\n";
    try expect(source, expected, null);
}

test "multiple importpkg statement without any options" {
    const sources: [4][]const u8 = .{
        "importpkg { tikz, amsmath, coprime-math }",
        "importpkg { tikz, amsmath, coprime-math, }",
        \\importpkg { 
        \\    tikz, 
        \\    amsmath,
        \\    coprime-math,
        \\}
        ,
        \\importpkg { 
        \\    tikz, 
        \\    amsmath,
        \\    coprime-math
        \\}
        ,
    };
    const expected =
        \\\usepackage{tikz}
        \\\usepackage{amsmath}
        \\\usepackage{coprime-math}
        \\
    ;

    for (sources) |source| try expect(source, expected, null);
}

test "multiple importpkg statement with options 1" {
    const sources: [8][]const u8 = .{
        "importpkg { tikz, amsmath, coprime-math (stix) }",
        "importpkg { tikz, amsmath, coprime-math(stix) }",
        "importpkg { tikz, amsmath, coprime-math (stix), }",
        "importpkg { tikz, amsmath, coprime-math(stix), }",
        \\importpkg { 
        \\    tikz, 
        \\    amsmath,
        \\    coprime-math (stix),
        \\}
        ,
        \\importpkg { 
        \\    tikz, 
        \\    amsmath,
        \\    coprime-math(stix),
        \\}
        ,
        \\importpkg { 
        \\    tikz, 
        \\    amsmath,
        \\    coprime-math (stix)
        \\}
        ,
        // who wrotes like this?
        \\importpkg { 
        \\    tikz, 
        \\    amsmath,
        \\    coprime-math (
        \\  stix
        \\  )
        \\}
        ,
    };
    const expected =
        \\\usepackage{tikz}
        \\\usepackage{amsmath}
        \\\usepackage[stix]{coprime-math}
        \\
    ;

    for (sources) |source| try expect(source, expected, null);
}

test "multiple importpkg statement with options 2" {
    const source = "importpkg { tikz (a,b,c), foo-f(aa-aa, bb2cc), novax, bar2-a-b(faaa, aa-b-c) }";
    const expected =
        \\\usepackage[a,b,c]{tikz}
        \\\usepackage[aa-aa,bb2cc]{foo-f}
        \\\usepackage{novax}
        \\\usepackage[faaa,aa-b-c]{bar2-a-b}
        \\
    ;
    try expect(source, expected, null);
}

test "multiple importpkg statement with options 3" {
    const source =
        \\importpkg {
        \\    tikz (a, b, c),
        \\    foo-f(aa-aa,
        \\        bb2cc),
        \\ novax,
        \\                 bar2-a-b(faaa,   aa-b-c
        \\)
        \\}
    ;
    const expected =
        \\\usepackage[a,b,c]{tikz}
        \\\usepackage[aa-aa,bb2cc]{foo-f}
        \\\usepackage{novax}
        \\\usepackage[faaa,aa-b-c]{bar2-a-b}
        \\
    ;
    try expect(source, expected, null);
}

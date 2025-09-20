const std = @import("std");

const expect = @import("utility.zig").expect;

test "simple docclass statement" {
    const source = "docclass article";
    const expected = "\\documentclass{article}\n";
    try expect(source, expected, null);
}

test "docclass with single option" {
    const source = "docclass article (a4paper)";
    const expected = "\\documentclass[a4paper]{article}\n";
    try expect(source, expected, null);
}

test "docclass with several options" {
    const source = "docclass coprime (tikz,geometry,fancythm)";
    const expected = "\\documentclass[tikz,geometry,fancythm]{coprime}\n";
    try expect(source, expected, null);
}

test "who writes docclass like this?" {
    const source =
        \\docclass coprime (a4paper , 
        \\    foo, bar-what  ,
        \\)
    ;
    const expected = "\\documentclass[a4paper,foo,bar-what]{coprime}\n";
    try expect(source, expected, null);
}

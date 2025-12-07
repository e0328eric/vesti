const std = @import("std");

const expect = @import("utility.zig").expect;
const concat = @import("utility.zig").concatAmsText;

test "simple docclass statement" {
    const source = "docclass article";
    const expected = concat("\\documentclass{article}");
    try expect(source, expected, null);
}

test "docclass with single option" {
    const source = "docclass article (a4paper)";
    const expected = concat("\\documentclass[a4paper]{article}");
    try expect(source, expected, null);
}

test "docclass with several options" {
    const source = "docclass coprime (tikz,geometry,fancythm)";
    const expected = concat("\\documentclass[tikz,geometry,fancythm]{coprime}");
    try expect(source, expected, null);
}

test "who writes docclass like this?" {
    const source =
        \\docclass coprime (a4paper , 
        \\    foo, bar-what  ,
        \\)
    ;
    const expected = concat("\\documentclass[a4paper,foo,bar-what]{coprime}");
    try expect(source, expected, null);
}

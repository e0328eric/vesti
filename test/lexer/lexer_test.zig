const std = @import("std");

const Lexer = @import("vesti_test").lexer.Lexer;
const Type = @import("vesti_test").token.Type;

fn expectToken(
    comptime is_print: bool,
    lex: *Lexer,
    toktype: Type,
    literal: []const u8,
) !void {
    var token = lex.next();
    if (is_print) {
        std.debug.print("\n\n", .{});
        std.debug.print("<expected>\n", .{});
        std.debug.print("toktype: {}, literal: |{s}|\n", .{ toktype, literal });
        std.debug.print("<got>\n", .{});
        std.debug.print("toktype: {}, literal: |{s}|, span: {any}\n", .{
            token.toktype,
            token.literal,
            token.span,
        });
    }
    try std.testing.expect(token.toktype == toktype);
    try std.testing.expect(std.mem.eql(u8, token.literal, literal));
}

test "lexing one character symbols" {
    const source = "+*;:\"'`|=<?!,.~#&/";
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .plus, "+");
    try expectToken(false, &lex, .star, "*");
    try expectToken(false, &lex, .semicolon, ";");
    try expectToken(false, &lex, .colon, ":");
    try expectToken(false, &lex, .double_quote, "\"");
    try expectToken(false, &lex, .right_quote, "'");
    try expectToken(false, &lex, .left_quote, "`");
    try expectToken(false, &lex, .vert, "|");
    try expectToken(false, &lex, .equal, "=");
    try expectToken(false, &lex, .less, "<");
    try expectToken(false, &lex, .question, "?");
    try expectToken(false, &lex, .bang, "!");
    try expectToken(false, &lex, .comma, ",");
    try expectToken(false, &lex, .period, ".");
    try expectToken(false, &lex, .tilde, "~");
    try expectToken(false, &lex, .function_param, "#");
    try expectToken(false, &lex, .ampersand, "&");
    try expectToken(false, &lex, .slash, "/");
}

test "lexing two characters symbols" {
    const source = "$!--><->=<=@!%!";
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .raw_dollar, "$");
    try expectToken(false, &lex, .minus, "-");
    try expectToken(false, &lex, .right_arrow, "\\to ");
    try expectToken(false, &lex, .left_arrow, "\\leftarrow ");
    try expectToken(false, &lex, .great_equal, "\\geq ");
    try expectToken(false, &lex, .less_equal, "\\leq ");
    try expectToken(false, &lex, .at, "@");
    try expectToken(false, &lex, .latex_comment, "%");
}

test "lexing comments" {
    const source =
        \\++% Lexer do not parse these things!
        \\%* How about this? *%+%***%
        \\%* and this?*% +
        \\%*finally this? *%
        \\+
    ;
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .plus, "+");
    try expectToken(false, &lex, .plus, "+");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .nop, "");
    try expectToken(false, &lex, .plus, "+");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .plus, "+");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .plus, "+");
}

test "lexing numbers" {
    const source = "123 3.21 -7781 -9523.123";
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .integer, "123");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .float, "3.21");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .integer, "-7781");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .float, "-9523.123");
}

test "lexing not a numbers" {
    const source = "0 00 010 -0 -010 -101 0.0 00.0 0.00 0. 2.";
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .integer, "0");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "00");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "010");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .integer, "-0");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "-010");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .integer, "-101");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .float, "0.0");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "00");
    try expectToken(false, &lex, .period, ".");
    try expectToken(false, &lex, .integer, "0");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .float, "0.00");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .integer, "0");
    try expectToken(false, &lex, .period, ".");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .integer, "2");
    try expectToken(false, &lex, .period, ".");
}

test "lexing verbatim" {
    const source =
        \\%-Vesti compiler does not touch anything in here-%
        \\%- multiline support
        \\\begin{document}
        \\Hello, World! ###
        \\\end{document}-%
    ;
    var lex = Lexer.new(source);

    const expect_str1 = "Vesti compiler does not touch anything in here";
    const expect_str2 =
        \\ multiline support
        \\\begin{document}
        \\Hello, World! ###
        \\\end{document}
    ;

    try expectToken(false, &lex, .raw_latex, expect_str1);
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .raw_latex, expect_str2);
}

test "lexing math delimiters" {
    const source = "$ $ $$ $$ $ \\)\\[$$\\]$";
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .text_math_start, "$");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text_math_end, "$");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .display_math_start, "\\[");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .display_math_end, "\\]");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text_math_start, "$");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text_math_end, "$");
    try expectToken(false, &lex, .display_math_start, "\\[");
    try expectToken(false, &lex, .display_math_end, "\\]");
    try expectToken(false, &lex, .display_math_end, "\\]");
    try expectToken(false, &lex, .text_math_start, "$");
}

test "lexing backslashs" {
    const source = "$\\{\\#\\foo@bar\\ \\$\\}$\\ \\가ㅣ나\\@@@f ";
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .text_math_start, "$");
    try expectToken(false, &lex, .math_left_brace, "\\{");
    try expectToken(false, &lex, .sharp, "\\#");
    try expectToken(false, &lex, .latex_function, "\\foo@bar");
    try expectToken(false, &lex, .math_large_space, "\\;");
    try expectToken(false, &lex, .dollar, "\\$");
    try expectToken(false, &lex, .math_right_brace, "\\}");
    try expectToken(false, &lex, .text_math_end, "$");
    try expectToken(false, &lex, .force_space, "\\ ");
    try expectToken(false, &lex, .latex_function, "\\가ㅣ나");
    try expectToken(false, &lex, .latex_function, "\\@@@f");
    try expectToken(false, &lex, .space, " ");
}

test "lexing identifiers (ascii)" {
    const source = "This is a book!";
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .text, "This");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "is");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "a");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "book");
    try expectToken(false, &lex, .bang, "!");
}

test "lexing identifiers (unicode)" {
    const source = "どもサメです。 삼십이32";
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .text, "どもサメです");
    try expectToken(false, &lex, .other_unicode_char, "。");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "삼십이32");
}

test "lexing keywords" {
    const source =
        \\This docclass import imports packages endfun
        \\endenv nodocclass defun startdoc etxt mtxt mnd mst mnt begenv
    ;
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .text, "This");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .docclass, "docclass");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .import, "import");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "imports");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "packages");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .end_function_def, "endfun");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .endenv, "endenv");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .nodocclass, "nodocclass");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .function_def, "defun");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .start_doc, "startdoc");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .etxt, "etxt");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .mtxt, "mtxt");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text_math_end, "mnd");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text_math_start, "mst");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "mnt");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .begenv, "begenv");
    try expectToken(false, &lex, .eof, "");
}

test "lexing latex functions" {
    const source = "\\foo \\bar@hand \\frac{a @ b}";
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .latex_function, "\\foo");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .latex_function, "\\bar@hand");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .latex_function, "\\frac");
    try expectToken(false, &lex, .left_brace, "{");
    try expectToken(false, &lex, .text, "a");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .argument_splitter, "@");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "b");
    try expectToken(false, &lex, .right_brace, "}");
    try expectToken(false, &lex, .eof, "");
}

test "lexing basic vesti document" {
    const source =
        \\docclass coprime (tikz, korean)
        \\import {
        \\    geometry (a4paper, margin = 0.4in),
        \\    amsmath,
        \\}
        \\
        \\startdoc
        \\
        \\% A comment of the vesti
        \\This is a \LaTeX!
        \\\[
        \\    1 + 1 = \sum_{j=1}^\infty f(x),\qquad mtxt foobar etxt
        \\\]
        \\begenv center %[adadasdawd]
        \\    The TeX
        \\endenv
    ;
    var lex = Lexer.new(source);

    try expectToken(false, &lex, .docclass, "docclass");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "coprime");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .left_paren, "(");
    try expectToken(false, &lex, .text, "tikz");
    try expectToken(false, &lex, .comma, ",");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "korean");
    try expectToken(false, &lex, .right_paren, ")");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .import, "import");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .left_brace, "{");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "geometry");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .left_paren, "(");
    try expectToken(false, &lex, .text, "a4paper");
    try expectToken(false, &lex, .comma, ",");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "margin");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .equal, "=");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .float, "0.4");
    try expectToken(false, &lex, .text, "in");
    try expectToken(false, &lex, .right_paren, ")");
    try expectToken(false, &lex, .comma, ",");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "amsmath");
    try expectToken(false, &lex, .comma, ",");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .right_brace, "}");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .start_doc, "startdoc");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .text, "This");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "is");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "a");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .latex_function, "\\LaTeX");
    try expectToken(false, &lex, .bang, "!");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .display_math_start, "\\[");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .integer, "1");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .plus, "+");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .integer, "1");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .equal, "=");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .latex_function, "\\sum");
    try expectToken(false, &lex, .subscript, "_");
    try expectToken(false, &lex, .left_brace, "{");
    try expectToken(false, &lex, .text, "j");
    try expectToken(false, &lex, .equal, "=");
    try expectToken(false, &lex, .integer, "1");
    try expectToken(false, &lex, .right_brace, "}");
    try expectToken(false, &lex, .superscript, "^");
    try expectToken(false, &lex, .latex_function, "\\infty");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "f");
    try expectToken(false, &lex, .left_paren, "(");
    try expectToken(false, &lex, .text, "x");
    try expectToken(false, &lex, .right_paren, ")");
    try expectToken(false, &lex, .comma, ",");
    try expectToken(false, &lex, .latex_function, "\\qquad");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .mtxt, "mtxt");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "foobar");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .etxt, "etxt");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .display_math_end, "\\]");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .begenv, "begenv");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "center");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "The");
    try expectToken(false, &lex, .space, " ");
    try expectToken(false, &lex, .text, "TeX");
    try expectToken(false, &lex, .newline, "\n");
    try expectToken(false, &lex, .endenv, "endenv");
    try expectToken(false, &lex, .eof, "");
}

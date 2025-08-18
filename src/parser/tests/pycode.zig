const std = @import("std");
const diag = @import("../../diagnostic.zig");
const testing = std.testing;

const allocator = testing.allocator;

const Parser = @import("../Parser.zig");

test "basic pycode 1" {
    const source =
        \\pycode 聖者の行進
        \\    \\import vesti
        \\ 
        \\\\print("Hello, World!")
        \\            \\if x == 3:
        \\\\    pass
        \\    聖者の行進
    ;
    var diagnostic = diag.Diagnostic{
        .allocator = allocator,
        .source = .init(.Borrowed, .{source}),
    };
    defer diagnostic.deinit();

    var parser = try Parser.init(
        allocator,
        source,
        undefined,
        &diagnostic,
        true, // allow pycode for testing
        null, // disallow changing latex engine type
    );

    var ast = parser.parse() catch |err| switch (err) {
        Parser.ParseError.ParseFailed => {
            try diagnostic.prettyPrint(true);
            return err;
        },
        else => return err,
    };
    defer {
        for (ast.items) |*stmt| stmt.deinit(allocator);
        ast.deinit(allocator);
    }

    const expected_pycode =
        \\import vesti
        \\print("Hello, World!")
        \\if x == 3:
        \\    pass
        \\
    ;

    try testing.expectFmt(expected_pycode, "{s}", .{ast.items[0].PyCode.code.items});
}

test "basic pycode with imports" {
    const source =
        \\pycode 聖者の行進
        \\    \\import vesti
        \\ 
        \\\\print("Hello, World!")
        \\            \\if x == 3:
        \\\\    pass
        \\    聖者の行進[abcd, 가나다라]
    ;
    var diagnostic = diag.Diagnostic{
        .allocator = allocator,
        .source = .init(.Borrowed, .{source}),
    };
    defer diagnostic.deinit();

    var parser = try Parser.init(
        allocator,
        source,
        undefined,
        &diagnostic,
        true, // allow pycode for testing
        null, // disallow changing latex engine type
    );

    var ast = parser.parse() catch |err| switch (err) {
        Parser.ParseError.ParseFailed => {
            try diagnostic.prettyPrint(true);
            return err;
        },
        else => return err,
    };
    defer {
        for (ast.items) |*stmt| stmt.deinit(allocator);
        ast.deinit(allocator);
    }

    const expected_pycode =
        \\import vesti
        \\print("Hello, World!")
        \\if x == 3:
        \\    pass
        \\
    ;

    try testing.expect(ast.items[0] == .PyCode);
    try testing.expectFmt(expected_pycode, "{s}", .{ast.items[0].PyCode.code.items});
    try testing.expect(ast.items[0].PyCode.code_import != null);
    if (ast.items[0].PyCode.code_import) |import| {
        try testing.expect(import.items.len == 2);
        try testing.expectFmt("abcd", "{s}", .{import.items[0]});
        try testing.expectFmt("가나다라", "{s}", .{import.items[1]});
    }
}

test "basic pycode with noexport" {
    const source =
        // the <BRACKET> label `MAINPY` is preserved not to exporting pycode
        \\pycode MAINPY
        \\    \\import vesti
        \\ 
        \\\\print("Hello, World!")
        \\            \\if x == 3:
        \\\\    pass
        \\    MAINPY[abcd, 가나다라]
    ;
    var diagnostic = diag.Diagnostic{
        .allocator = allocator,
        .source = .init(.Borrowed, .{source}),
    };
    defer diagnostic.deinit();

    var parser = try Parser.init(
        allocator,
        source,
        undefined,
        &diagnostic,
        true, // allow pycode for testing
        null, // disallow changing latex engine type
    );

    var ast = parser.parse() catch |err| switch (err) {
        Parser.ParseError.ParseFailed => {
            try diagnostic.prettyPrint(true);
            return err;
        },
        else => return err,
    };
    defer {
        for (ast.items) |*stmt| stmt.deinit(allocator);
        ast.deinit(allocator);
    }

    const expected_pycode =
        \\import vesti
        \\print("Hello, World!")
        \\if x == 3:
        \\    pass
        \\
    ;

    try testing.expect(ast.items[0] == .PyCode);
    try testing.expectFmt(expected_pycode, "{s}", .{ast.items[0].PyCode.code.items});
    try testing.expect(ast.items[0].PyCode.code_import != null);
    if (ast.items[0].PyCode.code_import) |import| {
        try testing.expect(import.items.len == 2);
        try testing.expectFmt("abcd", "{s}", .{import.items[0]});
        try testing.expectFmt("가나다라", "{s}", .{import.items[1]});
    }
    try testing.expect(ast.items[0].PyCode.code_export == null);
}

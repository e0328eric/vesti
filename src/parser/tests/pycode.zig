const std = @import("std");
const diag = @import("../../diagnostic.zig");
const testing = std.testing;

const allocator = testing.allocator;

const Parser = @import("../Parser.zig");

test "basic pycode 1" {
    const source =
        \\pycode 聖者の行進
        \\    //import vesti
        \\ 
        \\//print("Hello, World!")
        \\            //if x == 3:
        \\//    pass
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


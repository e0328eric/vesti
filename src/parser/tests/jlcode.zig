const std = @import("std");
const diag = @import("../../diagnostic.zig");
const testing = std.testing;

const allocator = testing.allocator;

const Parser = @import("../Parser.zig");

test "basic jlcode" {
    const source =
        \\#jl:
        \\function test(x,y)
        \\  if x < y
        \\    println("x is less than y")
        \\  elseif x > y
        \\    println("x is greater than y")
        \\  else
        \\    println("x and y are equal")
        \\  end
        \\end
        \\:jl#
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
        true, // allow jlcode for testing
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

    const expected_jlcode =
        \\
        \\function test(x,y)
        \\  if x < y
        \\    println("x is less than y")
        \\  elseif x > y
        \\    println("x is greater than y")
        \\  else
        \\    println("x and y are equal")
        \\  end
        \\end
        \\
    ;

    try testing.expectFmt(expected_jlcode, "{s}", .{ast.items[0].JlCode.code.items});
}

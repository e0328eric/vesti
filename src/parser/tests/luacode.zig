const std = @import("std");
const diag = @import("../../diagnostic.zig");
const testing = std.testing;

const allocator = testing.allocator;

const Parser = @import("../Parser.zig");

test "basic luacode" {
    const source =
        \\#::#
        \\function test(x,y)
        \\  if x < y
        \\    println("x is less than y")
        \\  elseif x > y
        \\    println("x is greater than y")
        \\  else
        \\    println("x and y are equal")
        \\  end
        \\end
        \\#::#
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
        .{
            .luacode = true,
            .global_def = false,
        },
        .{ null, .pdflatex }, // disallow changing latex engine type
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

    const expected_luacode =
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

    try testing.expectFmt(expected_luacode, "{s}", .{ast.items[0].LuaCode.code.items});
}

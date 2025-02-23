const std = @import("std");
const mem = std.mem;

const diag = @import("../../diagnostic.zig");

const ArrayList = std.ArrayList;
const CowStr = @import("../../CowStr.zig").CowStr;
const Expr = @import("../ast.zig").Expr;
const Parser = @import("../Parser.zig");
const Stmt = @import("../ast.zig").Stmt;

const allocator = std.testing.allocator;
const Codegen = @import("../../Codegen.zig");

pub fn expect(
    source: []const u8,
    expected: []const u8,
    output_modifier: ?fn ([]const u8) []const u8,
) !void {
    var diagnostic = diag.Diagnostic{ .allocator = allocator };
    defer diagnostic.deinit();

    var parser = try Parser.init(allocator, source, undefined, &diagnostic);
    defer parser.deinit();

    const ast = parser.parse() catch |err| switch (err) {
        Parser.ParseError.ParseFailed => {
            try diagnostic.prettyPrint(true);
            return err;
        },
        else => return err,
    };
    defer {
        for (ast.items) |stmt| stmt.deinit();
        ast.deinit();
    }

    var output = try ArrayList(u8).initCapacity(allocator, 100);
    defer output.deinit();
    var codegen = try Codegen.init(allocator, source, ast.items, &diagnostic);
    defer codegen.deinit();
    try codegen.codegen(output.writer());

    if (output_modifier) |f| {
        if (!mem.eql(u8, f(output.items), expected)) {
            std.debug.print(
                \\
                \\========= Test failed =========
                \\expected: |{s}|
                \\obtained: |{s}|
                \\===============================
                \\
            ,
                .{ expected, f(output.items) },
            );
            return error.TestUnexpectedResult;
        }
    } else {
        if (!mem.eql(u8, output.items, expected)) {
            std.debug.print(
                \\
                \\========= Test failed =========
                \\expected: |{s}|
                \\obtained: |{s}|
                \\===============================
                \\
            ,
                .{ expected, output.items },
            );
            return error.TestUnexpectedResult;
        }
    }
}

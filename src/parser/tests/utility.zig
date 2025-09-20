const std = @import("std");
const mem = std.mem;

const diag = @import("../../diagnostic.zig");

const ArrayList = std.ArrayList;
const CowStr = @import("../../CowStr.zig").CowStr;
const Expr = @import("../ast.zig").Expr;
const Io = std.Io;
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

    var parser = try Parser.init(
        allocator,
        source,
        undefined,
        &diagnostic,
        false, // disallow jlcode for testing
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

    var output = try ArrayList(u8).initCapacity(allocator, 100);
    var aw: Io.Writer.Allocating = .fromArrayList(allocator, &output);
    defer aw.deinit();
    var codegen = try Codegen.init(
        allocator,
        source,
        ast.items,
        &diagnostic,
        .pdflatex, // in the test, this does nothing
        true, // disallow jlcode
    );
    defer codegen.deinit();
    try codegen.codegen(&aw.writer);

    output = aw.toArrayList();
    defer output.deinit(allocator);

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

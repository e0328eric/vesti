const std = @import("std");
const mem = std.mem;

const diag = @import("../../diagnostic.zig");

const ArrayList = std.ArrayList;
const Codegen = @import("../../Codegen.zig");
const CowStr = @import("../../CowStr.zig").CowStr;
const Expr = @import("../ast.zig").Expr;
const Io = std.Io;
const Parser = @import("../Parser.zig");
const Stmt = @import("../ast.zig").Stmt;

const allocator = std.testing.allocator;
const io = std.testing.io;

pub inline fn concatAmsText(comptime s: []const u8) []const u8 {
    return s ++ "\n\\usepackage{amstext}\n";
}

pub fn expect(
    source: []const u8,
    expected: []const u8,
    output_modifier: ?fn ([]const u8) []const u8,
) !void {
    const environ = std.testing.environ;
    var envmap = try environ.createMap(allocator);
    defer envmap.deinit();

    var diagnostic = diag.Diagnostic{ .allocator = allocator, .io = io };
    defer diagnostic.deinit();

    var parser = try Parser.init(
        allocator,
        io,
        &envmap,
        source,
        undefined,
        &diagnostic,
        .{
            .luacode = false,
            .global_def = false,
        },
        .{ null, .pdflatex }, // disallow changing latex engine type
    );
    defer parser.deinit();

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
        false,
        &diagnostic,
    );
    defer codegen.deinit();
    try codegen.codegen(null, null, &aw.writer); // disallow luacode

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

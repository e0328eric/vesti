const std = @import("std");
const Parser = @import("../../parser/Parser.zig");
const Codegen = @import("../../Codegen.zig");
const diag = @import("../../diagnostic.zig");
const a = std.testing.allocator;

fn generate(source: []const u8, diagnostic: *diag.Diagnostic) ![]u8 {
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    var parser = try Parser.init(a, std.testing.io, &env, source, undefined, diagnostic, .{ .luacode = false, .global_def = false }, .{ null, .pdflatex });
    defer parser.deinit();
    var stmts = try parser.parse();
    defer {
        for (stmts.items) |*stmt| stmt.deinit(a);
        stmts.deinit(a);
    }
    var cg = try Codegen.init(a, source, stmts.items, false, diagnostic);
    defer cg.deinit();
    var writer: std.Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    try cg.codegen(null, null, &writer.writer);
    return try a.dupe(u8, writer.written());
}

test "documents without native tables do not receive table runtime" {
    var diagnostic: diag.Diagnostic = .{ .allocator = a, .io = std.testing.io };
    defer diagnostic.deinit();
    const tex = try generate("Unchanged ordinary prose.", &diagnostic);
    defer a.free(tex);
    try std.testing.expectEqualStrings("Unchanged ordinary prose.", tex);
}

test "generated geometry supports all styles without importing any package" {
    var diagnostic: diag.Diagnostic = .{ .allocator = a, .io = std.testing.io };
    defer diagnostic.deinit();
    const tex = try generate(
        \\#tabular(width=200pt,grid=all) {
        \\ columns { col(width=flex(1)); col(width=flex(1)); }
        \\ body {
        \\  hline(style=solid,color=rgb(.1,.2,.3));
        \\  row { cell(colspan=2) { UNIQUE-TITLE } }
        \\  hline(style=double,thickness=1pt,gap=2pt);
        \\  row { cell(background=cmyk(0,.6,.1,0)) { UNIQUE-PINK } cell {} }
        \\  hline(style=dotted,gap=1pt);
        \\  row { cell {} cell {} }
        \\  hline(style=dashed,dashlength=4pt);
        \\  row { cell {} cell {} }
        \\  hline(style=dashdot,phase=.5pt);
        \\  row { cell {} cell {} }
        \\  hline(style=dashdotdot,thickness=.8pt);
        \\ }
        \\}
    , &diagnostic);
    defer a.free(tex);
    for ([_][]const u8{ "\\usepackage", "\\RequirePackage", "\\begin{tabular}", "\\begin{longtable}", "\\arrayrulecolor", "\\cellcolor", "\\multirow", "\\multicolumn", "\\includegraphics" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, tex, forbidden) == null);
    for ([_][]const u8{ "solid", "double", "dotted", "dashed", "dashdot", "dashdotdot" }) |style|
        try std.testing.expect(std.mem.indexOf(u8, tex, style) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tex, "UNIQUE-TITLE"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tex, "UNIQUE-PINK"));
}

test "long table empty sections compile and repeated content is emitted once" {
    var diagnostic: diag.Diagnostic = .{ .allocator = a, .io = std.testing.io };
    defer diagnostic.deinit();
    const tex = try generate(
        \\#longtabular(width=200pt,pageheight=150pt,grid=all) {
        \\ columns { col(width=flex(1)); col(width=flex(1)); }
        \\ lastfoot {} firsthead {}
        \\ head { row { cell(colspan=2) { UNIQUE-REPEATED-HEADER } } }
        \\ foot { row { cell(colspan=2) { UNIQUE-REPEATED-FOOTER } } }
        \\ body {
        \\  keep { row { cell { A } cell { B } } row { cell { C } cell { D } } }
        \\  break;
        \\  row { cell(rowspan=2) { UNIQUE-SPAN } cell { E } }
        \\  row { cell { F } }
        \\ }
        \\}
    , &diagnostic);
    defer a.free(tex);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tex, "UNIQUE-REPEATED-HEADER"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tex, "UNIQUE-REPEATED-FOOTER"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tex, "UNIQUE-SPAN"));
    try std.testing.expect(std.mem.indexOf(u8, tex, "\\vestiTBpaginate") != null);
    try std.testing.expect(std.mem.indexOf(u8, tex, "\\vestiTBdef{force1}{1}") != null);
}

test "normalized overlap errors retain code coordinates and both source locations" {
    var diagnostic: diag.Diagnostic = .{ .allocator = a, .io = std.testing.io };
    defer diagnostic.deinit();
    try std.testing.expectError(error.ParseFailed, generate(
        \\#tabular {
        \\ columns { col(width=30pt); col(width=30pt); col(width=30pt); }
        \\ body {
        \\  row { cell {} cell(rowspan=2) {} cell {} }
        \\  row { cell(colspan=2) {} }
        \\ }
        \\}
    , &diagnostic));
    const info = diagnostic.inner.?.ParseError.err_info.TableError;
    try std.testing.expectEqualStrings("T003", info.code);
    try std.testing.expectEqual(@as(?usize, 2), info.row);
    try std.testing.expectEqual(@as(?usize, 2), info.column);
    try std.testing.expectEqual(@as(usize, 4), info.related.?.start.row);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.inner.?.ParseError.span.?.start.row);
}

test "short native tables nest but long native tables are rejected inside cells" {
    var diagnostic: diag.Diagnostic = .{ .allocator = a, .io = std.testing.io };
    defer diagnostic.deinit();
    const tex = try generate(
        \\#tabular { columns { col(width=100pt); }
        \\ body { row { cell {
        \\  #tabular(width=80pt) { columns { col(width=flex(1)); }
        \\    body { row { cell { UNIQUE-NESTED } } } }
        \\ } } } }
    , &diagnostic);
    defer a.free(tex);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tex, "UNIQUE-NESTED"));
    try std.testing.expectError(error.ParseFailed, generate(
        \\#tabular { columns { col(width=100pt); }
        \\ body { row { cell {
        \\  #longtabular(width=80pt,pageheight=100pt) { columns { col(width=flex(1)); }
        \\    body { row { cell {} } } }
        \\ } } } }
    , &diagnostic));
    try std.testing.expect(diagnostic.inner != null);
}

test "recognized cell effects fail with T010 before emitting reusable content" {
    for ([_][]const u8{
        "\\global\\advance\\count0 by1",
        "\\gdef\\Shared{changed}",
        "\\write16{replayed write}",
        "\\insert0{insertion}",
        "\\label{repeated-anchor}",
        "\\newpage",
        "\\footnote{footnote}",
    }) |body| {
        var diagnostic: diag.Diagnostic = .{ .allocator = a, .io = std.testing.io };
        defer diagnostic.deinit();
        const source = try std.mem.concat(a, u8, &.{
            "#tabular { columns { col(width=100pt); } body { row { cell { ",
            body,
            " } } } }",
        });
        defer a.free(source);
        try std.testing.expectError(error.ParseFailed, generate(source, &diagnostic));
        try std.testing.expectEqualStrings("T010", diagnostic.inner.?.ParseError.err_info.TableError.code);
    }
}

test "font-hook effects are checked on columns rows and cells" {
    for ([_][]const u8{
        "#tabular { columns { col(width=100pt,before={\\global\\advance\\count0 by1}); } body { row { cell {} } } }",
        "#tabular { columns { col(width=100pt); } body { row(before={\\write16{bad}}) { cell {} } } }",
        "#tabular { columns { col(width=100pt); } body { row { cell(before={\\label{bad}}) {} } } }",
    }) |source| {
        var diagnostic: diag.Diagnostic = .{ .allocator = a, .io = std.testing.io };
        defer diagnostic.deinit();
        try std.testing.expectError(error.ParseFailed, generate(source, &diagnostic));
        try std.testing.expectEqualStrings("T010", diagnostic.inner.?.ParseError.err_info.TableError.code);
    }
}

test "potentially equivalent explicit border units and phases emit a runtime check" {
    var diagnostic: diag.Diagnostic = .{ .allocator = a, .io = std.testing.io };
    defer diagnostic.deinit();
    const tex = try generate(
        \\#tabular { columns { col(width=100pt); }
        \\ body {
        \\  hline(style=dotted,thickness=1pc,gap=24pt,phase=36pt);
        \\  hline(style=dotted,thickness=12pt,gap=2pc,phase=0pt);
        \\  row { cell { Equivalent signatures } }
        \\ }
        \\}
    , &diagnostic);
    defer a.free(tex);
    try std.testing.expect(std.mem.indexOf(u8, tex, "\\vestiTBcheckstyles{1}{2}") != null);
}

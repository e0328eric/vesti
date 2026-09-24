const std = @import("std");
const Parser = @import("../Parser.zig");
const ast = @import("../ast.zig");
const model = @import("../../table/model.zig");
const diag = @import("../../diagnostic.zig");
const a = std.testing.allocator;

fn parseCheck(source: []const u8, comptime check: fn (*const model.Table) anyerror!void) !void {
    var envmap = try std.testing.environ.createMap(a);
    defer envmap.deinit();
    var diagnostic: diag.Diagnostic = .{ .allocator = a, .io = std.testing.io };
    defer diagnostic.deinit();
    var parser = try Parser.init(a, std.testing.io, &envmap, source, undefined, &diagnostic, .{ .luacode = false, .global_def = false }, .{ null, .pdflatex });
    defer parser.deinit();
    var stmts = try parser.parse();
    defer {
        for (stmts.items) |*s| s.deinit(a);
        stmts.deinit(a);
    }
    try std.testing.expect(stmts.items.len > 0);
    try std.testing.expect(stmts.items[0] == .Table);
    try check(stmts.items[0].Table);
}

fn rejects(source: []const u8) !void {
    var envmap = try std.testing.environ.createMap(a);
    defer envmap.deinit();
    var diagnostic: diag.Diagnostic = .{ .allocator = a, .io = std.testing.io };
    defer diagnostic.deinit();
    var parser = try Parser.init(a, std.testing.io, &envmap, source, undefined, &diagnostic, .{ .luacode = false, .global_def = false }, .{ null, .pdflatex });
    defer parser.deinit();
    if (parser.parse()) |result| {
        var stmts = result;
        defer {
            for (stmts.items) |*s| s.deinit(a);
            stmts.deinit(a);
        }
        return error.TestExpectedError;
    } else |err| try std.testing.expectEqual(error.ParseFailed, err);
    try std.testing.expect(diagnostic.inner != null);
}

test "native table parses typed defaults, spans, colors, before and nested content" {
    try parseCheck(
        \\#tabular(width=200pt, grid=all, rulewidth=.4pt, rulecolor=rgb(.1,.2,.3),) {
        \\ columns { col(width=flex(1), before={\bf}); col(width=40pt); }
        \\ body {
        \\  row { cell(colspan=2,background=cmyk(0,.6,.1,0)) { Stock {nested} $x$ \& \$ } }
        \\  row { cell(rowspan=2) { A } cell { B } }
        \\  row { cell {} }
        \\ }
        \\}
    , struct {
        fn check(t: *const model.Table) !void {
            try std.testing.expectEqual(model.Kind.short, t.kind);
            try std.testing.expectEqual(@as(f64, 200), t.options.width.dimension.value);
            try std.testing.expectEqual(model.Grid.all, t.options.grid);
            try std.testing.expectEqual(@as(usize, 2), t.columns.items.len);
            try std.testing.expect(t.columns.items[0].before.items.len > 0);
            const body = t.section(.body).?;
            try std.testing.expectEqual(@as(usize, 3), body.rows.items.len);
            try std.testing.expectEqual(@as(usize, 2), body.rows.items[0].cells.items[0].options.colspan);
            try std.testing.expectEqual(@as(f64, 0.6), body.rows.items[0].cells.items[0].options.background.?.cmyk[1]);
            try std.testing.expectEqual(@as(usize, 2), body.rows.items[1].cells.items[0].options.rowspan);
        }
    }.check);
}

test "native table long sections keep and boundary positions are retained" {
    try parseCheck(
        \\#longtabular(width=\hsize,pageheight=8in) {
        \\ columns { col(width=flex(1)); }
        \\ lastfoot {} head { row { cell { Header } } } firsthead {}
        \\ body { keep { row { cell { A } } hline; row { cell { B } } }
        \\ break; row { cell { C } } nobreak; row { cell { D } } }
        \\}
    , struct {
        fn check(t: *const model.Table) !void {
            try std.testing.expectEqual(model.Kind.long, t.kind);
            try std.testing.expectEqual(model.Register.hsize, t.options.width.register);
            try std.testing.expectEqual(@as(usize, 0), t.section(.firsthead).?.rows.items.len);
            try std.testing.expect(t.section(.foot) == null);
            const body = t.section(.body).?;
            try std.testing.expectEqual(@as(usize, 1), body.keeps.items.len);
            try std.testing.expectEqual(@as(usize, 2), body.keeps.items[0].end);
            try std.testing.expectEqual(@as(usize, 2), body.boundaries.items[0].after);
            try std.testing.expectEqual(@as(usize, 1), body.hlines.items[0].boundary);
        }
    }.check);
}

test "native table six border styles parse with independent pattern overrides" {
    try parseCheck(
        \\#tabular(rulestyle=dashed,rulegap=2pt,ruledashlength=auto,rulephase=.2pt) {
        \\ columns { col(width=30pt); }
        \\ body { hline(style=solid); row { cell { A } }
        \\ hline(style=double,thickness=.8pt,gap=auto,color=gray(.4));
        \\ vline(after=0,style=dotted,gap=1pt);
        \\ vline(after=1,style=dashed,dashlength=4pt);
        \\ hline(style=dashdot,dashlength=3pt,phase=.5pt);
        \\ hline(style=dashdotdot,dashlength=3pt,gap=1pt); }
        \\}
    , struct {
        fn check(t: *const model.Table) !void {
            const s = t.section(.body).?;
            try std.testing.expectEqual(model.Pattern.dashed, t.options.border.style);
            try std.testing.expectEqual(model.Pattern.solid, s.hlines.items[0].style.style.?);
            try std.testing.expectEqual(model.Pattern.double, s.hlines.items[1].style.style.?);
            try std.testing.expectEqual(model.Pattern.dotted, s.vlines.items[0].style.style.?);
            try std.testing.expectEqual(model.Pattern.dashdotdot, s.hlines.items[3].style.style.?);
        }
    }.check);
}

test "native table invalid schemas fail without leaking partially parsed content" {
    const tail = " { columns { col(width=10pt); } body { row { cell { A } } } }";
    inline for (.{
        "#tabular()",                     "#tabular(width=10pt,width=10pt)", "#tabular(bogus=1)",
        "#tabular(width=2 pt)",           "#tabular(width=-1pt)",            "#tabular(width=1e2pt)",
        "#tabular(rulecolor=rgb(1,2,0))", "#tabular(rulewidth=0pt)",         "#tabular(rulecolor=gray(.))",
        "#tabular(pageheight=10pt)",      "#longtabular(width=10pt)",        "#longtabular(pageheight=20pt)",
    }) |prefix| try rejects(prefix ++ tail);
    try rejects("#tabular { columns { col(align=center); } body { row { cell { A } } } }");
    try rejects("#tabular { columns { col(width=flex(1)); } body { row { cell { A } } } }");
    try rejects("#tabular { columns { col(width=10pt); } body {} }");
    try rejects("#tabular { columns { col(width=10pt); } body { row { cell(rowspan=0) {} } } }");
    try rejects("#tabular { columns { col(width=10pt); } body { row(before={a},bad=1) {} } }");
    try rejects("#tabular { columns { col(width=10pt); } body { row { cell { A } } } head {} }");
    try rejects("#tabular { columns { col(width=10pt); } body { row { cell { A } } } body {} }");
    try rejects("#tabular { columns { col(width=10pt); } body { vline(style=dotted); } }");
    try rejects("#longtabular(width=10pt,pageheight=20pt) { columns { col(width=10pt); } body { break; row { cell {} } } }");
    try rejects("#longtabular(width=10pt,pageheight=20pt) { columns { col(width=10pt); } body { row { cell {} } break; } }");
    try rejects("$ #tabular { columns { col(width=10pt); } body { row { cell {} } } } $");
    try rejects("#tabular { columns { col(width=10pt); } body { keep { keep {} } } }");
    try rejects("#tabular { columns { col(width=10pt); } body { row { cell { unclosed }");
}

test "native table cell braces use raw tokens and nested builtin parsing" {
    try parseCheck(
        \\#tabular {
        \\ columns { col(width=natural); }
        \\ body { row { cell {
        \\   %-{ raw brace is not a structural token -%
        \\   #tabular { columns { col(width=natural); } body { row { cell { nested } } } }
        \\ } } }
        \\}
    , struct {
        fn check(t: *const model.Table) !void {
            var nested: usize = 0;
            for (t.section(.body).?.rows.items[0].cells.items[0].body.items) |stmt| {
                if (stmt == .Table) nested += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), nested);
        }
    }.check);
}

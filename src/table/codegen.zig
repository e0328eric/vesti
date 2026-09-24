//! Native tables lower to a primitive box compositor; no table packages.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const Model = @import("model.zig");
const Layout = @import("layout.zig");
const Codegen = @import("../Codegen.zig");
const Lua = @import("../Lua.zig");
const Writer = std.Io.Writer;
const Error = Codegen.Error;

fn contains(stmts: []const ast.Stmt) bool {
    for (stmts) |s| switch (s) {
        .Table => return true,
        .MathCtx => |v| {
            if (contains(v.inner.items)) return true;
        },
        .Braced => |v| {
            if (contains(v.inner.items)) return true;
        },
        .Fraction => |v| {
            if (contains(v.numerator.items) or contains(v.denominator.items)) return true;
        },
        .PlainTextInMath => |v| {
            if (contains(v.inner.items)) return true;
        },
        .DefineFunction => |v| {
            if (contains(v.inner.items)) return true;
        },
        .DefineEnv => |v| {
            if (contains(v.inner_begin.items) or contains(v.inner_end.items)) return true;
        },
        .Environment => |v| {
            if (contains(v.inner.items)) return true;
            for (v.args.items) |arg| if (contains(arg.ctx.items)) return true;
        },
        .PictureEnvironment => |v| {
            if (contains(v.inner.items)) return true;
        },
        .BeginPhantomEnviron => |v| {
            for (v.args.items) |arg| if (contains(arg.ctx.items)) return true;
        },
        else => {},
    };
    return false;
}

pub fn prologue(stmts: []const ast.Stmt, placeholder: ?*const std.ArrayList(ast.Stmt), w: *Writer) Error!void {
    if (!contains(stmts) and !(if (placeholder) |p| contains(p.items) else false)) return;
    try w.writeAll("\n% Vesti native table support: no package imports.\n\\expandafter\\ifx\\csname vestiTBversion\\endcsname\\relax\n");
    inline for (.{
        @embedFile("runtime.tex"),
        @embedFile("paint_runtime.tex"),
        @embedFile("layout_runtime.tex"),
        @embedFile("pager_runtime.tex"),
    }) |runtime| {
        // Plain format allocation macros are outer. Hide their tokens while a
        // repeated module's guard is being skipped by TeX's conditional scanner.
        var lines = std.mem.splitScalar(u8, runtime, '\n');
        while (lines.next()) |line| {
            var allocated = false;
            inline for (.{ "newbox", "newdimen", "newcount" }) |name| {
                if (std.mem.startsWith(u8, line, "\\" ++ name)) {
                    try w.writeAll("\\csname " ++ name ++ "\\endcsname");
                    try w.writeAll(line[name.len + 1 ..]);
                    allocated = true;
                }
            }
            if (!allocated) try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    try w.writeAll("\\fi\n");
}

const Emitter = struct {
    cg: *Codegen,
    t: *const Model.Table,
    plan: *const Layout.Normalized,
    lua: ?*Lua,
    placeholder: ?*const std.ArrayList(ast.Stmt),
    w: *Writer,
    styles: std.ArrayList(Model.BorderStyle) = .empty,

    fn fail(self: *Emitter, message: []const u8) Error {
        self.cg.diagnostic.initDiagInner(.{ .ParseError = .{ .err_info = .{ .IllegalUseErr = message }, .span = self.t.span } });
        return error.ParseFailed;
    }
    fn checkContent(self: *Emitter, stmts: []const ast.Stmt, span: Model.Span) Error!void {
        if (@import("effects.zig").contains(stmts)) {
            self.cg.diagnostic.initDiagInner(.{ .ParseError = .{ .err_info = .{ .TableError = .{
                .code = "T010",
                .message = "table cells must be reusable boxes; global mutation, insertions, floats, labels, writes and page/output changes are unsupported",
            } }, .span = span } });
            return error.ParseFailed;
        }
    }
    fn styleId(self: *Emitter, style: Model.BorderStyle) Error!usize {
        for (self.styles.items, 1..) |s, id| if (std.meta.eql(s, style)) return id;
        try self.styles.append(self.cg.allocator, style);
        return self.styles.items.len;
    }
    fn edgeId(self: *Emitter, edge: ?Layout.Edge) Error!i64 {
        if (edge) |e| {
            const id: i64 = @intCast(try self.styleId(e.style));
            return if (e.explicit) -id else id;
        }
        return 0;
    }
    fn dim(self: *Emitter, d: Model.Dim) Error!void {
        try self.w.print("{d:.9}{s}", .{ d.value, @tagName(d.unit) });
    }
    fn width(self: *Emitter, d: Model.Width) Error!void {
        switch (d) {
            .dimension => |v| try self.dim(v),
            .register => |v| try self.w.print("\\{s}", .{@tagName(v)}),
            else => unreachable,
        }
    }
    fn color(self: *Emitter, c: Model.Color) Error!void {
        try self.w.print("{{{s}}}{{", .{@tagName(c)});
        switch (c) {
            .gray => |v| try self.w.print("{d:.9}", .{v}),
            .rgb => |v| try self.w.print("{d:.9} {d:.9} {d:.9}", .{ v[0], v[1], v[2] }),
            .cmyk => |v| try self.w.print("{d:.9} {d:.9} {d:.9} {d:.9}", .{ v[0], v[1], v[2], v[3] }),
        }
        try self.w.writeByte('}');
    }
    fn wrapped(self: *Emitter, c: Layout.Cell) bool {
        const col = self.t.columns.items[c.col];
        return c.source.options.wrap orelse col.wrap orelse (col.width != .natural);
    }
    fn prepare(self: *Emitter) Error!void {
        const w = self.w;
        if (self.cg.table_depth == 1) try w.writeAll("\\par\n");
        for (self.plan.sections) |s| {
            for (s.horizontal) |e| {
                _ = try self.edgeId(e);
            }
            for (s.vertical) |e| {
                _ = try self.edgeId(e);
            }
            for (s.deferred_conflicts) |conflict| {
                _ = try self.styleId(conflict.first.style);
                _ = try self.styleId(conflict.second.style);
            }
        }
        try w.print("\n% Native {s}, source {d}:{d}\n\\begingroup\n\\vestiTBcols={d}\\relax\n", .{ @tagName(self.t.kind), self.t.span.start.row, self.t.span.start.col, self.t.columns.items.len });
        try w.print("\\def\\vestiTBtablesource{{{d}:{d}}}\n", .{ self.t.span.start.row, self.t.span.start.col });
        try w.writeAll("\\vestiTBset{hostwidth}{\\hsize}\n\\setbox\\vestiTBunwrapped=\\vbox{}\\setbox\\vestiTBwrapped=\\vbox{}\\setbox\\vestiTBgroups=\\vbox{}\n");
        inline for (.{ "padx", "pady", "minheight" }) |name| {
            try w.writeAll("\\vestiTBset{" ++ name ++ "}{");
            try self.dim(@field(self.t.options, name));
            try w.writeAll("}\n");
        }
        if (self.t.options.width != .natural) {
            try w.writeAll("\\vestiTBset{targetwidth}{");
            try self.width(self.t.options.width);
            try w.writeAll("}\n");
        }
        if (self.t.options.pageheight) |h| {
            try w.writeAll("\\vestiTBset{pageheight}{");
            try self.width(h);
            try w.writeAll("}\n\\vestiTBpreflight\n\\ifnum\\vestiTBpagerok=1\\relax\n");
        }
        for (self.styles.items, 1..) |style, id| try self.emitStyle(style, id);
        for (self.plan.sections) |s| for (s.deferred_conflicts) |c| {
            try w.print("\\vestiTBcheckstyles{{{d}}}{{{d}}}\n", .{ try self.styleId(c.first.style), try self.styleId(c.second.style) });
        };
        // Font-relative lengths are frozen before any column/row/cell font hook.
        for (self.t.columns.items, 0..) |col, i| {
            try w.print("\\vestiTBset{{col{d}w}}{{", .{i});
            if (col.width == .dimension) try self.dim(col.width.dimension) else try w.writeAll("0pt");
            try w.writeAll("}\n");
        }
        for (0..self.t.columns.items.len + 1) |j| {
            try w.print("\\vestiTBset{{lane{d}w}}{{0pt}}\n", .{j});
            for (self.plan.sections) |s| for (0..s.row_count) |r| if (s.vEdge(r, j)) |e| {
                try w.print("\\vestiTBmax{{lane{d}w}}{{\\vestiTBget{{e{d}e}}}}\n", .{ j, try self.styleId(e.style) });
            };
        }
        for (self.plan.sections, 0..) |s, si| {
            for (0..s.row_count + 1) |r| {
                try w.print("\\vestiTBset{{s{d}b{d}}}{{0pt}}\n", .{ si, r });
                for (0..s.column_count) |c| if (s.hEdge(r, c)) |e| {
                    try w.print("\\vestiTBmax{{s{d}b{d}}}{{\\vestiTBget{{e{d}e}}}}\n", .{ si, r, try self.styleId(e.style) });
                };
            }
            for (s.source.rows.items, 0..) |row, r| {
                try w.print("\\vestiTBset{{s{d}r{d}h}}{{", .{ si, r });
                if (row.options.minheight) |h| try self.dim(h) else try w.writeAll("\\vestiTBget{minheight}");
                try w.writeAll("}\n");
            }
        }
    }
    fn emitStyle(self: *Emitter, s: Model.BorderStyle, id: usize) Error!void {
        const w = self.w;
        try w.print("\\vestiTBdef{{e{d}style}}{{{s}}}\\vestiTBset{{e{d}t}}{{", .{ id, @tagName(s.style), id });
        try self.dim(s.thickness);
        try w.writeAll("}\n");
        if (s.style == .solid) {
            try w.print("\\vestiTBset{{e{d}g}}{{0pt}}\n", .{id});
        } else switch (s.gap) {
            .dimension => |d| {
                try w.print("\\vestiTBset{{e{d}g}}{{", .{id});
                try self.dim(d);
                try w.writeAll("}\n");
            },
            .auto => try w.print("\\vestiTBautolength{{{d}}}{{g}}{{{d}}}\n", .{ id, @as(u8, if (s.style == .double) 1 else 2) }),
        }
        switch (s.style) {
            .solid, .double => try w.print("\\vestiTBset{{e{d}d}}{{0pt}}\n", .{id}),
            .dotted => try w.print("\\vestiTBset{{e{d}d}}{{\\vestiTBget{{e{d}t}}}}\n", .{ id, id }),
            else => switch (s.dashlength) {
                .dimension => |d| {
                    try w.print("\\vestiTBset{{e{d}d}}{{", .{id});
                    try self.dim(d);
                    try w.writeAll("}\n");
                },
                .auto => try w.print("\\vestiTBautolength{{{d}}}{{d}}{{4}}\n", .{id}),
            },
        }
        try w.print("\\vestiTBset{{e{d}p}}{{", .{id});
        if (s.style == .solid or s.style == .double) try w.writeAll("0pt") else try self.dim(s.phase);
        try w.writeAll("}\n");
        try w.print("\\vestiTBvalidatestyle{{{d}}}\n", .{id});
        if (s.style != .solid and s.style != .double) try w.print("\\vestiTBnormalizephase{{{d}}}{{{d}}}\n", .{ id, @as(u8, switch (s.style) {
            .dashdot => 4,
            .dashdotdot => 6,
            else => 2,
        }) });
        try w.print("\\vestiTBdef{{e{d}model}}{{{s}}}\\vestiTBdef{{e{d}color}}{{", .{ id, @tagName(s.color), id });
        switch (s.color) {
            .gray => |v| try w.print("{d:.9}", .{v}),
            .rgb => |v| try w.print("{d:.9} {d:.9} {d:.9}", .{ v[0], v[1], v[2] }),
            .cmyk => |v| try w.print("{d:.9} {d:.9} {d:.9} {d:.9}", .{ v[0], v[1], v[2], v[3] }),
        }
        try w.print("}}\n\\expandafter\\edef\\csname vestiTBve{d}sign\\endcsname{{{s}/\\vestiTBget{{e{d}t}}/\\vestiTBget{{e{d}g}}/\\vestiTBget{{e{d}d}}/\\vestiTBget{{e{d}p}}/\\vestiTBget{{e{d}model}}/\\vestiTBget{{e{d}color}}}}\n", .{ id, @tagName(s.style), id, id, id, id, id, id });
    }

    fn measure(self: *Emitter, wrap: bool) Error!void {
        const w = self.w;
        try w.writeAll("\\setbox\\vestiTBstack=\\vbox{}\n");
        for (self.plan.sections, 0..) |s, si| for (s.cells, 0..) |c, ci| {
            if (self.wrapped(c) != wrap) continue;
            const col = self.t.columns.items[c.col];
            try w.print("% cell {d}:{d}, section {s}, row {d}, column {d}\n\\setbox\\vestiTBcellbox=\\{s}{{\\def\\vestiTBcellsource{{{d}:{d}, row {d}, column {d}}}\\vestiTBguardcell\n", .{ c.source.span.start.row, c.source.span.start.col, @tagName(s.source.kind), c.row + 1, c.col + 1, if (wrap) "vbox" else "hbox", c.source.span.start.row, c.source.span.start.col, c.row + 1, c.col + 1 });
            if (wrap) {
                try w.print("\\hsize=\\vestiTBget{{s{d}c{d}inner}}\\relax\\parindent=0pt\n", .{ si, ci });
                switch (c.source.options.@"align" orelse col.@"align") {
                    .left => try w.writeAll("\\leftskip=0pt\\rightskip=0pt plus1fil\\parfillskip=0pt plus1fil\n"),
                    .center => try w.writeAll("\\leftskip=0pt plus1fil\\rightskip=0pt plus1fil\\parfillskip=0pt\n"),
                    .right => try w.writeAll("\\leftskip=0pt plus1fil\\rightskip=0pt\\parfillskip=0pt\n"),
                }
            }
            try self.cg.codegenStmts(&col.before, self.lua, self.placeholder, w);
            try w.writeAll("\\relax\n");
            try self.cg.codegenStmts(&s.source.rows.items[c.row].options.before, self.lua, self.placeholder, w);
            try w.writeAll("\\relax\n");
            try self.cg.codegenStmts(&c.source.options.before, self.lua, self.placeholder, w);
            try w.writeAll("\\relax\n");
            try self.cg.codegenStmts(&c.source.body, self.lua, self.placeholder, w);
            if (wrap) try w.writeAll("\\par");
            try w.writeAll("}%\n");
            inline for (.{ "w", "h", "d" }, .{ "wd", "ht", "dp" }) |suffix, primitive| {
                try w.print("\\vestiTBset{{s{d}c{d}{s}}}{{\\{s}\\vestiTBcellbox}}\n", .{ si, ci, suffix, primitive });
            }
            try w.writeAll("\\vestiTBstore\n");
        };
        try w.print("\\setbox\\vestiTB{s}=\\box\\vestiTBstack\n", .{if (wrap) "wrapped" else "unwrapped"});
    }
    fn cellWidth(self: *Emitter, si: usize, ci: usize, c: Layout.Cell) Error!void {
        const w = self.w;
        try w.print("\\vestiTBset{{s{d}c{d}rectw}}{{0pt}}\n", .{ si, ci });
        for (c.col..c.col + c.colspan) |j| try w.print("\\vestiTBadd{{s{d}c{d}rectw}}{{\\vestiTBget{{col{d}w}}}}\n", .{ si, ci, j });
        for (c.col + 1..c.col + c.colspan) |j| try w.print("\\vestiTBadd{{s{d}c{d}rectw}}{{\\vestiTBget{{lane{d}w}}}}\n", .{ si, ci, j });
    }
    fn widths(self: *Emitter) Error!void {
        const w = self.w;
        for (self.plan.sections, 0..) |s, si| for (s.cells, 0..) |c, ci| {
            if (self.wrapped(c) or c.colspan != 1 or self.t.columns.items[c.col].width != .natural) continue;
            try w.print("\\vestiTBscratch=\\vestiTBget{{s{d}c{d}w}}\\relax\\advance\\vestiTBscratch by\\vestiTBget{{padx}}\\relax\\advance\\vestiTBscratch by\\vestiTBget{{padx}}\\relax\n\\vestiTBmax{{col{d}w}}{{\\vestiTBscratch}}\n", .{ si, ci, c.col });
        };
        for (2..self.t.columns.items.len + 1) |span| {
            for (self.plan.sections, 0..) |s, si| for (s.cells, 0..) |c, ci| {
                if (self.wrapped(c) or c.colspan != span) continue;
                var n: usize = 0;
                var flex = false;
                for (self.t.columns.items[c.col .. c.col + c.colspan]) |col| {
                    if (col.width == .natural) n += 1;
                    if (col.width == .flex) flex = true;
                }
                if (n == 0 or flex) continue;
                try self.cellWidth(si, ci, c);
                try w.print("\\vestiTBdeficit=\\vestiTBget{{s{d}c{d}w}}\\relax\\advance\\vestiTBdeficit by\\vestiTBget{{padx}}\\relax\\advance\\vestiTBdeficit by\\vestiTBget{{padx}}\\relax\\advance\\vestiTBdeficit by-\\vestiTBget{{s{d}c{d}rectw}}\\relax\n\\ifdim\\vestiTBdeficit>0pt\\vestiTBshare=\\vestiTBdeficit\\divide\\vestiTBshare by{d}\\relax\n", .{ si, ci, si, ci, n });
                for (self.t.columns.items[c.col .. c.col + c.colspan], c.col..) |col, j| if (col.width == .natural) {
                    n -= 1;
                    try w.print("\\vestiTBadd{{col{d}w}}{{\\vestiTB{s}}}\\advance\\vestiTBdeficit by-\\vestiTBshare\n", .{ j, if (n == 0) "deficit" else "share" });
                };
                try w.writeAll("\\fi\n");
            };
        }
        try w.writeAll("\\vestiTBset{totalwidth}{0pt}\n");
        var weight_max: f64 = 0;
        var flex_count: usize = 0;
        for (self.t.columns.items, 0..) |col, j| {
            if (col.width == .flex) {
                weight_max = @max(weight_max, col.width.flex);
                flex_count += 1;
            }
            try w.print("\\vestiTBadd{{totalwidth}}{{\\vestiTBget{{col{d}w}}}}\n", .{j});
        }
        for (0..self.t.columns.items.len + 1) |j| try w.print("\\vestiTBadd{{totalwidth}}{{\\vestiTBget{{lane{d}w}}}}\n", .{j});
        if (self.t.options.width != .natural) {
            try w.writeAll("\\vestiTBavailable=\\vestiTBget{targetwidth}\\relax\\advance\\vestiTBavailable by-\\vestiTBget{totalwidth}\\relax\n");
            if (flex_count == 0) {
                try w.writeAll("\\ifdim\\vestiTBavailable<0pt\\vestiTBavailable=-\\vestiTBavailable\\fi\n\\ifdim\\vestiTBavailable>1sp\\vestiTBwidtherror{target \\vestiTBget{targetwidth} differs from tracks plus border lanes \\vestiTBget{totalwidth}}\\fi\n");
            } else {
                try w.writeAll("\\ifdim\\vestiTBavailable>0pt\\else\\vestiTBwidtherror{tracks plus border lanes \\vestiTBget{totalwidth} exhaust target \\vestiTBget{targetwidth}}\\vestiTBavailable=1sp\\fi\n\\vestiTBdeficit=\\vestiTBavailable\n");
                var weight_total: f64 = 0;
                for (self.t.columns.items) |col| if (col.width == .flex) {
                    weight_total += col.width.flex / weight_max;
                };
                for (self.t.columns.items, 0..) |col, j| if (col.width == .flex) {
                    flex_count -= 1;
                    if (flex_count == 0) try w.writeAll("\\vestiTBshare=\\vestiTBdeficit\n") else {
                        const numerator: u32 = @intFromFloat(@round((col.width.flex / weight_max) / weight_total * 1000000000));
                        try w.print("\\vestiTBweighted{{{d}}}{{1000000000}}\n", .{numerator});
                    }
                    try w.print("\\vestiTBset{{col{d}w}}{{\\vestiTBshare}}\\advance\\vestiTBdeficit by-\\vestiTBshare\n", .{j});
                };
                try w.writeAll("\\vestiTBset{totalwidth}{\\vestiTBget{targetwidth}}\n");
            }
        }
        try w.writeAll("\\vestiTBset{lane0x}{0pt}\n");
        for (self.t.columns.items, 0..) |_, j| {
            try w.print("\\vestiTBscratch=\\vestiTBget{{col{d}w}}\\relax\\advance\\vestiTBscratch by-\\vestiTBget{{padx}}\\relax\\advance\\vestiTBscratch by-\\vestiTBget{{padx}}\\relax\n\\ifdim\\vestiTBscratch>0pt\\else\\vestiTBwidtherror{{column {d} has no positive content width}}\\fi\n", .{ j, j + 1 });
            try w.print("\\vestiTBset{{col{d}x}}{{\\vestiTBget{{lane{d}x}}}}\\vestiTBadd{{col{d}x}}{{\\vestiTBget{{lane{d}w}}}}\n\\vestiTBset{{lane{d}x}}{{\\vestiTBget{{col{d}x}}}}\\vestiTBadd{{lane{d}x}}{{\\vestiTBget{{col{d}w}}}}\n", .{ j, j, j, j, j + 1, j, j + 1, j });
        }
        for (self.plan.sections, 0..) |s, si| for (s.cells, 0..) |c, ci| {
            try self.cellWidth(si, ci, c);
            try w.print("\\vestiTBset{{s{d}c{d}inner}}{{\\vestiTBget{{s{d}c{d}rectw}}}}\\vestiTBadd{{s{d}c{d}inner}}{{-\\vestiTBget{{padx}}}}\\vestiTBadd{{s{d}c{d}inner}}{{-\\vestiTBget{{padx}}}}\n", .{ si, ci, si, ci, si, ci, si, ci });
            if (!self.wrapped(c)) try w.print("\\vestiTBfit{{s{d}c{d}}}{{{d}:{d} (row {d}, column {d})}}\n", .{ si, ci, c.source.span.start.row, c.source.span.start.col, c.row + 1, c.col + 1 });
        };
    }

    fn cellHeight(self: *Emitter, si: usize, ci: usize, c: Layout.Cell) Error!void {
        try self.w.print("\\vestiTBset{{s{d}c{d}recth}}{{0pt}}\n", .{ si, ci });
        for (c.row..c.row + c.rowspan) |r| try self.w.print("\\vestiTBadd{{s{d}c{d}recth}}{{\\vestiTBget{{s{d}r{d}h}}}}\n", .{ si, ci, si, r });
        for (c.row + 1..c.row + c.rowspan) |r| try self.w.print("\\vestiTBadd{{s{d}c{d}recth}}{{\\vestiTBget{{s{d}b{d}}}}}\n", .{ si, ci, si, r });
    }
    fn heights(self: *Emitter) Error!void {
        const w = self.w;
        for (self.plan.sections, 0..) |s, si| {
            for (s.cells, 0..) |c, ci| {
                try w.print("\\vestiTBset{{s{d}c{d}need}}{{\\vestiTBget{{s{d}c{d}h}}}}\\vestiTBadd{{s{d}c{d}need}}{{\\vestiTBget{{s{d}c{d}d}}}}\\vestiTBadd{{s{d}c{d}need}}{{\\vestiTBget{{pady}}}}\\vestiTBadd{{s{d}c{d}need}}{{\\vestiTBget{{pady}}}}\n", .{ si, ci, si, ci, si, ci, si, ci, si, ci, si, ci });
                if (c.rowspan == 1) try w.print("\\vestiTBmax{{s{d}r{d}h}}{{\\vestiTBget{{s{d}c{d}need}}}}\n", .{ si, c.row, si, ci });
            }
            var spanning: std.ArrayList(usize) = .empty;
            defer spanning.deinit(self.cg.allocator);
            for (s.cells, 0..) |c, ci| if (c.rowspan > 1) {
                try spanning.append(self.cg.allocator, ci);
            };
            std.mem.sort(usize, spanning.items, s.cells, struct {
                fn less(cells: []Layout.Cell, a: usize, b: usize) bool {
                    return if (cells[a].rowspan == cells[b].rowspan) a < b else cells[a].rowspan < cells[b].rowspan;
                }
            }.less);
            for (spanning.items) |ci| {
                const c = s.cells[ci];
                try self.cellHeight(si, ci, c);
                try w.print("\\vestiTBdeficit=\\vestiTBget{{s{d}c{d}need}}\\relax\\advance\\vestiTBdeficit by-\\vestiTBget{{s{d}c{d}recth}}\\relax\n\\ifdim\\vestiTBdeficit>0pt\\vestiTBshare=\\vestiTBdeficit\\divide\\vestiTBshare by{d}\\relax\n", .{ si, ci, si, ci, c.rowspan });
                for (c.row..c.row + c.rowspan) |r| try w.print("\\vestiTBadd{{s{d}r{d}h}}{{\\vestiTB{s}}}\\advance\\vestiTBdeficit by-\\vestiTBshare\n", .{ si, r, if (r + 1 == c.row + c.rowspan) "deficit" else "share" });
                try w.writeAll("\\fi\n");
            }
            try w.print("\\vestiTBset{{s{d}r0y}}{{0pt}}\n", .{si});
            var current_group: usize = 0;
            for (0..s.row_count) |r| {
                var restart = false;
                if (self.t.kind == .long and s.source.kind == .body) {
                    if (current_group + 1 < s.groups.len and s.groups[current_group + 1].first == r + 1) {
                        restart = true;
                        current_group += 1;
                    }
                }
                if (restart) {
                    try w.print("\\vestiTBset{{s{d}r{d}y}}{{0pt}}\n", .{ si, r + 1 });
                    continue;
                }
                try w.print("\\vestiTBset{{s{d}r{d}y}}{{\\vestiTBget{{s{d}r{d}y}}}}\\vestiTBadd{{s{d}r{d}y}}{{\\vestiTBget{{s{d}r{d}h}}}}\n", .{ si, r + 1, si, r, si, r + 1, si, r });
                if (r + 1 < s.row_count) try w.print("\\vestiTBadd{{s{d}r{d}y}}{{\\vestiTBget{{s{d}b{d}}}}}\n", .{ si, r + 1, si, r + 1 });
            }
            for (s.cells, 0..) |c, ci| try self.cellHeight(si, ci, c);
        }
    }

    fn hVector(self: *Emitter, s: Layout.Section, boundary: usize) Error!void {
        for (0..s.column_count) |j| try self.w.print("\\vestiTBhitem{{{d}}}{{{d}}}", .{ j, try self.edgeId(s.hEdge(boundary, j)) });
    }
    fn cellStart(s: Layout.Section, row: usize) usize {
        var lo: usize = 0;
        var hi = s.cells.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (s.cells[mid].row < row) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
    fn part(self: *Emitter, s: Layout.Section, si: usize, group: Layout.Group, name: []const u8, is_body: bool) Error!void {
        const w = self.w;
        const cell_first = cellStart(s, group.first);
        const cell_end = cellStart(s, group.end);
        try w.print("\\vestiTBdef{{{s}rowcount}}{{{d}}}\n", .{ name, group.end - group.first });
        try w.print("\\vestiTBdef{{{s}source}}{{{s} rows {d}--{d}}}\n", .{ name, @tagName(s.source.kind), group.first + 1, group.end });
        try w.print("\\vestiTBset{{{s}height}}{{0pt}}\n", .{name});
        for (group.first..group.end) |r| {
            try w.print("\\vestiTBadd{{{s}height}}{{\\vestiTBget{{s{d}r{d}h}}}}\n", .{ name, si, r });
            if (r > group.first) try w.print("\\vestiTBadd{{{s}height}}{{\\vestiTBget{{s{d}b{d}}}}}\n", .{ name, si, r });
        }
        try w.print("\\vestiTBdef{{{s}top}}{{", .{name});
        try self.hVector(s, group.first);
        try w.writeAll("}\n");
        try w.print("\\vestiTBdef{{{s}bottom}}{{", .{name});
        if (group.first != group.end) try self.hVector(s, group.end);
        try w.writeAll("}\n");
        try w.print("\\vestiTBdef{{{s}rows}}{{%\n", .{name});
        for (group.first..group.end) |r| {
            if (r > group.first) {
                try w.writeAll("\\vestiTBpaintjoin{");
                try self.hVector(s, r);
                try w.writeAll("}%\n");
            }
            try w.print("\\vestiTBpaintrow{{\\vestiTBget{{s{d}r{d}h}}}}{{", .{ si, r });
            for (0..s.column_count + 1) |j| try w.print("\\vestiTBvitem{{{d}}}{{{d}}}", .{ j, try self.edgeId(s.vEdge(r, j)) });
            try w.writeAll("}%\n");
        }
        try w.writeAll("}\n");
        try w.print("\\vestiTBdef{{{s}background}}{{%\n", .{name});
        for (s.cells[cell_first..cell_end], cell_first..) |c, ci| {
            const bg = c.source.options.background orelse s.source.rows.items[c.row].options.background orelse continue;
            try w.print("\\vestiTBplaceY=\\vestiTBget{{s{d}r{d}y}}\\relax\\advance\\vestiTBplaceY by-\\vestiTBget{{s{d}r{d}y}}\\relax\\advance\\vestiTBplaceY by\\vestiTBorigin\n\\vestiTBrect{{\\vestiTBget{{col{d}x}}}}{{\\vestiTBplaceY}}{{\\vestiTBget{{s{d}c{d}rectw}}}}{{\\vestiTBget{{s{d}c{d}recth}}}}", .{ si, c.row, si, group.first, c.col, si, ci, si, ci });
            try self.color(bg);
            try w.writeAll("%\n");
        }
        try w.writeAll("}\n\\setbox\\vestiTBgroupcanvas=\\hbox{}\n");
        var rev = cell_end;
        while (rev > cell_first) {
            rev -= 1;
            const c = s.cells[rev];
            const ci = rev;
            const stack = if (self.wrapped(c)) "wrapped" else "unwrapped";
            try w.print("\\setbox\\vestiTBstack=\\box\\vestiTB{s}\\vestiTBpop\\setbox\\vestiTB{s}=\\box\\vestiTBstack\n", .{ stack, stack });
            inline for (.{ "w", "h", "d" }, .{ "wd", "ht", "dp" }) |suffix, primitive| try w.print("\\{s}\\vestiTBcellbox=\\vestiTBget{{s{d}c{d}{s}}}\\relax\n", .{ primitive, si, ci, suffix });
            try w.print("\\vestiTBplaceX=\\vestiTBget{{s{d}c{d}inner}}\\relax\\advance\\vestiTBplaceX by-\\wd\\vestiTBcellbox\n", .{ si, ci });
            switch (c.source.options.@"align" orelse self.t.columns.items[c.col].@"align") {
                .left => try w.writeAll("\\vestiTBplaceX=0pt\n"),
                .center => try w.writeAll("\\divide\\vestiTBplaceX by2\n"),
                .right => {},
            }
            try w.print("\\advance\\vestiTBplaceX by\\vestiTBget{{col{d}x}}\\relax\\advance\\vestiTBplaceX by\\vestiTBget{{padx}}\\relax\n", .{c.col});
            try w.print("\\vestiTBplaceY=\\vestiTBget{{s{d}c{d}recth}}\\relax\\advance\\vestiTBplaceY by-\\vestiTBget{{s{d}c{d}need}}\\relax\n", .{ si, ci, si, ci });
            switch (c.source.options.valign orelse self.t.columns.items[c.col].valign orelse self.t.options.valign) {
                .top => try w.writeAll("\\vestiTBplaceY=0pt\n"),
                .middle => try w.writeAll("\\divide\\vestiTBplaceY by2\n"),
                .bottom => {},
            }
            try w.print("\\advance\\vestiTBplaceY by\\vestiTBget{{pady}}\\relax\\advance\\vestiTBplaceY by\\vestiTBget{{s{d}r{d}y}}\\relax\\advance\\vestiTBplaceY by-\\vestiTBget{{s{d}r{d}y}}\\relax\n\\setbox\\vestiTBgroupcanvas=\\hbox{{\\unhbox\\vestiTBgroupcanvas\\vestiTBplace{{\\vestiTBplaceX}}{{\\vestiTBplaceY}}}}\n", .{ si, c.row, si, group.first });
        }
        if (is_body) {
            try w.writeAll("\\setbox\\vestiTBcellbox=\\box\\vestiTBgroupcanvas\\setbox\\vestiTBstack=\\box\\vestiTBgroups\\vestiTBstore\\setbox\\vestiTBgroups=\\box\\vestiTBstack\n");
            try w.print("\\vestiTBdef{{{s}load}}{{\\vestiTBloadgroup}}\n", .{name});
        } else {
            try w.print("\\setbox\\vestiTB{s}=\\box\\vestiTBgroupcanvas\\vestiTBdef{{{s}load}}{{\\setbox\\vestiTBcellbox=\\copy\\vestiTB{s}}}\n", .{ name, name, name });
        }
    }
    fn parts(self: *Emitter) Error!void {
        // Consume the two retained-cell stacks in reverse source order.
        var si = self.plan.sections.len;
        while (si > 0) {
            si -= 1;
            const s = self.plan.sections[si];
            if (s.source.kind == .body) {
                if (self.t.kind == .short) {
                    try self.part(s, si, .{ .first = 0, .end = s.row_count }, "G1", true);
                    try self.w.writeAll("\\vestiTBgroupcount=1\\relax\n");
                } else {
                    try self.w.print("\\vestiTBgroupcount={d}\\relax\n", .{s.groups.len});
                    var gi = s.groups.len;
                    while (gi > 0) {
                        gi -= 1;
                        var buf: [32]u8 = undefined;
                        const name = std.fmt.bufPrint(&buf, "G{d}", .{gi + 1}) catch unreachable;
                        try self.part(s, si, s.groups[gi], name, true);
                        try self.w.print("\\vestiTBdef{{force{d}}}{{{d}}}\n", .{ gi + 1, @as(u8, if (s.boundaries[s.groups[gi].end].forced) 1 else 0) });
                    }
                }
            } else try self.part(s, si, .{ .first = 0, .end = s.row_count }, @tagName(s.source.kind), false);
        }
        inline for (.{ Model.SectionKind.head, .foot, .firsthead, .lastfoot }) |kind| {
            const name = @tagName(kind);
            if (self.plan.section(kind) == null) {
                if (self.plan.effectiveSection(kind)) |effective| {
                    const base = @tagName(effective.source.kind);
                    inline for (.{ "height", "top", "bottom", "rows", "background", "load", "rowcount" }) |suffix| try self.w.print("\\vestiTBdef{{{s}{s}}}{{\\vestiTBget{{{s}{s}}}}}\n", .{ name, suffix, base, suffix });
                } else {
                    try self.w.writeAll("\\vestiTBdef{" ++ name ++ "rowcount}{0}\n");
                    try self.w.writeAll("\\vestiTBdef{" ++ name ++ "height}{0pt}\\vestiTBdef{" ++ name ++ "load}{\\setbox\\vestiTBcellbox=\\hbox{}}\n");
                    inline for (.{ "top", "bottom", "rows", "background" }) |suffix| try self.w.writeAll("\\vestiTBdef{" ++ name ++ suffix ++ "}{}\n");
                }
            }
        }
    }
    fn finish(self: *Emitter) Error!void {
        const w = self.w;
        if (self.t.kind == .long) {
            try w.writeAll("\\def\\vestiTBpagerdetails{At \\vestiTBtablesource, \\vestiTBget{G\\the\\vestiTBpagerfirst source}; content extents: group=\\vestiTBget{G\\the\\vestiTBpagerfirst height}, head=\\vestiTBget{\\vestiTBpagerhead height}, continued foot=\\vestiTBget{footheight}, final foot=\\vestiTBget{lastfootheight}. }\n");
            try w.writeAll("\\def\\vestiTBpageleftglue{");
            if (self.t.options.@"align" != .left) try w.writeAll("\\hfil");
            try w.writeAll("}\\def\\vestiTBpagerightglue{");
            if (self.t.options.@"align" != .right) try w.writeAll("\\hfil");
            try w.writeAll("}\\vestiTBpaginate\n\\fi\n");
        } else {
            try w.writeAll("\\vestiTBpaintstart\\vestiTBpaintpart{G1}\\vestiTBpaintfinish\n\\setbox\\vestiTBcanvas=\\hbox{\\raise\\dp\\vestiTBcanvas\\box\\vestiTBcanvas}\n");
            if (self.cg.table_depth > 1) try w.writeAll("\\box\\vestiTBcanvas\n") else {
                try w.writeAll("\\par\\noindent\\hbox to\\vestiTBget{hostwidth}{");
                if (self.t.options.@"align" != .left) try w.writeAll("\\hfil");
                try w.writeAll("\\box\\vestiTBcanvas");
                if (self.t.options.@"align" != .right) try w.writeAll("\\hfil");
                try w.writeAll("}\\par\n");
            }
        }
        try w.writeAll("\\endgroup\n");
    }
};

pub fn emit(cg: *Codegen, t: *const Model.Table, lua: ?*Lua, placeholder: ?*const std.ArrayList(ast.Stmt), w: *Writer) Error!void {
    var failure: ?Layout.Failure = null;
    var plan = Layout.normalize(cg.allocator, t, &failure) catch |err| switch (err) {
        error.InvalidTable => {
            const f = failure.?;
            cg.diagnostic.initDiagInner(.{ .ParseError = .{ .err_info = .{ .TableError = .{
                .code = f.code,
                .message = f.message,
                .related = f.related,
                .row = f.row,
                .column = f.column,
            } }, .span = f.span } });
            return error.ParseFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer plan.deinit(cg.allocator);
    var e: Emitter = .{ .cg = cg, .t = t, .plan = &plan, .lua = lua, .placeholder = placeholder, .w = w };
    defer e.styles.deinit(cg.allocator);
    for (t.columns.items) |c| try e.checkContent(c.before.items, c.span);
    for (t.sections.items) |s| for (s.rows.items) |r| {
        try e.checkContent(r.options.before.items, r.span);
        for (r.cells.items) |c| {
            try e.checkContent(c.options.before.items, c.span);
            try e.checkContent(c.body.items, c.span);
        }
    };
    if (t.kind == .long and cg.table_depth != 0) return e.fail("T009: longtabular cannot be nested inside another table");
    if (cg.table_depth != 0 and t.options.width == .natural) return e.fail("T009: a nested tabular requires an explicit finite width");
    cg.table_depth += 1;
    defer cg.table_depth -= 1;
    try e.prepare();
    try e.measure(false);
    try e.widths();
    try e.measure(true);
    try e.heights();
    try e.parts();
    try e.finish();
}

test {
    _ = @import("tests/codegen.zig");
}

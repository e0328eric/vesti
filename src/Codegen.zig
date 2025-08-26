const std = @import("std");
const diag = @import("diagnostic.zig");
const ast = @import("parser/ast.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const LatexEngine = @import("parser/Parser.zig").LatexEngine;
const Python = @import("Python.zig");
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;
const Span = @import("location.zig").Span;

const Error = Allocator.Error || Io.Writer.Error || Python.Error || error{
    PyLabelNotFound,
    DuplicatedPyLabel,
    PyEvalFailed,
};

allocator: Allocator,
source: []const u8,
stmts: []const ast.Stmt,
diagnostic: *diag.Diagnostic,
pycode_exports: StringArrayHashMap(ArrayList(u8)),
py: ?Python,

const Self = @This();

pub fn init(
    allocator: Allocator,
    source: []const u8,
    stmts: []const ast.Stmt,
    diagnostic: *diag.Diagnostic,
    engine: LatexEngine,
    comptime disallow_pycode: bool,
) !Self {
    var py: ?Python = if (disallow_pycode) null else Python.init(engine) catch {
        const io_diag = try diag.IODiagnostic.init(
            allocator,
            null,
            "failed to initialize python vm",
            .{},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.PyInitFailed;
    };
    errdefer if (py) |*p| p.deinit();

    return Self{
        .allocator = allocator,
        .source = source,
        .stmts = stmts,
        .diagnostic = diagnostic,
        .pycode_exports = .{},
        .py = py,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    for (self.pycode_exports.values()) |*code| {
        code.deinit(allocator);
    }
    self.pycode_exports.deinit(allocator);
    if (self.py) |*py| py.deinit();
}

pub fn codegen(
    self: *Self,
    writer: *Io.Writer,
) Error!void {
    for (self.stmts) |stmt| {
        try self.codegenStmt(stmt, writer);
    }
}

fn codegenStmts(
    self: *Self,
    stmts: ArrayList(ast.Stmt),
    writer: *Io.Writer,
) Error!void {
    for (stmts.items) |stmt| {
        try self.codegenStmt(stmt, writer);
    }
}

fn codegenStmt(
    self: *Self,
    stmt: ast.Stmt,
    writer: *Io.Writer,
) Error!void {
    switch (stmt) {
        .NopStmt => {},
        .NonStopMode => try writer.writeAll("\n\\nonstopmode\n"),
        .MakeAtLetter => try writer.writeAll("\n\\makeatletter\n"),
        .MakeAtOther => try writer.writeAll("\n\\makeatother\n"),
        .Latex3On => try writer.writeAll("\n\\ExplSyntaxOn\n"),
        .Latex3Off => try writer.writeAll("\n\\ExplSyntaxOff\n"),
        .ImportExpl3Pkg => try writer.writeAll("\\usepackage{expl3, xparse}\n"),
        .TextLit, .MathLit => |ctx| try writer.writeAll(ctx),
        .MathCtx => |math_ctx| {
            const delimiter = switch (math_ctx.state) {
                .Inline => .{ "$", "$" },
                .Display => .{ "\\[", "\\]" },
            };
            try writer.writeAll(delimiter[0]);
            try self.codegenStmts(math_ctx.ctx, writer);
            try writer.writeAll(delimiter[1]);
        },
        .Braced => |bs| {
            if (!bs.unwrap_brace) try writer.writeByte('{');
            try self.codegenStmts(bs.inner, writer);
            if (!bs.unwrap_brace) try writer.writeByte('}');
        },
        .Fraction => |fraction| {
            try writer.writeAll("\\frac{");
            try self.codegenStmts(fraction.numerator, writer);
            try writer.writeAll("}{");
            try self.codegenStmts(fraction.denominator, writer);
            try writer.writeByte('}');
        },
        .DocumentStart => try writer.writeAll("\n\\begin{document}"),
        .DocumentEnd => try writer.writeAll("\n\\end{document}\n"),
        .DocumentClass => |docclass| {
            try writer.writeAll("\\documentclass");
            if (docclass.options) |options| {
                try writer.writeByte('[');
                var i: usize = 0;
                while (i + 1 < options.items.len) : (i += 1) {
                    try writer.print("{f},", .{options.items[i]});
                } else {
                    try writer.print("{f}]", .{options.items[i]});
                }
            }
            try writer.print("{{{f}}}\n", .{docclass.name});
        },
        .ImportSinglePkg => |usepkg| {
            try writer.writeAll("\\usepackage");
            if (usepkg.options) |options| {
                try writer.writeByte('[');
                var i: usize = 0;
                while (i + 1 < options.items.len) : (i += 1) {
                    try writer.print("{f},", .{options.items[i]});
                } else {
                    try writer.print("{f}]", .{options.items[i]});
                }
            }
            try writer.print("{{{f}}}\n", .{usepkg.name});
        },
        .ImportMultiplePkgs => |usepkgs| {
            for (usepkgs.items) |usepkg|
                try self.codegenStmt(ast.Stmt{ .ImportSinglePkg = usepkg }, writer);
        },
        .PlainTextInMath => |info| {
            try writer.writeAll("\\text{");
            if (info.add_front_space) try writer.writeByte(' ');
            try self.codegenStmts(info.inner, writer);
            if (info.add_back_space) try writer.writeByte(' ');
            try writer.writeByte('}');
        },
        .MathDelimiter => |info| {
            switch (info.kind) {
                .None => try writer.writeAll(info.delimiter),
                .LeftBig => try writer.print("\\left{s}", .{info.delimiter}),
                .RightBig => try writer.print("\\right{s}", .{info.delimiter}),
            }
        },
        .Environment => |info| {
            try writer.print("\\begin{{{f}}}", .{info.name});
            for (info.args.items) |arg| {
                switch (arg.needed) {
                    .MainArg => {
                        try writer.writeByte('{');
                        try self.codegenStmts(arg.ctx, writer);
                        try writer.writeByte('}');
                    },
                    .Optional => {
                        try writer.writeByte('[');
                        try self.codegenStmts(arg.ctx, writer);
                        try writer.writeByte(']');
                    },
                    .StarArg => try writer.writeByte('*'),
                }
            }
            try self.codegenStmts(info.inner, writer);
            try writer.print("\\end{{{f}}}", .{info.name});
        },
        .BeginPhantomEnviron => |info| {
            try writer.print("\\begin{{{f}}}", .{info.name});
            for (info.args.items) |arg| {
                switch (arg.needed) {
                    .MainArg => {
                        try writer.writeByte('{');
                        try self.codegenStmts(arg.ctx, writer);
                        try writer.writeByte('}');
                    },
                    .Optional => {
                        try writer.writeByte('[');
                        try self.codegenStmts(arg.ctx, writer);
                        try writer.writeByte(']');
                    },
                    .StarArg => try writer.writeByte('*'),
                }
            }
            if (info.add_newline) {
                try writer.writeByte('\n');
            }
        },
        .EndPhantomEnviron => |name| try writer.print("\\end{{{f}}}\n", .{name}),
        .ImportVesti => |name| try writer.print("\\input{{{s}}}", .{name.items}),
        .FilePath => |name| try writer.print("{f}", .{name}),
        .PyCode => |cb| {
            if (self.py) |*py| {
                var new_code = try ArrayList(u8).initCapacity(
                    self.allocator,
                    cb.code.items.len,
                );
                errdefer new_code.deinit(self.allocator);

                if (cb.code_import) |import_arr_list| {
                    for (import_arr_list.items) |import_label| {
                        if (self.pycode_exports.get(import_label)) |import_code| {
                            try new_code.appendSlice(self.allocator, import_code.items);
                            try new_code.append(self.allocator, '\n');
                        } else {
                            const label_not_found = try diag.ParseDiagnostic.pyLabelNotFound(
                                self.diagnostic.allocator,
                                cb.code_span,
                                import_label,
                            );
                            self.diagnostic.initDiagInner(.{ .ParseError = label_not_found });
                            return error.PyLabelNotFound;
                        }
                    }
                }

                if (cb.code_export) |export_label| {
                    if (self.pycode_exports.get(export_label) != null) {
                        self.diagnostic.initDiagInner(.{ .ParseError = .{
                            .err_info = .{ .DuplicatedPyLabel = export_label },
                            .span = cb.code_span,
                        } });
                        return error.DuplicatedPyLabel;
                    }
                    try new_code.appendSlice(self.allocator, cb.code.items);
                    try self.pycode_exports.put(self.allocator, export_label, new_code);
                    return;
                }

                try new_code.appendSlice(self.allocator, cb.code.items);
                try new_code.append(self.allocator, 0);

                // TODO: print appropriate error message
                if (!py.runPyCode(@ptrCast(new_code.items))) {
                    const py_runtime_err = try diag.ParseDiagnostic.pyEvalFailed(
                        self.diagnostic.allocator,
                        cb.code_span,
                        "vesti library in python emits an error",
                        .{},
                        "see above python error message",
                    );
                    self.diagnostic.initDiagInner(.{ .ParseError = py_runtime_err });
                    return error.PyEvalFailed;
                }

                var ves_output = try py.getVestiOutputStr(self.allocator);
                defer ves_output.deinit(self.allocator);
                try writer.writeAll(ves_output.items);

                new_code.deinit(self.allocator);
            }
        },
        .Int, .Float => undefined, // TODO: deprecated
    }
}

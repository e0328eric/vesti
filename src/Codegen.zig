const std = @import("std");
const diag = @import("./diagnostic.zig");
const ast = @import("./parser/ast.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const StringArrayHashMap = std.StringArrayHashMap;
const Lua = @import("./Lua.zig");

const Error = Allocator.Error || Lua.Error || error{
    LuaInitFailed,
    LuaLabelNotFound,
    DuplicatedLuaLabel,
    LuaEvalFailed,
};

allocator: Allocator,
source: []const u8,
stmts: []const ast.Stmt,
diagnostic: *diag.Diagnostic,
luacode_exports: StringArrayHashMap(ArrayList(u8)),
lua: Lua,

const Self = @This();

pub fn init(
    allocator: Allocator,
    source: []const u8,
    stmts: []const ast.Stmt,
    diagnostic: *diag.Diagnostic,
) !Self {
    const lua = Lua.init(allocator) catch {
        const io_diag = try diag.IODiagnostic.init(
            allocator,
            null,
            "failed to initialize lua vm",
            .{},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.LuaInitFailed;
    };
    errdefer lua.deinit();

    const luacode_exports = StringArrayHashMap(ArrayList(u8)).init(allocator);
    errdefer luacode_exports.deinit();

    return Self{
        .allocator = allocator,
        .source = source,
        .stmts = stmts,
        .diagnostic = diagnostic,
        .luacode_exports = luacode_exports,
        .lua = lua,
    };
}

pub fn deinit(self: *Self) void {
    for (self.luacode_exports.values()) |code| {
        code.deinit();
    }
    self.luacode_exports.deinit();
    self.lua.deinit();
}

pub fn codegen(
    self: *Self,
    writer: anytype,
) Error!void {
    for (self.stmts) |stmt| {
        try self.codegenStmt(stmt, writer);
    }
}

fn codegenStmts(
    self: *Self,
    stmts: ArrayList(ast.Stmt),
    writer: anytype,
) Error!void {
    for (stmts.items) |stmt| {
        try self.codegenStmt(stmt, writer);
    }
}

fn codegenStmt(
    self: *Self,
    stmt: ast.Stmt,
    writer: anytype,
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
        .Braced => |inner_stmts| {
            try writer.writeByte('{');
            try self.codegenStmts(inner_stmts, writer);
            try writer.writeByte('}');
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
                    try writer.print("{cows},", .{options.items[i]});
                } else {
                    try writer.print("{cows}]", .{options.items[i]});
                }
            }
            try writer.print("{{{cows}}}\n", .{docclass.name});
        },
        .ImportSinglePkg => |usepkg| {
            try writer.writeAll("\\usepackage");
            if (usepkg.options) |options| {
                try writer.writeByte('[');
                var i: usize = 0;
                while (i + 1 < options.items.len) : (i += 1) {
                    try writer.print("{cows},", .{options.items[i]});
                } else {
                    try writer.print("{cows}]", .{options.items[i]});
                }
            }
            try writer.print("{{{cows}}}\n", .{usepkg.name});
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
            try writer.print("\\begin{{{cows}}}", .{info.name});
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
            try writer.print("\\end{{{cows}}}", .{info.name});
        },
        .BeginPhantomEnviron => |info| {
            try writer.print("\\begin{{{cows}}}", .{info.name});
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
        .EndPhantomEnviron => |name| try writer.print("\\end{{{cows}}}\n", .{name}),
        .ImportVesti => |name| try writer.print("\\input{{{s}}}", .{name.items}),
        .FilePath => |name| try writer.print("{cows}", .{name}),
        .LuaCode => |cb| {
            var new_code = try ArrayList(u8).initCapacity(
                self.allocator,
                cb.code.len,
            );
            errdefer new_code.deinit();

            if (cb.code_import) |import_arr_list| {
                for (import_arr_list.items) |import_label| {
                    if (self.luacode_exports.get(import_label)) |import_code| {
                        try new_code.appendSlice(import_code.items);
                        try new_code.append('\n');
                    } else {
                        const label_not_found = try diag.ParseDiagnostic.luaLabelNotFound(
                            self.diagnostic.allocator,
                            cb.code_span,
                            import_label,
                        );
                        self.diagnostic.initDiagInner(.{ .ParseError = label_not_found });
                        return error.LuaLabelNotFound;
                    }
                }
            }

            if (cb.code_export) |export_label| {
                if (self.luacode_exports.get(export_label) != null) {
                    self.diagnostic.initDiagInner(.{ .ParseError = .{
                        .err_info = .{ .DuplicatedLuaLabel = export_label },
                        .span = cb.code_span,
                    } });
                    return error.DuplicatedLuaLabel;
                }
                try new_code.appendSlice(cb.code);
                try self.luacode_exports.put(export_label, new_code);
                return;
            }

            try new_code.appendSlice(cb.code);
            try new_code.append(0);

            // TODO: print appropriate error message
            self.lua.evalCode(@ptrCast(new_code.items)) catch |err| {
                // the very top element is an "error" string
                const err_str = self.lua.lua.toString(-1) catch unreachable;
                const lua_runtime_err = try diag.ParseDiagnostic.luaEvalFailed(
                    self.diagnostic.allocator,
                    cb.code_span,
                    "{}",
                    .{err},
                    err_str,
                );
                self.diagnostic.initDiagInner(.{ .ParseError = lua_runtime_err });
                return error.LuaEvalFailed;
            };
            if (self.lua.getError()) |err_str| {
                const lua_runtime_err = try diag.ParseDiagnostic.luaEvalFailed(
                    self.diagnostic.allocator,
                    cb.code_span,
                    "vesti library in lua emits an error",
                    .{},
                    err_str,
                );
                self.diagnostic.initDiagInner(.{ .ParseError = lua_runtime_err });
                return error.LuaEvalFailed;
            }
            const ves_output = self.lua.getVestiOutputStr();
            try writer.writeAll(ves_output);

            self.lua.clearVestiOutputStr();
            new_code.deinit();
        },
        .Int, .Float => undefined, // TODO: deprecated
    }
}

const std = @import("std");
const diag = @import("diagnostic.zig");
const ast = @import("parser/ast.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const LatexEngine = @import("parser/Parser.zig").LatexEngine;
const ParseError = @import("parser/Parser.zig").ParseError;
const Lua = @import("Lua.zig");
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;
const Span = @import("location.zig").Span;

const Error = Allocator.Error || Io.Writer.Error || ParseError ||
    error{
        LuaLabelNotFound,
        DuplicatedLuaLabel,
        LuaEvalFailed,
    };

allocator: Allocator,
source: []const u8,
stmts: []const ast.Stmt,
diagnostic: *diag.Diagnostic,
luacode_exports: StringArrayHashMap(ArrayList(u8)),

const Self = @This();

pub fn init(
    allocator: Allocator,
    source: []const u8,
    stmts: []const ast.Stmt,
    diagnostic: *diag.Diagnostic,
) !Self {
    return Self{
        .allocator = allocator,
        .source = source,
        .stmts = stmts,
        .diagnostic = diagnostic,
        .luacode_exports = .empty,
    };
}

pub fn deinit(self: *Self) void {
    for (self.luacode_exports.values()) |*code| {
        code.deinit(self.allocator);
    }
    self.luacode_exports.deinit(self.allocator);
}

pub fn codegen(
    self: *Self,
    lua: ?*Lua,
    writer: *Io.Writer,
) Error!void {
    for (self.stmts) |stmt| {
        try self.codegenStmt(stmt, lua, writer);
    }
}

fn codegenStmts(
    self: *Self,
    stmts: ArrayList(ast.Stmt),
    lua: ?*Lua,
    writer: *Io.Writer,
) Error!void {
    for (stmts.items) |stmt| {
        try self.codegenStmt(stmt, lua, writer);
    }
}

fn codegenStmt(
    self: *Self,
    stmt: ast.Stmt,
    lua: ?*Lua,
    writer: *Io.Writer,
) Error!void {
    switch (stmt) {
        .NopStmt => {},
        .TextLit => |ctx| try writer.print("{f}", .{ctx}),
        .MathLit => |ctx| try writer.writeAll(ctx),
        .MathCtx => |math_ctx| {
            const delimiter = switch (math_ctx.state) {
                .Inline => .{ "$", "$" },
                .Display => .{ "\\[", "\\]" },
                .Labeled => .{ "\\begin{equation}", "\\end{equation}" },
            };
            try writer.writeAll(delimiter[0]);
            if (math_ctx.label) |label| {
                try writer.print("\\label{{{s}}}", .{label.items});
            }
            try self.codegenStmts(math_ctx.inner, lua, writer);
            try writer.writeAll(delimiter[1]);
        },
        .Braced => |bs| {
            if (!bs.unwrap_brace) try writer.writeByte('{');
            try self.codegenStmts(bs.inner, lua, writer);
            if (!bs.unwrap_brace) try writer.writeByte('}');
        },
        .Fraction => |fraction| {
            try writer.writeAll("\\frac{");
            try self.codegenStmts(fraction.numerator, lua, writer);
            try writer.writeAll("}{");
            try self.codegenStmts(fraction.denominator, lua, writer);
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
                try self.codegenStmt(
                    ast.Stmt{ .ImportSinglePkg = usepkg },
                    lua,
                    writer,
                );
        },
        .PlainTextInMath => |info| {
            try writer.writeAll("\\text{");
            if (info.add_front_space) try writer.writeByte(' ');
            try self.codegenStmts(info.inner, lua, writer);
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
                        try self.codegenStmts(arg.ctx, lua, writer);
                        try writer.writeByte('}');
                    },
                    .Optional => {
                        try writer.writeByte('[');
                        try self.codegenStmts(arg.ctx, lua, writer);
                        try writer.writeByte(']');
                    },
                    .StarArg => try writer.writeByte('*'),
                }
            }
            if (info.label) |label| {
                try writer.print("\\label{{{s}}}", .{label.items});
            }
            try self.codegenStmts(info.inner, lua, writer);
            try writer.print("\\end{{{f}}}", .{info.name});
        },
        .BeginPhantomEnviron => |info| {
            try writer.print("\\begin{{{f}}}", .{info.name});
            for (info.args.items) |arg| {
                switch (arg.needed) {
                    .MainArg => {
                        try writer.writeByte('{');
                        try self.codegenStmts(arg.ctx, lua, writer);
                        try writer.writeByte('}');
                    },
                    .Optional => {
                        try writer.writeByte('[');
                        try self.codegenStmts(arg.ctx, lua, writer);
                        try writer.writeByte(']');
                    },
                    .StarArg => try writer.writeByte('*'),
                }
            }
            if (info.add_newline) {
                try writer.writeByte('\n');
            }
        },
        .EndPhantomEnviron => |name| try writer.print("\\end{{{f}}}", .{name}),
        .ImportVesti => |name| try writer.print("\\input{{{s}}}", .{name.items}),
        .FilePath => |name| try writer.print("{f}", .{name}),
        .DefunParamList => |info| {
            const num_of_sharp = std.math.powi(usize, 2, info.nested) catch {
                self.diagnostic.initDiagInner(.{ .ParseError = .{
                    .err_info = .{ .DefunParamOverflow = info.nested },
                    .span = info.span,
                } });
                return ParseError.ParseFailed;
            };
            for (0..num_of_sharp) |_| try writer.writeByte('#');
            try writer.print("{d}", .{info.arg_num});
        },
        .DefineFunction => |ctx| {
            const kind =
                @as(u4, @intCast(@intFromBool(ctx.kind.expand))) << 0 |
                @as(u4, @intCast(@intFromBool(ctx.kind.global))) << 1 |
                @as(u4, @intCast(@intFromBool(ctx.kind.long))) << 2 |
                @as(u4, @intCast(@intFromBool(ctx.kind.outer))) << 3;
            const defin = switch (kind) {
                0b0000 => "\\def",
                0b0001 => "\\edef",
                0b0010 => "\\gdef",
                0b0011 => "\\xdef",
                0b0100 => "\\long\\def",
                0b0101 => "\\long\\edef",
                0b0110 => "\\long\\gdef",
                0b0111 => "\\long\\xdef",
                0b1000 => "\\outer\\def",
                0b1001 => "\\outer\\edef",
                0b1010 => "\\outer\\gdef",
                0b1011 => "\\outer\\xdef",
                0b1100 => "\\outer\\long\\def",
                0b1101 => "\\outer\\long\\edef",
                0b1110 => "\\outer\\long\\gdef",
                0b1111 => "\\outer\\long\\xdef",
            };

            // prologue
            if (!ctx.kind.redef) {
                try writer.print(
                    \\\expandafter\ifx\csname {f}\endcsname\relax
                    \\{s}\{f}
                , .{ ctx.name, defin, ctx.name });
            } else {
                try writer.print("{s}\\{f}", .{ defin, ctx.name });
            }

            if (ctx.param_str) |str| {
                try writer.print("{f}{{", .{str});
            } else {
                try writer.writeByte('{');
            }

            // body
            var body = Io.Writer.Allocating.init(self.allocator);
            defer body.deinit();
            try self.codegenStmts(ctx.inner, lua, &body.writer);

            var body_content: []const u8 = body.written();
            if (ctx.kind.trim_left) {
                body_content = std.mem.trimLeft(u8, body_content, " \t\r\n");
            }
            if (ctx.kind.trim_right) {
                body_content = std.mem.trimRight(u8, body_content, " \t\r\n");
            }
            try writer.writeAll(body_content);

            //epilogue
            if (!ctx.kind.redef) {
                try writer.writeAll("}\n\\else\\fi ");
            } else {
                try writer.writeAll("}");
            }
        },
        .DefineEnv => |ctx| {
            // prologue
            try writer.writeAll(if (ctx.is_redefine)
                "\\renewenvironment"
            else
                "\\newenvironment");
            try writer.print("{{{f}}}", .{ctx.name});
            if (ctx.num_args > 0)
                try writer.print("[{d}]", .{ctx.num_args});
            if (ctx.default_arg) |arg| {
                try writer.writeByte('[');
                try self.codegenStmts(arg.ctx, lua, writer);
                try writer.writeByte(']');
            }
            try writer.writeByte('{');

            // body
            try self.codegenStmts(ctx.inner_begin, lua, writer);
            try writer.writeAll("}{");
            try self.codegenStmts(ctx.inner_end, lua, writer);

            //epilogue
            try writer.writeAll("}\n");
        },
        .LuaCode => |cb| {
            if (lua) |l| {
                var new_code = try ArrayList(u8).initCapacity(
                    self.allocator,
                    cb.code.items.len,
                );
                errdefer new_code.deinit(self.allocator);

                if (cb.code_import) |import_arr_list| {
                    for (import_arr_list.items) |import_label| {
                        if (self.luacode_exports.get(import_label)) |import_code| {
                            try new_code.appendSlice(self.allocator, import_code.items);
                            try new_code.append(self.allocator, '\n');
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
                    try new_code.appendSlice(self.allocator, cb.code.items);
                    try self.luacode_exports.put(self.allocator, export_label, new_code);
                    return;
                }
                try new_code.appendSlice(self.allocator, cb.code.items);
                try new_code.append(self.allocator, 0);

                l.evalCode(@ptrCast(new_code.items)) catch {
                    const lua_runtime_err = try diag.ParseDiagnostic.luaEvalFailed(
                        self.diagnostic.allocator,
                        cb.code_span,
                        "failed to run luacode",
                        .{},
                        "see above lua error message",
                    );
                    self.diagnostic.initDiagInner(.{ .ParseError = lua_runtime_err });
                    return error.LuaEvalFailed;
                };

                const ves_output = try l.getVestiOutputStr();
                defer self.allocator.free(ves_output);
                try writer.writeAll(@ptrCast(ves_output));

                new_code.deinit(self.allocator);
            }
        },
    }
}

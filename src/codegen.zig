const std = @import("std");

const ast = @import("./parser/ast.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub fn codegen(stmts: ArrayList(ast.Stmt), writer: anytype) anyerror!void {
    for (stmts.items) |stmt| {
        try codegenStmt(stmt, writer);
    }
}

fn codegenStmt(stmt: ast.Stmt, writer: anytype) anyerror!void {
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
            try codegen(math_ctx.ctx, writer);
            try writer.writeAll(delimiter[1]);
        },
        .Braced => |inner_stmts| {
            try writer.writeByte('{');
            try codegen(inner_stmts, writer);
            try writer.writeByte('}');
        },
        .Fraction => |fraction| {
            try writer.writeAll("\\frac{");
            try codegen(fraction.numerator, writer);
            try writer.writeAll("}{");
            try codegen(fraction.denominator, writer);
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
                try codegenStmt(ast.Stmt{ .ImportSinglePkg = usepkg }, writer);
        },
        .PlainTextInMath => |info| {
            try writer.writeAll("\\text{");
            if (info.add_front_space) try writer.writeByte(' ');
            try codegen(info.inner, writer);
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
                        try codegen(arg.ctx, writer);
                        try writer.writeByte('}');
                    },
                    .Optional => {
                        try writer.writeByte('[');
                        try codegen(arg.ctx, writer);
                        try writer.writeByte(']');
                    },
                    .StarArg => try writer.writeByte('*'),
                }
            }
            try codegen(info.inner, writer);
            try writer.print("\\end{{{cows}}}", .{info.name});
        },
        .BeginPhantomEnviron => |info| {
            try writer.print("\\begin{{{cows}}}", .{info.name});
            for (info.args.items) |arg| {
                switch (arg.needed) {
                    .MainArg => {
                        try writer.writeByte('{');
                        try codegen(arg.ctx, writer);
                        try writer.writeByte('}');
                    },
                    .Optional => {
                        try writer.writeByte('[');
                        try codegen(arg.ctx, writer);
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
        .Int, .Float => undefined, // TODO: deprecated
    }
}

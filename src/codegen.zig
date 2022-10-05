const std = @import("std");
const ast = @import("ast.zig");
const fmt = std.fmt;
const mem = std.mem;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

pub const CodegenError = error{
    MakeStmtToStrFailed,
    MakeLatexToStrFailed,
    MakeDocclassToStrFailed,
    MakeImportToStrFailed,
    MakeDocumentBlockFailed,
    MakeTextToStrFailed,
    MakeMathToStrFailed,
    MakePlainTextInMathToStrFailed,
    MakeIntegerToStrFailed,
    MakeFloatToStrFailed,
    MakeRawLatexToStrFailed,
    MakeLatexFunctionToStrFailed,
    MakeEnvironmentToStrFailed,
    MakePhantomEnvironmentToStrFailed,
    MakeFunctionDefToStrFailed,
    MakeEnvironmentDefToStrFailed,
};

pub fn latexToString(
    latex: *const ast.Latex,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    for (latex.stmts.items) |*stmt| {
        const stmt_string = try stmtToString(stmt, alloc);
        defer stmt_string.deinit();

        output.appendSlice(stmt_string.items) catch return error.MakeLatexToStrFailed;
    }

    return output;
}

pub fn stmtToString(
    stmt: *const ast.Statement,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    return switch (stmt.*) {
        .document_class => |*pkg| try docclassToString(pkg, alloc),
        .use_packages => |*pkgs| try importToString(pkgs, alloc),
        .document_start => blk: {
            var output = ArrayList(u8).init(alloc);
            errdefer output.deinit();

            output.appendSlice("\\begin{document}\n") catch return error.MakeDocumentBlockFailed;
            break :blk output;
        },
        .document_end => blk: {
            var output = ArrayList(u8).init(alloc);
            errdefer output.deinit();

            output.appendSlice("\n\\end{document}\n") catch return error.MakeDocumentBlockFailed;
            break :blk output;
        },
        .main_text => |text| try mainTextToString(text, alloc),
        .integer => |i| try integerToString(i, alloc),
        .float => |f| try floatToString(f, alloc),
        .raw_latex => |raw_latex| try rawLatexToString(raw_latex, alloc),
        .math_text => |*math_text| try mathTextToString(math_text, alloc),
        .plain_text_in_math => |*plain_text| try plainTextInMathToString(plain_text, alloc),
        .latex_function => |*fnt| try latexFunctionToString(fnt, alloc),
        .environment => |*env| try environmentToString(env, alloc),
        .phantom_begin_environment => |*env| try phantomBeginEnvironmentToString(env, alloc),
        .phantom_end_environment => |*env| blk: {
            var output = ArrayList(u8).init(alloc);
            errdefer output.deinit();

            output.writer().print(
                "\\end{{{s}}}\n",
                .{env.items},
            ) catch return error.MakePhantomEnvironmentToStrFailed;
            break :blk output;
        },
        .function_define => |*fnt_def| try functionDefToString(fnt_def, alloc),
        .environment_define => |*env_def| try environmentDefToString(env_def, alloc),
    };
}

fn docclassToString(
    package: *const ast.Package,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    var writer = output.writer();

    if (package.options) |opts| {
        var options_str = ArrayList(u8).init(alloc);
        defer options_str.deinit();

        for (opts.items) |*opt| {
            const latex_string = try latexToString(opt, alloc);
            defer latex_string.deinit();

            options_str.writer().print(
                "{s},",
                .{latex_string.items},
            ) catch return error.MakeDocclassToStrFailed;
        }
        _ = options_str.pop();

        writer.print(
            "\\documentclass[{s}]{{{s}}}\n",
            .{ options_str.items, package.name.items },
        ) catch return error.MakeDocclassToStrFailed;
    } else {
        writer.print(
            "\\documentclass{{{s}}}\n",
            .{package.name.items},
        ) catch return error.MakeDocclassToStrFailed;
    }

    return output;
}

fn importToString(
    packages: *const ArrayList(ast.Package),
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    var writer = output.writer();

    for (packages.items) |pkg| {
        if (pkg.options) |opts| {
            var options_str = ArrayList(u8).init(alloc);
            defer options_str.deinit();

            for (opts.items) |*opt| {
                const latex_string = try latexToString(opt, alloc);
                defer latex_string.deinit();

                options_str.writer().print(
                    "{s},",
                    .{latex_string.items},
                ) catch return error.MakeImportToStrFailed;
            }
            _ = options_str.pop();

            writer.print(
                "\\usepackage[{s}]{{{s}}}\n",
                .{ options_str.items, pkg.name.items },
            ) catch return error.MakeImportToStrFailed;
        } else {
            writer.print(
                "\\usepackage{{{s}}}\n",
                .{pkg.name.items},
            ) catch return error.MakeImportToStrFailed;
        }
    }

    return output;
}

fn mainTextToString(
    text: []const u8,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    output.appendSlice(text) catch return error.MakeTextToStrFailed;

    return output;
}

fn mathTextToString(
    math_text: *const ast.MathText,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    switch (math_text.state) {
        .text_math => {
            const inner_text = try latexToString(&math_text.text, alloc);
            defer inner_text.deinit();

            output.append('$') catch return error.MakeMathToStrFailed;
            output.appendSlice(inner_text.items) catch return error.MakeMathToStrFailed;
            output.append('$') catch return error.MakeMathToStrFailed;
        },
        .display_math => {
            const inner_text = try latexToString(&math_text.text, alloc);
            defer inner_text.deinit();

            output.appendSlice("\\[") catch return error.MakeMathToStrFailed;
            output.appendSlice(inner_text.items) catch return error.MakeMathToStrFailed;
            output.appendSlice("\\]") catch return error.MakeMathToStrFailed;
        },
    }

    return output;
}

fn plainTextInMathToString(
    plain_text: *const ast.PlainTextInMath,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();
    var writer = output.writer();

    var latex = try latexToString(&plain_text.text, alloc);
    defer latex.deinit();

    const last_char = latex.popOrNull();
    if (last_char != null and last_char.? != ' ') {
        latex.append(last_char.?) catch return error.MakePlainTextInMathToStrFailed;
    }

    _ = switch ((@as(
        u2,
        @boolToInt(plain_text.trim.start),
    ) << 1) | @as(
        u2,
        @boolToInt(plain_text.trim.end),
    )) {
        0 => writer.print("\\text{{{s}}}", .{latex.items}),
        1 => writer.print("\\text{{{s} }}", .{latex.items}),
        2 => writer.print("\\text{{ {s}}}", .{latex.items}),
        3 => writer.print("\\text{{ {s} }}", .{latex.items}),
    } catch return error.MakePlainTextInMathToStrFailed;

    return output;
}

fn integerToString(int: i64, alloc: Allocator) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    output.writer().print("{d}", .{int}) catch return error.MakeIntegerToStrFailed;

    return output;
}

fn floatToString(float: f64, alloc: Allocator) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    output.writer().print("{d}", .{float}) catch return error.MakeFloatToStrFailed;

    return output;
}

fn rawLatexToString(
    raw_latex: []const u8,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    output.appendSlice(raw_latex) catch return error.MakeRawLatexToStrFailed;

    return output;
}

fn latexFunctionToString(
    function: *const ast.LatexFnt,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    var writer = output.writer();

    output.appendSlice(function.name) catch return error.MakeLatexFunctionToStrFailed;
    if (function.has_space) {
        output.append(' ') catch return error.MakeLatexFunctionToStrFailed;
    }
    for (function.args.items) |*arg| {
        var arg_string = ArrayList(u8).init(alloc);
        defer arg_string.deinit();

        const inner_string = try latexToString(&arg.inner, alloc);
        defer inner_string.deinit();
        arg_string.appendSlice(inner_string.items) catch return error.MakeLatexFunctionToStrFailed;

        _ = switch (arg.arg_type) {
            .main_arg => writer.print("{{{s}}}", .{arg_string.items}),
            .optional => writer.print("[{s}]", .{arg_string.items}),
            .star_arg => output.append('*'),
        } catch return error.MakeLatexFunctionToStrFailed;
    }

    return output;
}

fn environmentToString(
    env: *const ast.Environment,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    var writer = output.writer();

    writer.print(
        "\\begin{{{s}}}",
        .{env.name.items},
    ) catch return error.MakeEnvironmentToStrFailed;

    for (env.args.items) |*arg| {
        var arg_string = ArrayList(u8).init(alloc);
        defer arg_string.deinit();

        const inner_string = try latexToString(&arg.inner, alloc);
        defer inner_string.deinit();
        arg_string.appendSlice(inner_string.items) catch return error.MakeEnvironmentToStrFailed;

        _ = switch (arg.arg_type) {
            .main_arg => writer.print("{{{s}}}", .{arg_string.items}),
            .optional => writer.print("[{s}]", .{arg_string.items}),
            .star_arg => output.append('*'),
        } catch return error.MakeEnvironmentToStrFailed;
    }

    const body_string = try latexToString(&env.text, alloc);
    defer body_string.deinit();
    output.appendSlice(body_string.items) catch return error.MakeEnvironmentToStrFailed;

    writer.print(
        "\\end{{{s}}}\n",
        .{env.name.items},
    ) catch return error.MakeEnvironmentToStrFailed;

    return output;
}

fn phantomBeginEnvironmentToString(
    env: *const ast.PhantomBeginEnv,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    var writer = output.writer();

    writer.print(
        "\\begin{{{s}}}",
        .{env.name.items},
    ) catch return error.MakePhantomEnvironmentToStrFailed;

    for (env.args.items) |*arg| {
        var arg_string = ArrayList(u8).init(alloc);
        defer arg_string.deinit();

        const inner_string = try latexToString(&arg.inner, alloc);
        defer inner_string.deinit();
        arg_string.appendSlice(inner_string.items) catch return error.MakePhantomEnvironmentToStrFailed;

        _ = switch (arg.arg_type) {
            .main_arg => writer.print("{{{s}}}", .{arg_string.items}),
            .optional => writer.print("[{s}]", .{arg_string.items}),
            .star_arg => output.append('*'),
        } catch return error.MakePhantomEnvironmentToStrFailed;
    }
    output.append('\n') catch return error.MakePhantomEnvironmentToStrFailed;

    return output;
}

fn functionDefToString(
    fnt_def: *const ast.FunctionDefine,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    var writer = output.writer();

    _ = switch (fnt_def.style) {
        .plain => writer.print("\\def\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .long_plain => writer.print("\\long\\def\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .outer_plain => writer.print("\\outer\\def\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .long_outer_plain => writer.print("\\long\\outer\\def\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .expand => writer.print("\\edef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .long_expand => writer.print("\\long\\edef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .outer_expand => writer.print("\\outer\\edef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .long_outer_expand => writer.print("\\long\\outer\\edef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .global => writer.print("\\gdef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .long_global => writer.print("\\long\\gdef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .outer_global => writer.print("\\outer\\gdef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .long_outer_global => writer.print("\\long\\outer\\gdef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .expand_global => writer.print("\\xdef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .long_expand_global => writer.print("\\long\\xdef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .outer_expand_global => writer.print("\\outer\\xdef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
        .long_outer_expand_global => writer.print("\\long\\outer\\xdef\\{s}{s}{{", .{
            fnt_def.name.items,
            fnt_def.args.items,
        }),
    } catch return error.MakeFunctionDefToStrFailed;

    var tmp = try latexToString(&fnt_def.body, alloc);
    defer tmp.deinit();

    output.appendSlice(switch ((@as(
        u2,
        @boolToInt(fnt_def.trim.start),
    ) << 1) | @as(
        u2,
        @boolToInt(fnt_def.trim.end),
    )) {
        0 => tmp.items,
        1 => mem.trimRight(u8, tmp.items, " \t\n"),
        2 => mem.trimLeft(u8, tmp.items, " \t\n"),
        3 => mem.trim(u8, tmp.items, " \t\n"),
    }) catch return error.MakeFunctionDefToStrFailed;

    output.appendSlice("}\n") catch return error.MakeFunctionDefToStrFailed;

    return output;
}

fn environmentDefToString(
    env_def: *const ast.EnvironmentDefine,
    alloc: Allocator,
) CodegenError!ArrayList(u8) {
    var output = ArrayList(u8).init(alloc);
    errdefer output.deinit();

    var writer = output.writer();

    _ = blk: {
        if (env_def.is_redefine) {
            break :blk writer.print("\\renewenvironment{{{s}}}", .{env_def.name.items});
        } else {
            break :blk writer.print("\\newenvironment{{{s}}}", .{env_def.name.items});
        }
    } catch return error.MakeEnvironmentDefToStrFailed;

    if (env_def.args_num > 0) {
        writer.print("[{d}]", .{env_def.args_num}) catch return error.MakeEnvironmentDefToStrFailed;
        if (env_def.optional_arg) |*optional_arg| {
            output.append('[') catch return error.MakeEnvironmentDefToStrFailed;

            var tmp = try latexToString(optional_arg, alloc);
            defer tmp.deinit();
            output.appendSlice(tmp.items) catch return error.MakeEnvironmentDefToStrFailed;

            output.appendSlice("]{") catch return error.MakeEnvironmentDefToStrFailed;
        } else {
            output.append('{') catch return error.MakeEnvironmentDefToStrFailed;
        }
    } else {
        output.append('{') catch return error.MakeEnvironmentDefToStrFailed;
    }

    var beg_tmp = try latexToString(&env_def.begin_part, alloc);
    defer beg_tmp.deinit();

    output.appendSlice(switch ((@as(
        u2,
        @boolToInt(env_def.trim.start),
    ) << 1) | @as(
        u2,
        @boolToInt(env_def.trim.mid.?),
    )) {
        0 => beg_tmp.items,
        1 => mem.trimRight(u8, beg_tmp.items, " \t\n"),
        2 => mem.trimLeft(u8, beg_tmp.items, " \t\n"),
        3 => mem.trim(u8, beg_tmp.items, " \t\n"),
    }) catch return error.MakeEnvironmentDefToStrFailed;

    output.appendSlice("}{") catch return error.MakeEnvironmentDefToStrFailed;

    var end_tmp = try latexToString(&env_def.end_part, alloc);
    defer end_tmp.deinit();

    output.appendSlice(switch ((@as(
        u2,
        @boolToInt(env_def.trim.mid.?),
    ) << 1) | @as(
        u2,
        @boolToInt(env_def.trim.end),
    )) {
        0 => end_tmp.items,
        1 => mem.trimRight(u8, end_tmp.items, " \t\n"),
        2 => mem.trimLeft(u8, end_tmp.items, " \t\n"),
        3 => mem.trim(u8, end_tmp.items, " \t\n"),
    }) catch return error.MakeEnvironmentDefToStrFailed;

    output.appendSlice("}\n") catch return error.MakeEnvironmentDefToStrFailed;

    return output;
}

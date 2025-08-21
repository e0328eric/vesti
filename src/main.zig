const std = @import("std");
const time = std.time;
const compile = @import("./compile.zig");
const pyscript = @import("./pyscript.zig");
const c = @import("c");

const assert = std.debug.assert;

const ArrayList = std.ArrayList;
const Diagnostic = @import("./diagnostic.zig").Diagnostic;
const Parser = @import("./parser/Parser.zig");
const LatexEngine = Parser.LatexEngine;
const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;

fn signalHandler(signal: c_int) callconv(.c) noreturn {
    _ = signal;
    std.debug.print("bye!\n", .{});
    std.process.exit(0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // set signal handling
    _ = c.signal(c.SIGINT, signalHandler);

    var zlap = try @import("zlap").Zlap(@embedFile("./commands.zlap")).init(allocator);
    defer zlap.deinit();

    if (zlap.isSubcmdActive("clear")) {
        try std.fs.cwd().deleteTree(VESTI_DUMMY_DIR);
        std.debug.print("[successively remove {s}]", .{VESTI_DUMMY_DIR});
        return;
    } else if (zlap.is_help or
        (!zlap.isSubcmdActive("compile") and !zlap.isSubcmdActive("run")))
    {
        std.debug.print("{s}\n", .{zlap.help_msg});
        return;
    }

    const compile_subcmd = zlap.subcommands.get("compile").?;
    const main_filenames = compile_subcmd.args.get("FILENAMES").?;
    const compile_lim: usize = blk: {
        const tmp = compile_subcmd.flags.get("lim").?.value.number;
        if (tmp <= 0) return error.InvalidCompileLimit;
        break :blk @intCast(tmp);
    };

    const compile_all = compile_subcmd.flags.get("all").?.value.bool;
    const watch = compile_subcmd.flags.get("watch").?.value.bool;
    const no_color = compile_subcmd.flags.get("no_color").?.value.bool;
    const no_exit_err = compile_subcmd.flags.get("no_exit_err").?.value.bool;

    const is_latex = compile_subcmd.flags.get("latex").?.value.bool;
    const is_pdflatex = compile_subcmd.flags.get("pdflatex").?.value.bool;
    const is_xelatex = compile_subcmd.flags.get("xelatex").?.value.bool;
    const is_lualatex = compile_subcmd.flags.get("lualatex").?.value.bool;
    const is_tectonic = compile_subcmd.flags.get("tectonic").?.value.bool;

    const before_script = compile_subcmd.flags.get("before_script").?.value.string;
    const after_script = compile_subcmd.flags.get("after_script").?.value.string;
    const step_script = compile_subcmd.flags.get("step_script").?.value.string;
    const run_script = compile_subcmd.flags.get("run_script").?.value.string;

    const engine = try getEngine(.{
        .is_latex = is_latex,
        .is_pdflatex = is_pdflatex,
        .is_xelatex = is_xelatex,
        .is_lualatex = is_lualatex,
        .is_tectonic = is_tectonic,
    });

    var diagnostic = Diagnostic{
        .allocator = allocator,
    };
    defer diagnostic.deinit();

    // TODO: because of the `compty` keyword, engines between `compile` and
    // `run` may different (since we can know the engine type inside of
    // build.py). How can I resolve such issue?
    if (zlap.isSubcmdActive("run")) {
        const py_contents = (try pyscript.getBuildPyContents(
            allocator,
            run_script,
            &diagnostic,
        )) orelse return error.BuildFileNotFound; // TODO: make a diagnostic
        defer allocator.free(py_contents);

        pyscript.runPyCode(allocator, &diagnostic, engine, py_contents) catch |err| {
            try diagnostic.prettyPrint(no_color);
            return err;
        };
    }

    var prev_mtime: ?i128 = null;
    try compile.compile(
        allocator,
        main_filenames.value.strings.items,
        &diagnostic,
        engine,
        compile_lim,
        &prev_mtime,
        .{
            .before = before_script,
            .after = after_script,
            .step = step_script,
        },
        .{
            .compile_all = compile_all,
            .watch = watch,
            .no_color = no_color,
            .no_exit_err = no_exit_err,
        },
    );
}

const EngineTypeInput = packed struct {
    is_latex: bool,
    is_pdflatex: bool,
    is_xelatex: bool,
    is_lualatex: bool,
    is_tectonic: bool,
};

fn getEngine(ty: EngineTypeInput) !LatexEngine {
    const is_latex_num = @as(u8, @intCast(@intFromBool(ty.is_latex))) << 0;
    const is_pdflatex_num = @as(u8, @intCast(@intFromBool(ty.is_pdflatex))) << 1;
    const is_xelatex_num = @as(u8, @intCast(@intFromBool(ty.is_xelatex))) << 2;
    const is_lualatex_num = @as(u8, @intCast(@intFromBool(ty.is_lualatex))) << 3;
    const is_tectonic_num = @as(u8, @intCast(@intFromBool(ty.is_tectonic))) << 4;
    const engine_num = is_latex_num |
        is_pdflatex_num |
        is_xelatex_num |
        is_lualatex_num |
        is_tectonic_num;

    switch (engine_num) {
        // TODO: read config file and replace with it
        0 => return .pdflatex,
        1 << 0 => return .latex,
        1 << 1 => return .pdflatex,
        1 << 2 => return .xelatex,
        1 << 3 => return .lualatex,
        1 << 4 => return .tectonic,
        else => return error.InvalidEngineFlag,
    }
}

test "vesti tests" {
    _ = @import("./parser/Parser.zig");
}

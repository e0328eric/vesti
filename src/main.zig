const USE_JULIA = @import("vesti-info").USE_JULIA;

const std = @import("std");
const c = @import("c");
const compile = @import("compile.zig");
const diag = @import("diagnostic.zig");
const jlscript = if (USE_JULIA) @import("jlscript.zig") else {};
const zlap = @import("zlap");
const time = std.time;

const assert = std.debug.assert;
const getConfigPath = Config.getConfigPath;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const Diagnostic = diag.Diagnostic;
const Julia = if (USE_JULIA) @import("julia/Julia.zig") else {};
const Parser = @import("parser/Parser.zig");
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

    var zlap_cmd = try zlap.Zlap(@embedFile("commands.zlap"), null).init(allocator);
    defer zlap_cmd.deinit();

    if (zlap_cmd.isSubcmdActive("clear")) {
        try std.fs.cwd().deleteTree(VESTI_DUMMY_DIR);
        std.debug.print("[successively remove {s}]", .{VESTI_DUMMY_DIR});
        return;
    } else if (zlap_cmd.isSubcmdActive("tex2ves")) {
        const tex2ves_subcmd = zlap_cmd.subcommands.get("tex2ves").?;
        const tex_files = tex2ves_subcmd.args.get("FILENAMES").?;
        // TODO: implement tex2ves
        _ = tex_files;

        std.debug.print("currently, this subcommand does nothing.\n", .{});
        return;
    } else if (zlap_cmd.is_help) {
        std.debug.print("{s}\n", .{zlap_cmd.help_msg});
        return;
    } else if (zlap_cmd.isSubcmdActive("compile")) {
        const compile_subcmd = zlap_cmd.subcommands.get("compile").?;
        try compileStep(allocator, &compile_subcmd);
    } else if (zlap_cmd.isSubcmdActive("run")) {
        const run_subcmd = zlap_cmd.subcommands.get("run").?;
        try runStep(allocator, &run_subcmd);
    } else {
        std.debug.print("{s}\n", .{zlap_cmd.help_msg});
        return error.InvalidSubcommand;
    }
}

fn runStep(allocator: Allocator, run_subcmd: *const zlap.Subcmd) !void {
    if (!USE_JULIA) return;

    const is_latex = run_subcmd.flags.get("latex").?.value.bool;
    const is_pdflatex = run_subcmd.flags.get("pdflatex").?.value.bool;
    const is_xelatex = run_subcmd.flags.get("xelatex").?.value.bool;
    const is_lualatex = run_subcmd.flags.get("lualatex").?.value.bool;
    const is_tectonic = run_subcmd.flags.get("tectonic").?.value.bool;

    const first_script = run_subcmd.flags.get("first_script").?.value.string;

    var diagnostic = Diagnostic{ .allocator = allocator };
    defer diagnostic.deinit();

    const engine = try getEngine(allocator, &diagnostic, .{
        .is_latex = is_latex,
        .is_pdflatex = is_pdflatex,
        .is_xelatex = is_xelatex,
        .is_lualatex = is_lualatex,
        .is_tectonic = is_tectonic,
    });

    // initializing Julia globally
    var julia = try Julia.init(engine);
    defer julia.deinit();

    const first_jl = try jlscript.getBuildJlContents(
        allocator,
        first_script,
        &diagnostic,
    ) orelse return error.FirstJlNotFound;
    defer allocator.free(first_jl);

    try jlscript.runJlCode(&julia, &diagnostic, first_jl, first_script);
}

fn compileStep(allocator: Allocator, compile_subcmd: *const zlap.Subcmd) !void {
    const main_filenames = compile_subcmd.args.get("FILENAMES").?;
    const compile_lim: usize = blk: {
        const tmp = compile_subcmd.flags.get("lim").?.value.number;
        if (tmp <= 0) return error.InvalidCompileLimit;
        break :blk @intCast(tmp);
    };

    const compile_single = compile_subcmd.flags.get("single").?.value.bool;
    const watch = compile_subcmd.flags.get("watch").?.value.bool;
    const no_color = compile_subcmd.flags.get("no_color").?.value.bool;
    const no_exit_err = compile_subcmd.flags.get("no_exit_err").?.value.bool;

    const is_latex = compile_subcmd.flags.get("latex").?.value.bool;
    const is_pdflatex = compile_subcmd.flags.get("pdflatex").?.value.bool;
    const is_xelatex = compile_subcmd.flags.get("xelatex").?.value.bool;
    const is_lualatex = compile_subcmd.flags.get("lualatex").?.value.bool;
    const is_tectonic = compile_subcmd.flags.get("tectonic").?.value.bool;

    const before_script = compile_subcmd.flags.get("before_script").?.value.string;
    const step_script = compile_subcmd.flags.get("step_script").?.value.string;

    var diagnostic = Diagnostic{ .allocator = allocator };
    defer diagnostic.deinit();

    var engine = try getEngine(allocator, &diagnostic, .{
        .is_latex = is_latex,
        .is_pdflatex = is_pdflatex,
        .is_xelatex = is_xelatex,
        .is_lualatex = is_lualatex,
        .is_tectonic = is_tectonic,
    });

    // initializing Julia globally
    var julia = if (USE_JULIA) try Julia.init(engine) else {};
    defer if (USE_JULIA) julia.deinit();

    var prev_mtime: ?i128 = null;
    try compile.compile(
        allocator,
        main_filenames.value.strings.items,
        &julia,
        &diagnostic,
        &engine,
        compile_lim,
        &prev_mtime,
        .{
            .before = before_script,
            .step = step_script,
        },
        .{
            .compile_all = !compile_single,
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

fn getEngine(
    allocator: Allocator,
    diagnostic: *Diagnostic,
    ty: EngineTypeInput,
) !LatexEngine {
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

    const default_engine = blk: {
        const config = Config.init(allocator, diagnostic) catch
            break :blk .tectonic; // default engine is tectonic
        defer config.deinit(allocator);
        break :blk config.engine;
    };

    switch (engine_num) {
        0 => return default_engine,
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

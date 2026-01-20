const builtin = @import("builtin");
const std = @import("std");
const c = @import("vesti_c.zig");
const diag = @import("diagnostic.zig");
const luascript = @import("luascript.zig");
const zlap = @import("zlap");
const time = std.time;
const path = std.fs.path;

const assert = std.debug.assert;
const getConfigPath = Config.getConfigPath;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const CompileAttribute = Compiler.CompileAttribute;
const Compiler = @import("Compiler.zig");
const Config = @import("Config.zig");
const Diagnostic = diag.Diagnostic;
const EnvMap = std.process.Environ.Map;
const Io = std.Io;
const LatexEngine = Parser.LatexEngine;
const Lua = @import("Lua.zig");
const LuaContents = Compiler.LuaContents;
const LuaScripts = Compiler.LuaScripts;
const Parser = @import("parser/Parser.zig");
const Zlap = zlap.Zlap(@embedFile("commands.zlap"), null);
const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;

fn signalHandler(signal: c_int) callconv(.c) noreturn {
    _ = signal;
    std.debug.print("bye!\n", .{});
    std.process.exit(0);
}

pub fn main(init: std.process.Init) !void {
    // change the console encoding into utf-8
    // One can find the magic number in here
    // https://learn.microsoft.com/en-us/windows/win32/intl/code-page-identifiers
    if (builtin.os.tag == .windows) {
        if (std.os.windows.kernel32.SetConsoleOutputCP(65001) == 0) {
            std.debug.print("ERROR: cannot set the codepoint into utf-8\n", .{});
            return error.FailedToSetUTF8Codepoint;
        }
    }

    const allocator = init.gpa;
    const io = init.io;

    // set signal handling
    _ = c.signal(c.SIGINT, signalHandler);

    var zlap_cmd: Zlap = try .init(allocator, init.minimal.args);
    defer zlap_cmd.deinit();
    if (zlap_cmd.is_help) {
        std.debug.print("{s}\n", .{zlap_cmd.help_msg});
        return;
    }

    var diagnostic = Diagnostic{ .allocator = allocator, .io = io };
    defer diagnostic.deinit();

    const subcmds = .{
        "init",
        "clear",
        "compile",
        "experimental",
    };
    inline for (subcmds) |subcmd_str| {
        if (zlap_cmd.isSubcmdActive(subcmd_str)) {
            const subcmd = zlap_cmd.subcommands.get(subcmd_str).?;
            @field(@This(), subcmd_str ++ "Step")(
                allocator,
                io,
                init.environ_map,
                &diagnostic,
                &subcmd,
            ) catch |err| {
                if (!diagnostic.lock_print_at_main)
                    try diagnostic.prettyPrint(true);
                return err;
            };
            return;
        }
    } else {
        std.debug.print("{s}\n", .{zlap_cmd.help_msg});
        return error.InvalidSubcommand;
    }
}

//          ╭─────────────────────────────────────────────────────────╮
//          │                  Subcommand Functions                   │
//          ╰─────────────────────────────────────────────────────────╯

const experimentalStep = @import("experimental.zig").experimentalStep;

fn initStep(
    allocator: Allocator,
    io: Io,
    env_map: *const EnvMap,
    diagnostic: *Diagnostic,
    init_subcmd: *const zlap.Subcmd,
) !void {
    _ = env_map;
    _ = diagnostic;

    const project_name = init_subcmd.args.get("PROJECT").?.value.string;
    var project_filename: Io.Writer.Allocating = .init(allocator);
    defer project_filename.deinit();

    try project_filename.writer.print("{s}.ves", .{project_name});
    try project_filename.writer.flush();

    var first_lua = try Io.Dir.createFile(.cwd(), io, "first.lua", .{});
    defer first_lua.close(io);
    var project_ves = try Io.Dir.createFile(.cwd(), io, project_filename.written(), .{});
    defer project_ves.close(io);

    var buf: [1024]u8 = undefined;
    var first_lua_writer = first_lua.writer(io, &buf);

    try first_lua_writer.interface.print(
        \\-- below code imports vesti module
        \\-- vesti.getModule("module_name")
        \\vesti.compile("{s}.ves", {{ engine = "tect", compile_all = true }})
    , .{project_name});
    try first_lua_writer.end();

    var project_ves_writer = project_ves.writer(io, &buf);
    try project_ves_writer.interface.print(
        \\docclass article
        \\startdoc
        \\Hello, World!
    , .{});
    try project_ves_writer.end();
}

fn clearStep(
    allocator: Allocator,
    io: Io,
    env_map: *const EnvMap,
    diagnostic: *Diagnostic,
    clear_subcmd: *const zlap.Subcmd,
) !void {
    _ = allocator;
    _ = env_map;
    _ = diagnostic;
    _ = clear_subcmd;

    try Io.Dir.cwd().deleteTree(io, VESTI_DUMMY_DIR);
    std.debug.print("[successively remove {s}]\n", .{VESTI_DUMMY_DIR});
}

fn compileStep(
    allocator: Allocator,
    io: Io,
    env_map: *const EnvMap,
    diagnostic: *Diagnostic,
    compile_subcmd: *const zlap.Subcmd,
) !void {
    const main_filename = compile_subcmd.args.get("FILENAME").?;
    const compile_lim: usize = blk: {
        const tmp = compile_subcmd.flags.get("lim").?.value.number;
        if (tmp <= 0) return error.InvalidCompileLimit;
        break :blk @intCast(tmp);
    };

    const watch = compile_subcmd.flags.get("watch").?.value.bool;
    const no_color = compile_subcmd.flags.get("no_color").?.value.bool;
    const exit_err = compile_subcmd.flags.get("exit_err").?.value.bool;
    const standalone = compile_subcmd.flags.get("standalone").?.value.bool;

    const is_latex = compile_subcmd.flags.get("latex").?.value.bool;
    const is_pdflatex = compile_subcmd.flags.get("pdflatex").?.value.bool;
    const is_xelatex = compile_subcmd.flags.get("xelatex").?.value.bool;
    const is_lualatex = compile_subcmd.flags.get("lualatex").?.value.bool;
    const is_tectonic = compile_subcmd.flags.get("tectonic").?.value.bool;

    const first_script = compile_subcmd.flags.get("first_script").?.value.string;
    const before_script = compile_subcmd.flags.get("before_script").?.value.string;
    const step_script = compile_subcmd.flags.get("step_script").?.value.string;

    const config = try Config.init(allocator, io, env_map, diagnostic);
    defer config.deinit(allocator);

    var engine = try getEngine(config.engine, .{
        .is_latex = is_latex,
        .is_pdflatex = is_pdflatex,
        .is_xelatex = is_xelatex,
        .is_lualatex = is_lualatex,
        .is_tectonic = is_tectonic,
    });

    // initializing Lua globally
    var lua = try Lua.init(
        allocator,
        io,
        env_map,
        engine,
        &config,
        .{
            .compile_all = true,
            .watch = watch,
            .no_color = no_color,
            .no_exit_err = !exit_err,
        },
    );
    defer lua.deinit();

    // -S flag ignores to find and run first.lua, and make compile_all = false
    if (!standalone) {
        // search first.lua in case of not specifying main_filename
        if (main_filename.value.string.len == 0) blk: {
            const cwd = std.process.getCwdAlloc(allocator) catch {
                std.debug.print("error: cannot get the current directory\n", .{});
                return error.FailedGetCwd;
            };
            defer allocator.free(cwd);

            var iter = path.componentIterator(cwd);
            const last = iter.last() orelse {
                std.debug.print(
                    "error: cwd {s} is empty. But this might be an undefined behavior\n",
                    .{cwd},
                );
                return error.CwdIsEmpty;
            };

            // change current directory where first.lua is located
            if (try changeCwdAtFirstLua(allocator, io, &last)) break :blk;
            while (iter.previous()) |prev| {
                if (try changeCwdAtFirstLua(allocator, io, &prev)) break :blk;
            }

            // in this point, first.lua is not found, so raise an error
            std.debug.print("error: `first.lua` is not found.\n", .{});
            return error.FailedToFindFirstLua;
        }

        const first_lua = try luascript.getBuildLuaContents(
            allocator,
            io,
            first_script,
            diagnostic,
        ) orelse return error.FirstLuaNotFound;
        defer allocator.free(first_lua);

        // we are going to run `first.lua`
        lua.is_first_lua = true;
        try luascript.runLuaCode(lua, diagnostic, first_lua, first_script);
        lua.is_first_lua = false;

        // first.lua may change engine
        engine = lua.engine;
    } else {
        lua.compile_attr.compile_all = false;
    }

    const main_ves = if (main_filename.value.string.len != 0)
        main_filename.value.string
    else
        @as([]const u8, @ptrCast(lua.main_ves orelse {
            std.debug.print("error: vesti.compile is missing in first.lua\n", .{});
            return error.NoMainVestiFilename;
        }));

    var prev_mtime: ?i96 = null;

    const luacode_scripts = LuaScripts{
        .before = before_script,
        .step = step_script,
    };
    const luacode_contents = try LuaContents.init(
        allocator,
        io,
        diagnostic,
        &luacode_scripts,
    );
    errdefer luacode_contents.deinit(allocator);
    var compiler = Compiler{
        .allocator = allocator,
        .io = io,
        .env_map = env_map,
        .main_filename = main_ves,
        .lua = lua,
        .diagnostic = diagnostic,
        .engine = &engine,
        .compile_limit = compile_lim,
        .prev_mtime = &prev_mtime,
        .luacode_scripts = luacode_scripts,
        .luacode_contents = luacode_contents,
        .global_defkinds = .empty,
        .attr = lua.compile_attr,
    };
    defer compiler.deinit();
    try compiler.compile();
}

fn changeCwdAtFirstLua(
    allocator: Allocator,
    io: Io,
    component: *const path.NativeComponentIterator.Component,
) !bool {
    const first_lua_path = try path.join(allocator, &.{ component.path, "first.lua" });
    defer allocator.free(first_lua_path);

    // open file to check whether it exists
    var f = Io.Dir.openFileAbsolute(io, first_lua_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    // f is not needed anymore
    f.close(io);
    var dir = try Io.Dir.openDirAbsolute(io, component.path, .{});
    defer dir.close(io);
    try std.process.setCurrentDir(io, dir);
    return true;
}

//          ╭─────────────────────────────────────────────────────────╮
//          │                     Get Engine Type                     │
//          ╰─────────────────────────────────────────────────────────╯

const EngineTypeInput = packed struct {
    is_latex: bool,
    is_pdflatex: bool,
    is_xelatex: bool,
    is_lualatex: bool,
    is_tectonic: bool,
};

fn getEngine(
    default_engine: LatexEngine,
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

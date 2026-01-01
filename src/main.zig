const std = @import("std");
const c = @import("vesti_c.zig");
const diag = @import("diagnostic.zig");
const luascript = @import("luascript.zig");
const zlap = @import("zlap");
const time = std.time;
const path = std.fs.path;

const assert = std.debug.assert;
const getConfigPath = Config.getConfigPath;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const Compiler = @import("Compiler.zig");
const CompileAttribute = Compiler.CompileAttribute;
const Diagnostic = diag.Diagnostic;
const Io = std.Io;
const Lua = @import("Lua.zig");
const LuaScripts = Compiler.LuaScripts;
const LuaContents = Compiler.LuaContents;
const Parser = @import("parser/Parser.zig");
const LatexEngine = Parser.LatexEngine;
const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;

fn signalHandler(signal: c_int) callconv(.c) noreturn {
    _ = signal;
    std.debug.print("bye!\n", .{});
    std.process.exit(0);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // set signal handling
    _ = c.signal(c.SIGINT, signalHandler);

    var zlap_cmd = try zlap.Zlap(@embedFile("commands.zlap"), null).init(allocator);
    defer zlap_cmd.deinit();
    if (zlap_cmd.is_help) {
        std.debug.print("{s}\n", .{zlap_cmd.help_msg});
        return;
    }

    var diagnostic = Diagnostic{ .allocator = allocator, .io = io };
    defer diagnostic.deinit();

    const subcmds = .{
        "clear",
        "tex2ves",
        "compile",
    };
    inline for (subcmds) |subcmd_str| {
        if (zlap_cmd.isSubcmdActive(subcmd_str)) {
            const subcmd = zlap_cmd.subcommands.get(subcmd_str).?;
            @field(@This(), subcmd_str ++ "Step")(
                allocator,
                io,
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

fn clearStep(
    allocator: Allocator,
    io: Io,
    diagnostic: *Diagnostic,
    clear_step: *const zlap.Subcmd,
) !void {
    _ = allocator;
    _ = diagnostic;
    _ = clear_step;

    try Io.Dir.cwd().deleteTree(io, VESTI_DUMMY_DIR);
    std.debug.print("[successively remove {s}]\n", .{VESTI_DUMMY_DIR});
}

fn tex2vesStep(
    allocator: Allocator,
    io: Io,
    diagnostic: *Diagnostic,
    tex2ves_subcmd: *const zlap.Subcmd,
) !void {
    _ = allocator;
    _ = io;
    _ = diagnostic;

    const tex_files = tex2ves_subcmd.args.get("FILENAMES").?;
    // TODO: implement tex2ves
    _ = tex_files;

    std.debug.print("currently, this subcommand does nothing.\n", .{});
}

fn compileStep(
    allocator: Allocator,
    io: Io,
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

    const config = try Config.init(allocator, io, diagnostic);
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

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const fs = std.fs;
const path = fs.path;
const time = std.time;
const diag = @import("diagnostic.zig");
const luascript = @import("luascript.zig");
const win = if (builtin.os.tag == .windows) @import("vesti_c.zig") else {};

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const Codegen = @import("Codegen.zig");
const DynLib = std.DynLib;
const Io = std.Io;
const Lua = @import("Lua.zig");
const LatexEngine = Parser.LatexEngine;
const Parser = @import("parser/Parser.zig");
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;
const Sha3 = std.crypto.hash.sha3.Sha3_512;

const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;
const VESTI_VERSION = @import("vesti-info").VESTI_VERSION;
const TECTONIC_DLL = @import("vesti-info").TECTONIC_DLL;
const TECTONIC_DLL_HASH = @import("vesti-info").TECTONIC_DLL_HASH;

pub const CompileAttribute = packed struct {
    compile_all: bool,
    watch: bool,
    no_color: bool,
    no_exit_err: bool,
};

pub const LuaScripts = struct {
    before: []const u8,
    step: []const u8,
};

pub const LuaContents = struct {
    before: ?[:0]const u8 = null,
    step: ?[:0]const u8 = null,

    fn init(
        scripts: *const LuaScripts,
        allocator: Allocator,
        diagnostic: *diag.Diagnostic,
    ) !@This() {
        var output: @This() = .{};

        inline for (&.{ "before", "step" }) |ty| {
            @field(output, ty) = try luascript.getBuildLuaContents(
                allocator,
                @field(scripts, ty),
                diagnostic,
            );
            errdefer if (@field(output, ty)) |lf| allocator.free(lf);
        }

        return output;
    }

    fn deinit(self: *const @This(), allocator: Allocator) void {
        inline for (&.{ "before", "step" }) |ty| {
            if (@field(self, ty)) |lf| allocator.free(lf);
        }
    }
};

pub fn compile(
    allocator: Allocator,
    main_filenames: []const []const u8,
    lua: *Lua,
    diagnostic: *diag.Diagnostic,
    engine: *LatexEngine,
    compile_limit: usize,
    prev_mtime: *?i128,
    luacode_scripts: LuaScripts,
    attr: CompileAttribute,
) !void {
    const luacode_contents = try LuaContents.init(
        &luacode_scripts,
        allocator,
        diagnostic,
    );
    defer luacode_contents.deinit(allocator);

    // run before.lua to "initialize" vesti projects
    if (luacode_contents.before) |lc| {
        try luascript.runLuaCode(lua, diagnostic, lc, luacode_scripts.before);
    }

    while (true) {
        compileInner(
            allocator,
            main_filenames,
            lua,
            diagnostic,
            engine,
            compile_limit,
            prev_mtime,
            luacode_contents.step,
            luacode_scripts.step,
            attr,
        ) catch |err| {
            if (builtin.os.tag == .windows) {
                _ = win.MessageBoxA(
                    null,
                    "vesti compilation error occurs. See the console for more information",
                    "vesti compile failed",
                    win.MB_OK | win.MB_ICONEXCLAMATION,
                );
            }
            try diagnostic.prettyPrint(attr.no_color);

            if (err == error.FailedToOpenFile) return err;
            if (attr.no_exit_err) {
                std.debug.print("Ctrl+C to quit...\n", .{});
                prev_mtime.* = std.time.nanoTimestamp();
                std.Thread.sleep(200 * time.ns_per_ms);
                continue;
            } else {
                return err;
            }
        };

        if (!attr.watch) break;
    }
}

fn compileInner(
    allocator: Allocator,
    main_filenames: []const []const u8,
    lua: *Lua,
    diagnostic: *diag.Diagnostic,
    engine: *LatexEngine,
    compile_limit: usize,
    prev_mtime: *?i128,
    luacode_contents: ?[:0]const u8,
    luacode_scripts: []const u8,
    attr: CompileAttribute,
) !void {
    // make vesti-dummy directory
    fs.cwd().makeDir(VESTI_DUMMY_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var vesti_dummy = try fs.cwd().openDir(VESTI_DUMMY_DIR, .{});
    defer vesti_dummy.close();

    // add .gitignore file in default
    var git_ignore = try vesti_dummy.createFile(".gitignore", .{});
    defer git_ignore.close();

    var write_buf: [120]u8 = undefined;
    var writer = git_ignore.writer(&write_buf);
    try writer.interface.writeAll("*\n");
    try writer.end();

    // store "absolute paths" for vesti files
    var main_vesti_files: StringArrayHashMap(bool) = .{};
    defer {
        for (main_vesti_files.keys()) |vesti_file| allocator.free(vesti_file);
        main_vesti_files.deinit(allocator);
    }
    for (main_filenames) |filename| {
        if (!mem.eql(u8, path.extension(filename), "ves")) {
            const io_diag = try diag.IODiagnostic.init(
                diagnostic.allocator,
                null,
                "extension of `{s}` is not `ves`",
                .{filename},
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.ExtensionDifferent;
        }

        const real_filename = fs.cwd().realpathAlloc(allocator, filename) catch {
            const io_diag = try diag.IODiagnostic.init(
                diagnostic.allocator,
                null,
                "failed to open file `{s}`",
                .{filename},
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.FailedToOpenFile;
        };
        errdefer allocator.free(real_filename);
        try main_vesti_files.put(allocator, real_filename, true);
    }

    var vesti_files = if (attr.compile_all)
        StringArrayHashMap(bool){}
    else
        main_vesti_files;
    defer {
        if (attr.compile_all) {
            for (vesti_files.keys()) |vesti_file| allocator.free(vesti_file);
            vesti_files.deinit(allocator);
        }
    }

    var walk_dir = try fs.cwd().openDir(".", .{ .iterate = true });
    defer walk_dir.close();

    var is_compiled = false;
    while (attr.watch) {
        try updateVesFiles(
            allocator,
            &walk_dir,
            attr.compile_all,
            &main_vesti_files,
            &vesti_files,
        );

        // vesti -> latex
        for (vesti_files.keys()) |vesti_file| {
            if (prev_mtime.*) |pmtime| {
                const stat = try fs.cwd().statFile(vesti_file);
                if (stat.mtime > pmtime) {
                    try vestiToLatex(
                        allocator,
                        vesti_file,
                        lua,
                        diagnostic,
                        &vesti_dummy,
                        engine,
                        vesti_files.get(vesti_file).?,
                    );
                    is_compiled = true;
                }
            } else {
                try vestiToLatex(
                    allocator,
                    vesti_file,
                    lua,
                    diagnostic,
                    &vesti_dummy,
                    engine,
                    vesti_files.get(vesti_file).?,
                );
                is_compiled = true;
            }
        }

        // latex -> pdf
        if (is_compiled) {
            for (main_vesti_files.keys()) |filename| {
                try compileLatex(
                    allocator,
                    filename,
                    lua,
                    diagnostic,
                    engine.*,
                    &vesti_dummy,
                    luacode_contents,
                    luacode_scripts,
                    compile_limit,
                );
            }
            std.debug.print("Ctrl+C to quit...\n", .{});
            is_compiled = false;
        }

        prev_mtime.* = std.time.nanoTimestamp();
        std.Thread.sleep(200 * time.ns_per_ms);
    } else {
        try updateVesFiles(
            allocator,
            &walk_dir,
            attr.compile_all,
            &main_vesti_files,
            &vesti_files,
        );

        // vesti -> latex
        for (vesti_files.keys()) |vesti_file| {
            try vestiToLatex(
                allocator,
                vesti_file,
                lua,
                diagnostic,
                &vesti_dummy,
                engine,
                vesti_files.get(vesti_file).?,
            );
        }

        // latex -> pdf
        for (main_vesti_files.keys()) |filename| {
            try compileLatex(
                allocator,
                filename,
                lua,
                diagnostic,
                engine.*,
                &vesti_dummy,
                luacode_contents,
                luacode_scripts,
                compile_limit,
            );
        }
    }
}

// filename should be an absolute path
// TODO: prevent compiling vesti file which is already compiled at the step.
pub fn vestiToLatex(
    allocator: Allocator,
    filename: []const u8,
    lua: *Lua,
    diagnostic: *diag.Diagnostic,
    vesti_dummy_dir: *fs.Dir,
    engine: *LatexEngine,
    is_main: bool,
) !void {
    // since filename is an absolute name and it is a FILE, so dirname
    // always gives a dir_path
    const dir_path = path.dirname(filename) orelse unreachable;
    var vesti_file_dir = try fs.openDirAbsolute(dir_path, .{});
    defer vesti_file_dir.close();

    var vesti_file = fs.cwd().openFile(filename, .{}) catch |err| {
        const io_diag = try diag.IODiagnostic.init(
            diagnostic.allocator,
            null,
            "failed to open file `{s}`",
            .{filename},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return err;
    };
    defer vesti_file.close();

    var buf: [1024]u8 = undefined;
    var vesti_file_reader = vesti_file.reader(&buf);

    const source = vesti_file_reader.interface.allocRemaining(allocator, .unlimited) catch {
        const io_diag = try diag.IODiagnostic.init(
            diagnostic.allocator,
            null,
            "failed to read from {s}",
            .{filename},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.CompileVesFailed;
    };
    defer allocator.free(source);

    var parser: Parser = try .init(
        allocator,
        source,
        &vesti_file_dir,
        diagnostic,
        true,
        .{engine},
    );

    var ast = parser.parse() catch |err| switch (err) {
        Parser.ParseError.ParseFailed => {
            try diagnostic.initMetadataAlloc(filename, source);
            return err;
        },
        else => return err,
    };
    defer {
        for (ast.items) |*stmt| stmt.deinit(allocator);
        ast.deinit(allocator);
    }

    var aw: Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();

    // change engine type via `compty`
    lua.changeLatexEngine(engine.*);

    var codegen = try Codegen.init(
        allocator,
        source,
        ast.items,
        diagnostic,
    );
    defer codegen.deinit();
    codegen.codegen(lua, &aw.writer) catch |err| {
        try diagnostic.initMetadataAlloc(filename, source);
        return err;
    };
    var content = aw.toArrayList();
    defer content.deinit(allocator);

    const output_filename = try getTexFilename(allocator, filename, is_main);
    defer allocator.free(output_filename);
    var output_file = try vesti_dummy_dir.createFile(output_filename, .{});
    defer output_file.close();

    // write prologue
    var out_file_buf: [4096]u8 = undefined;
    var out_file_writer = output_file.writer(&out_file_buf);
    try out_file_writer.interface.print(
        \\%
        \\%    this file was generated by vesti {f}
        \\%    compile this file using {s} engine
        \\%    =========================================
        \\%    vesti: https://github.com/e0328eric/vesti
        \\%
        \\
    ,
        .{ VESTI_VERSION, engine.toStr() },
    );

    try out_file_writer.interface.writeAll(content.items);
    try out_file_writer.end();
}

// filename should be absolute
fn compileLatex(
    allocator: Allocator,
    filename: []const u8,
    lua: *Lua,
    diagnostic: *diag.Diagnostic,
    engine: LatexEngine,
    vesti_dummy: *fs.Dir,
    luacode_contents: ?[:0]const u8,
    luacode_scripts: []const u8,
    compile_limit: usize,
) !void {
    const main_tex_file = try getTexFilename(allocator, filename, true);
    defer allocator.free(main_tex_file);

    if (engine == .tectonic) {
        try compileLatexWithTectonic(
            allocator,
            diagnostic,
            main_tex_file,
            vesti_dummy,
            compile_limit,
        );
        if (luacode_contents) |lc| {
            try luascript.runLuaCode(lua, diagnostic, lc, luacode_scripts);
        }
    } else {
        for (0..compile_limit) |i| {
            std.debug.print("[compile number {}, engine: {s}]\n", .{
                i + 1,
                engine.toStr(),
            });

            try compileLatexWithInner(
                allocator,
                diagnostic,
                engine,
                main_tex_file,
                vesti_dummy,
            );
            if (luacode_contents) |lc| {
                try luascript.runLuaCode(lua, diagnostic, lc, luacode_scripts);
            }

            std.debug.print("[compiled]\n", .{});
        }
    }

    const main_pdf_file = try changeExtension(allocator, filename, "pdf");
    defer allocator.free(main_pdf_file);

    var from = try vesti_dummy.openFile(main_pdf_file, .{});
    defer from.close();
    var into = try fs.cwd().createFile(main_pdf_file, .{});
    defer into.close();

    var buf: [1024]u8 = undefined;
    var from_reader = from.reader(&buf);

    const pdf_context = try from_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(pdf_context);
    try into.writeAll(pdf_context);
}

fn compileLatexWithInner(
    allocator: Allocator,
    diagnostic: *diag.Diagnostic,
    engine: LatexEngine,
    main_tex_file: []const u8,
    vesti_dummy: *fs.Dir,
) !void {
    const result = try Child.run(.{
        .allocator = allocator,
        .argv = &.{ engine.toStr(), main_tex_file },
        .cwd = VESTI_DUMMY_DIR,
        .max_output_bytes = std.math.maxInt(usize),
        // XXX: https://github.com/ziglang/zig/issues/5190
        //.cwd_dir = vesti_dummy,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // write stdout and stderr in .vesti_dummy
    try vesti_dummy.writeFile(.{
        .sub_path = "stdout.txt",
        .data = result.stdout,
    });
    try vesti_dummy.writeFile(.{
        .sub_path = "stderr.txt",
        .data = result.stderr,
    });

    switch (result.term) {
        .Exited => |errcode| if (errcode != 0) {
            const io_diag = try diag.IODiagnostic.initWithNote(
                diagnostic.allocator,
                null,
                "{s} gaves an error while processing",
                .{engine.toStr()},
                "<Latex Engine Log>\n{s}",
                .{result.stdout},
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileLatexFailed;
        },
        else => return error.CompileLatexFailed,
    }
}

fn updateVesFiles(
    allocator: Allocator,
    root_dir: *fs.Dir,
    compile_all: bool,
    main_vesti_files: *const StringArrayHashMap(bool),
    vesti_files: *StringArrayHashMap(bool),
) !void {
    // if compile_all is false, just do nothing
    if (!compile_all) return;

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.eql(u8, path.extension(entry.basename), ".ves")) continue;

        const real_filename = try entry.dir.realpathAlloc(allocator, entry.basename);
        errdefer allocator.free(real_filename);

        if (vesti_files.get(real_filename) == null) {
            // check whether "real_filename" is a "main file"
            if (main_vesti_files.get(real_filename) != null) {
                try vesti_files.put(allocator, real_filename, true);
            } else {
                try vesti_files.put(allocator, real_filename, false);
            }
        } else {
            // we don't need this resource. Deallocate it
            allocator.free(real_filename);
        }
    }
}

// filename should be absolute
pub fn vestiNameMangle(allocator: Allocator, filename: []const u8) !ArrayList(u8) {
    const fnv1_hash = std.hash.Fnv1a_64.hash(filename);
    var output = try ArrayList(u8).initCapacity(allocator, 50);
    errdefer output.deinit(allocator);

    try output.print(allocator, "@vesti__{x}.tex", .{fnv1_hash});

    return output;
}

// filename should be absolute
fn getTexFilename(allocator: Allocator, filename: []const u8, is_main: bool) ![]const u8 {
    if (is_main) {
        return changeExtension(allocator, filename, "tex");
    } else {
        var output = try vestiNameMangle(allocator, filename);
        errdefer output.deinit(allocator);
        return try output.toOwnedSlice(allocator);
    }
}

fn changeExtension(
    allocator: Allocator,
    filename: []const u8,
    into: []const u8,
) ![]const u8 {
    const tmp = path.basename(filename);
    const idx = mem.lastIndexOfScalar(u8, tmp, '.') orelse return error.InvalidFilename;
    var output = try allocator.alloc(u8, idx + 1 + into.len);
    errdefer allocator.free(output);

    @memcpy(output[0..idx], tmp[0..idx]);
    output[idx] = '.';
    @memcpy(output[idx + 1 .. idx + 1 + into.len], into);
    return output;
}

// tectonic dlopen
const TectonicFnt = *const fn ([*]const u8, usize, [*]const u8, usize, usize) callconv(.c) bool;

fn compileLatexWithTectonic(
    allocator: Allocator,
    diagnostic: *diag.Diagnostic,
    main_tex_file: []const u8,
    vesti_dummy: *fs.Dir,
    compile_limit: usize,
) !void {
    // message templates
    const DLL_NOT_FOUND =
        "cannot find {s}, critical error!!!";
    const DLL_NOT_FOUND_NOTE =
        \\{0s} is assumed to locate at the same directory where the vesti exists.
        \\if this error message apprears, first check the {0s} location.
        \\otherwise, please make an issue on vesti github.
        \\repo url: https://github.com/e0328eric/vesti
    ;

    // tectonic dll is assumed to locate at the same directory with the vesti
    // below function follows symlink, which is expected
    const exe_dir = try fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir);
    const dll_hash = calculateDllHash(exe_dir) catch |err| switch (err) {
        error.FileNotFound => {
            const io_diag = try diag.IODiagnostic.initWithNote(
                diagnostic.allocator,
                null,
                DLL_NOT_FOUND,
                .{TECTONIC_DLL},
                DLL_NOT_FOUND_NOTE,
                .{TECTONIC_DLL},
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileLatexFailed;
        },
        else => return err,
    };

    if (dll_hash != TECTONIC_DLL_HASH) {
        const io_diag = try diag.IODiagnostic.initWithNote(
            diagnostic.allocator,
            null,
            "{s} is poisoned, critical error!!!",
            .{TECTONIC_DLL},
            \\{s} has unexpected hash value.
            \\For the security issue, please replace the dll from the repo.
            \\repo url: https://github.com/e0328eric/vesti
        ,
            .{TECTONIC_DLL},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.CompileLatexFailed;
    }

    var tectonic_dll = DynLib.open(TECTONIC_DLL) catch {
        const io_diag = try diag.IODiagnostic.initWithNote(
            diagnostic.allocator,
            null,
            DLL_NOT_FOUND,
            .{TECTONIC_DLL},
            DLL_NOT_FOUND_NOTE,
            .{TECTONIC_DLL},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.CompileLatexFailed;
    };
    defer tectonic_dll.close();

    const compile_latex_with_tectonic = tectonic_dll.lookup(
        TectonicFnt,
        "compile_latex_with_tectonic",
    );

    var curr_dir = try fs.cwd().openDir(".", .{});
    defer curr_dir.close();
    try vesti_dummy.setAsCwd();
    defer curr_dir.setAsCwd() catch @panic("failed to recover cwd");

    if (compile_latex_with_tectonic) |fnt| {
        if (!fnt(
            main_tex_file.ptr,
            main_tex_file.len,
            @ptrCast(VESTI_DUMMY_DIR),
            VESTI_DUMMY_DIR.len,
            compile_limit,
        )) {
            const io_diag = try diag.IODiagnostic.initWithNote(
                diagnostic.allocator,
                null,
                "tectonic gaves an error while processing",
                .{},
                "",
                .{},
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileLatexFailed;
        }
    } else return error.FindTectonicFunctionFailed;
}

fn calculateDllHash(exe_dir_path: []const u8) !u512 {
    // tectonic dll is assumed to locate at the same directory with the vesti
    // below function follows symlink, which is expected
    var exe_dir = try std.fs.openDirAbsolute(exe_dir_path, .{});
    defer exe_dir.close();

    var dll = try exe_dir.openFile(TECTONIC_DLL, .{});
    defer dll.close();
    var dll_read_buf: [4096]u8 = undefined;
    var dll_reader = dll.reader(&dll_read_buf);

    var sha_out: [Sha3.digest_length]u8 = undefined;
    var sha3 = Sha3.init(.{});

    var block: [Sha3.block_length]u8 = @splat(0);
    while (dll_reader.interface.readSliceAll(&block)) {
        sha3.update(&block);
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => return err,
    }
    sha3.final(&sha_out);

    return std.mem.bytesToValue(u512, &sha_out);
}

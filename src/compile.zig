const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const fs = std.fs;
const path = fs.path;
const time = std.time;
const diag = @import("./diagnostic.zig");
const run_script = @import("./run_script.zig");
const win = if (builtin.os.tag == .windows) @import("c") else {};

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const Codegen = @import("./Codegen.zig");
const Dynlib = std.DynLib;
const LatexEngine = Parser.LatexEngine;
const Lua = @import("./Lua.zig");
const Parser = @import("./parser/Parser.zig");
const StringArrayHashMap = std.StringArrayHashMap;

const TectonicFnt = fn ([*]const u8, usize, [*]const u8, usize, usize) callconv(.C) bool;

const VESTI_LOCAL_DUMMY_DIR = Parser.VESTI_LOCAL_DUMMY_DIR;
const VESTI_VERSION = @import("vesti-info").VESTI_VERSION;

pub const CompileAttribute = packed struct {
    compile_all: bool,
    watch: bool,
    no_color: bool,
    no_exit_err: bool,
};

pub fn compile(
    allocator: Allocator,
    main_filenames: []const []const u8,
    diagnostic: *diag.Diagnostic,
    engine: LatexEngine,
    compile_limit: usize,
    prev_mtime: *?i128,
    luacode_path: []const u8,
    attr: CompileAttribute,
) !void {
    const luacode_contents = try run_script.getBuildLuaContents(
        allocator,
        luacode_path,
        diagnostic,
    );
    defer if (luacode_contents) |lf| allocator.free(lf);

    while (true) {
        compileInner(
            allocator,
            main_filenames,
            diagnostic,
            engine,
            compile_limit,
            prev_mtime,
            luacode_contents,
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
                time.sleep(200 * time.ns_per_ms);
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
    diagnostic: *diag.Diagnostic,
    engine_: LatexEngine,
    compile_limit: usize,
    prev_mtime: *?i128,
    luacode_contents: ?[:0]const u8,
    attr: CompileAttribute,
) !void {
    // actually, one can change compile latex engine with `compty` keyword
    // inside of vesti codes.
    var engine = engine_;

    // make vesti-dummy directory
    fs.cwd().makeDir(VESTI_LOCAL_DUMMY_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var vesti_dummy = try fs.cwd().openDir(VESTI_LOCAL_DUMMY_DIR, .{});
    defer vesti_dummy.close();

    // store "absolute paths" for vesti files
    var main_vesti_files = StringArrayHashMap(bool).init(allocator);
    defer {
        for (main_vesti_files.keys()) |vesti_file| allocator.free(vesti_file);
        main_vesti_files.deinit();
    }
    for (main_filenames) |filename| {
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
        try main_vesti_files.put(real_filename, true);
    }

    var vesti_files = if (attr.compile_all)
        StringArrayHashMap(bool).init(allocator)
    else
        main_vesti_files;
    defer {
        if (attr.compile_all) {
            for (vesti_files.keys()) |vesti_file| allocator.free(vesti_file);
            vesti_files.deinit();
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
                        diagnostic,
                        &vesti_dummy,
                        &engine,
                        vesti_files.get(vesti_file).?,
                    );
                    is_compiled = true;
                }
            } else {
                try vestiToLatex(
                    allocator,
                    vesti_file,
                    diagnostic,
                    &vesti_dummy,
                    &engine,
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
                    diagnostic,
                    engine,
                    &vesti_dummy,
                    luacode_contents,
                    compile_limit,
                );
            }
            std.debug.print("Ctrl+C to quit...\n", .{});
            is_compiled = false;
        }

        prev_mtime.* = std.time.nanoTimestamp();
        time.sleep(200 * time.ns_per_ms);
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
                diagnostic,
                &vesti_dummy,
                &engine,
                vesti_files.get(vesti_file).?,
            );
        }

        // latex -> pdf
        for (main_vesti_files.keys()) |filename| {
            try compileLatex(
                allocator,
                filename,
                diagnostic,
                engine,
                &vesti_dummy,
                luacode_contents,
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

    const source = vesti_file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
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

    var parser = try Parser.init(
        allocator,
        source,
        &vesti_file_dir,
        diagnostic,
        true,
        engine,
    );
    defer parser.deinit();

    const ast = parser.parse() catch |err| switch (err) {
        Parser.ParseError.ParseFailed => {
            try diagnostic.initMetadataAlloc(filename, source);
            return err;
        },
        else => return err,
    };
    defer {
        for (ast.items) |stmt| stmt.deinit();
        ast.deinit();
    }

    var content = try ArrayList(u8).initCapacity(allocator, 256);
    defer content.deinit();

    const writer = content.writer();
    var codegen = try Codegen.init(allocator, source, ast.items, diagnostic);
    defer codegen.deinit();
    codegen.codegen(writer) catch |err| {
        try diagnostic.initMetadataAlloc(filename, source);
        return err;
    };

    const output_filename = try getTexFilename(allocator, filename, is_main);
    defer allocator.free(output_filename);
    var output_file = try vesti_dummy_dir.createFile(output_filename, .{});
    defer output_file.close();

    // write prologue
    try output_file.writer().print(
        \\%
        \\%    this file was generated by vesti {}
        \\%    compile this file using {s} engine
        \\%    =========================================
        \\%    vesti: https://github.com/e0328eric/vesti
        \\%
        \\
    ,
        .{ VESTI_VERSION, engine.toStr() },
    );

    try output_file.writeAll(content.items);
}

// filename should be absolute
fn compileLatex(
    allocator: Allocator,
    filename: []const u8,
    diagnostic: *diag.Diagnostic,
    engine: LatexEngine,
    vesti_dummy: *fs.Dir,
    luacode_contents: ?[:0]const u8,
    compile_limit: usize,
) !void {
    const main_tex_file = try getTexFilename(allocator, filename, true);
    defer allocator.free(main_tex_file);

    if (engine == .tectonic) {
        if (@import("vesti-info").use_tectonic) {
            try compileLatexWithTectonic(
                diagnostic,
                main_tex_file,
                vesti_dummy,
                compile_limit,
            );
            if (luacode_contents) |lc| {
                try run_script.runLuacode(allocator, diagnostic, lc);
            }
        } else {
            const io_diag = try diag.IODiagnostic.initWithNote(
                diagnostic.allocator,
                null,
                "this vesti executable does not supports tectonic",
                .{},
                "build vesti again with tectonic support",
                .{},
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileLatexFailed;
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
                try run_script.runLuacode(allocator, diagnostic, lc);
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

    const pdf_context = try from.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(pdf_context);
    try into.writeAll(pdf_context);
}

fn compileLatexWithTectonic(
    diagnostic: *diag.Diagnostic,
    main_tex_file: []const u8,
    vesti_dummy: *fs.Dir,
    compile_limit: usize,
) !void {
    var dll = try Dynlib.open("vesti_tectonic.dll");
    defer dll.close();

    if (dll.lookup(
        *const TectonicFnt,
        "compile_latex_with_tectonic",
    )) |comp| {
        // compile_latex_with_tectonic requires to change the current directory into
        // VESTI_LOCAL_DUMMY_DIR
        // if one store only fs.cwd(), then it breaks after `recovering` cwd, so
        // curr_dir should store fs.cwd().openDir(".").
        var curr_dir = try fs.cwd().openDir(".");
        defer curr_dir.close();
        try vesti_dummy.setAsCwd();
        defer curr_dir.setAsCwd() catch @panic("failed to recover cwd");

        if (!comp(
            main_tex_file.ptr,
            main_tex_file.len,
            @ptrCast(VESTI_LOCAL_DUMMY_DIR),
            VESTI_LOCAL_DUMMY_DIR.len,
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
    }
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
        .cwd = VESTI_LOCAL_DUMMY_DIR,
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
                try vesti_files.put(real_filename, true);
            } else {
                try vesti_files.put(real_filename, false);
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
    errdefer output.deinit();

    try output.writer().print("@vesti__{x}.tex", .{fnv1_hash});

    return output;
}

// filename should be absolute
fn getTexFilename(allocator: Allocator, filename: []const u8, is_main: bool) ![]const u8 {
    if (is_main) {
        return changeExtension(allocator, filename, "tex");
    } else {
        var output = try vestiNameMangle(allocator, filename);
        errdefer output.deinit();
        return try output.toOwnedSlice();
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

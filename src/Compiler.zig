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
const Stmt = @import("parser/ast.zig").Stmt;
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

allocator: Allocator,
main_filenames: []const []const u8,
lua: *Lua,
diagnostic: *diag.Diagnostic,
engine: *LatexEngine,
compile_limit: usize,
prev_mtime: *?i128,
luacode_scripts: LuaScripts,
luacode_contents: LuaContents,
global_defkinds: ArrayList(Stmt),
attr: CompileAttribute,

const Self = @This();

pub fn init(
    allocator: Allocator,
    main_filenames: []const []const u8,
    lua: *Lua,
    diagnostic: *diag.Diagnostic,
    engine: *LatexEngine,
    compile_limit: usize,
    prev_mtime: *?i128,
    luacode_scripts: LuaScripts,
    attr: CompileAttribute,
) !Self {
    const luacode_contents = try LuaContents.init(
        &luacode_scripts,
        allocator,
        diagnostic,
    );
    errdefer luacode_contents.deinit(allocator);

    return .{
        .allocator = allocator,
        .main_filenames = main_filenames,
        .lua = lua,
        .diagnostic = diagnostic,
        .engine = engine,
        .compile_limit = compile_limit,
        .prev_mtime = prev_mtime,
        .luacode_scripts = luacode_scripts,
        .luacode_contents = luacode_contents,
        .global_defkinds = .empty,
        .attr = attr,
    };
}

pub fn deinit(self: *Self) void {
    self.luacode_contents.deinit(self.allocator);
}

pub fn compile(self: *Self) !void {
    // run before.lua to "initialize" vesti projects
    if (self.luacode_contents.before) |lc| {
        try luascript.runLuaCode(
            self.lua,
            self.diagnostic,
            lc,
            self.luacode_scripts.before,
        );
    }

    while (true) {
        self.compileInner() catch |err| {
            if (builtin.os.tag == .windows) {
                _ = win.MessageBoxA(
                    null,
                    "vesti compilation error occurs. See the console for more information",
                    "vesti compile failed",
                    win.MB_OK | win.MB_ICONEXCLAMATION,
                );
            }
            // since diagnostic.prettyPrint is called in compile.compile, we should
            // avoid to print it twice (also on main)
            self.diagnostic.lock_print_at_main = true;
            try self.diagnostic.prettyPrint(self.attr.no_color);

            if (err == error.FailedToOpenFile) return err;
            if (!self.attr.watch) break;
            if (self.attr.no_exit_err) {
                std.debug.print("Ctrl+C to quit...\n", .{});
                self.prev_mtime.* = std.time.nanoTimestamp();
                std.Thread.sleep(200 * time.ns_per_ms);
                continue;
            } else {
                return err;
            }
        };

        if (!self.attr.watch) break;
    }
}

fn compileInner(self: *Self) !void {
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
        for (main_vesti_files.keys()) |vesti_file| self.allocator.free(vesti_file);
        main_vesti_files.deinit(self.allocator);
    }
    for (self.main_filenames) |filename| {
        if (!mem.eql(u8, path.extension(filename), ".ves")) {
            const io_diag = try diag.IODiagnostic.init(
                self.diagnostic.allocator,
                null,
                "extension of `{s}` is not `ves`",
                .{filename},
            );
            self.diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.ExtensionDifferent;
        }

        const real_filename = fs.cwd().realpathAlloc(self.allocator, filename) catch {
            const io_diag = try diag.IODiagnostic.init(
                self.diagnostic.allocator,
                null,
                "failed to open file `{s}`",
                .{filename},
            );
            self.diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.FailedToOpenFile;
        };
        errdefer self.allocator.free(real_filename);
        try main_vesti_files.put(self.allocator, real_filename, true);
    }

    var vesti_files = if (self.attr.compile_all)
        StringArrayHashMap(bool){}
    else
        main_vesti_files;
    defer {
        if (self.attr.compile_all) {
            for (vesti_files.keys()) |vesti_file| self.allocator.free(vesti_file);
            vesti_files.deinit(self.allocator);
        }
    }

    var walk_dir = try fs.cwd().openDir(".", .{ .iterate = true });
    defer walk_dir.close();

    var is_compiled = false;
    var vesti_contents: StringArrayHashMap(VestiContent) = .empty;
    defer {
        for (vesti_contents.values()) |*content| content.deinit(self.allocator);
        vesti_contents.deinit(self.allocator);
    }

    while (self.attr.watch) {
        try self.updateVesFiles(
            &walk_dir,
            &main_vesti_files,
            &vesti_files,
        );

        // parse vesti
        for (vesti_files.keys()) |vesti_file| {
            if (self.prev_mtime.*) |pmtime| {
                const stat = try fs.cwd().statFile(vesti_file);
                if (stat.mtime > pmtime) {
                    // this code comes first because if content.fond_existing is true
                    // and if vesti failes to parse, then the double free occurs.
                    //                   2025/11/09 Almagest
                    var new_content = try self.parseVesti(
                        vesti_file,
                        vesti_files.get(vesti_file).?,
                    );
                    errdefer new_content.deinit(self.allocator);

                    // TODO: make an error message for null case (file not exists)
                    const content = try vesti_contents.getOrPut(
                        self.allocator,
                        vesti_file,
                    );
                    // if the content already exists, then deallocate the old one
                    if (content.found_existing) content.value_ptr.deinit(self.allocator);
                    content.value_ptr.* = new_content;
                    is_compiled = true;
                }
            } else {
                // this code comes first because if content.fond_existing is true
                // and if vesti failes to parse, then the double free occurs.
                //                   2025/11/09 Almagest
                var new_content = try self.parseVesti(
                    vesti_file,
                    vesti_files.get(vesti_file).?,
                );
                errdefer new_content.deinit(self.allocator);

                // TODO: make an error message for null case (file not exists)
                const content = try vesti_contents.getOrPut(
                    self.allocator,
                    vesti_file,
                );
                // if the content already exists, then deallocate the old one
                if (content.found_existing) content.value_ptr.deinit(self.allocator);
                content.value_ptr.* = new_content;
                is_compiled = true;
            }
        }

        // vesti -> latex -> pdf
        if (is_compiled) {
            for (vesti_contents.values()) |content| {
                try self.vestiToLatex(&content, &vesti_dummy);
            }

            for (main_vesti_files.keys()) |filename| {
                try self.compileLatex(filename, &vesti_dummy);
            }
            std.debug.print("Ctrl+C to quit...\n", .{});
            is_compiled = false;
        }

        self.prev_mtime.* = std.time.nanoTimestamp();
        std.Thread.sleep(200 * time.ns_per_ms);
    } else {
        try self.updateVesFiles(
            &walk_dir,
            &main_vesti_files,
            &vesti_files,
        );

        // parse vesti
        for (vesti_files.keys()) |vesti_file| {
            // TODO: make an error message for null case (file not exists)
            var content = try self.parseVesti(
                vesti_file,
                vesti_files.get(vesti_file).?,
            );
            errdefer content.deinit(self.allocator);
            try vesti_contents.put(self.allocator, vesti_file, content);
        }

        // vesti -> latex -> pdf
        for (vesti_contents.values()) |content| {
            try self.vestiToLatex(&content, &vesti_dummy);
        }
        for (main_vesti_files.keys()) |filename| {
            try self.compileLatex(filename, &vesti_dummy);
        }
    }
}

// filename should be an absolute path
// TODO: prevent compiling vesti file which is already compiled at the step.
const VestiContent = struct {
    filename: []const u8, // pointer
    source: []const u8, // owned by this
    ast: ArrayList(Stmt) = .empty,
    is_main: bool = false,

    fn deinit(self: *@This(), allocator: Allocator) void {
        allocator.free(self.source);
        for (self.ast.items) |*stmt| stmt.deinit(allocator);
        self.ast.deinit(allocator);
    }
};

fn parseVesti(
    self: *Self,
    filename: []const u8,
    is_main: bool,
) !VestiContent {
    // since filename is an absolute name and it is a FILE, so dirname
    // always gives a dir_path
    const dir_path = path.dirname(filename) orelse unreachable;
    var vesti_file_dir = try fs.openDirAbsolute(dir_path, .{});
    defer vesti_file_dir.close();

    var vesti_file = fs.cwd().openFile(filename, .{}) catch |err| {
        const io_diag = try diag.IODiagnostic.init(
            self.diagnostic.allocator,
            null,
            "failed to open file `{s}`",
            .{filename},
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return err;
    };
    defer vesti_file.close();

    var buf: [1024]u8 = undefined;
    var vesti_file_reader = vesti_file.reader(&buf);

    const source = vesti_file_reader.interface.allocRemaining(self.allocator, .unlimited) catch {
        const io_diag = try diag.IODiagnostic.init(
            self.diagnostic.allocator,
            null,
            "failed to read from {s}",
            .{filename},
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.CompileVesFailed;
    };
    errdefer self.allocator.free(source);

    var parser: Parser = try .init(
        self.allocator,
        source,
        &vesti_file_dir,
        self.diagnostic,
        .{
            .luacode = true,
            .global_def = true,
            .is_main = is_main,
        },
        .{self.engine},
    );
    defer parser.deinit();

    var ast = parser.parse() catch |err| switch (err) {
        Parser.ParseError.ParseFailed => {
            try self.diagnostic.initMetadataAlloc(filename, source);
            return err;
        },
        else => return err,
    };
    errdefer {
        for (ast.items) |*stmt| stmt.deinit(self.allocator);
        ast.deinit(self.allocator);
    }

    const global_defkinds = try parser.global_defkinds.toOwnedSlice(self.allocator);
    errdefer {
        for (global_defkinds) |*stmt| stmt.deinit(self.allocator);
        self.allocator.free(global_defkinds);
    }
    try self.global_defkinds.appendSlice(self.allocator, global_defkinds);

    return .{
        .filename = filename,
        .source = source,
        .ast = ast,
        .is_main = is_main,
    };
}

pub fn vestiToLatex(
    self: *Self,
    content: *const VestiContent,
    vesti_dummy_dir: *fs.Dir,
) !void {
    var aw: Io.Writer.Allocating = try .initCapacity(self.allocator, 256);
    defer aw.deinit();

    // change engine type via `compty`
    self.lua.changeLatexEngine(self.engine.*);

    var codegen = try Codegen.init(
        self.allocator,
        content.source,
        content.ast.items,
        content.is_main,
        self.diagnostic,
    );
    defer codegen.deinit();
    codegen.codegen(self.lua, &self.global_defkinds, &aw.writer) catch |err| {
        try self.diagnostic.initMetadataAlloc(content.filename, content.source);
        return err;
    };
    var tex_content = aw.toArrayList();
    defer tex_content.deinit(self.allocator);

    const output_filename = try getTexFilename(
        self.allocator,
        content.filename,
        content.is_main,
    );
    defer self.allocator.free(output_filename);
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
        .{ VESTI_VERSION, self.engine.toStr() },
    );

    try out_file_writer.interface.writeAll(tex_content.items);
    try out_file_writer.end();
}

// filename should be absolute
fn compileLatex(
    self: *Self,
    filename: []const u8,
    vesti_dummy: *fs.Dir,
) !void {
    const main_tex_file = try getTexFilename(self.allocator, filename, true);
    defer self.allocator.free(main_tex_file);

    if (self.engine.* == .tectonic) {
        try self.compileLatexWithTectonic(main_tex_file, vesti_dummy);
        if (self.luacode_contents.before) |lc| {
            try luascript.runLuaCode(
                self.lua,
                self.diagnostic,
                lc,
                self.luacode_scripts.before,
            );
        }
    } else {
        for (0..self.compile_limit) |i| {
            std.debug.print("[compile number {}, engine: {s}]\n", .{
                i + 1,
                self.engine.toStr(),
            });

            try self.compileLatexWithInner(main_tex_file, vesti_dummy);
            if (self.luacode_contents.step) |lc| {
                try luascript.runLuaCode(
                    self.lua,
                    self.diagnostic,
                    lc,
                    self.luacode_scripts.step,
                );
            }

            std.debug.print("[compiled]\n", .{});
        }
    }

    const main_pdf_file = try changeExtension(self.allocator, filename, "pdf");
    defer self.allocator.free(main_pdf_file);

    var from = try vesti_dummy.openFile(main_pdf_file, .{});
    defer from.close();
    var into = try fs.cwd().createFile(main_pdf_file, .{});
    defer into.close();

    var buf: [1024]u8 = undefined;
    var from_reader = from.reader(&buf);

    const pdf_context = try from_reader.interface.allocRemaining(
        self.allocator,
        .unlimited,
    );
    defer self.allocator.free(pdf_context);
    try into.writeAll(pdf_context);
}

fn compileLatexWithInner(
    self: *Self,
    main_tex_file: []const u8,
    vesti_dummy: *fs.Dir,
) !void {
    const result = try Child.run(.{
        .allocator = self.allocator,
        .argv = &.{ self.engine.toStr(), main_tex_file },
        .cwd = VESTI_DUMMY_DIR,
        .max_output_bytes = std.math.maxInt(usize),
        // XXX: https://github.com/ziglang/zig/issues/5190
        //.cwd_dir = vesti_dummy,
    });
    defer {
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
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
                self.diagnostic.allocator,
                null,
                "{s} gaves an error while processing",
                .{self.engine.toStr()},
                "<Latex Engine Log>\n{s}",
                .{result.stdout},
            );
            self.diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileLatexFailed;
        },
        else => return error.CompileLatexFailed,
    }
}

fn updateVesFiles(
    self: *Self,
    root_dir: *fs.Dir,
    main_vesti_files: *const StringArrayHashMap(bool),
    vesti_files: *StringArrayHashMap(bool),
) !void {
    // if compile_all is false, just do nothing
    if (!self.attr.compile_all) return;

    var walker = try root_dir.walk(self.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.eql(u8, path.extension(entry.basename), ".ves")) continue;

        const real_filename = try entry.dir.realpathAlloc(self.allocator, entry.basename);
        errdefer self.allocator.free(real_filename);

        if (vesti_files.get(real_filename) == null) {
            // check whether "real_filename" is a "main file"
            if (main_vesti_files.get(real_filename) != null) {
                try vesti_files.put(self.allocator, real_filename, true);
            } else {
                try vesti_files.put(self.allocator, real_filename, false);
            }
        } else {
            // we don't need this resource. Deallocate it
            self.allocator.free(real_filename);
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
    self: *Self,
    main_tex_file: []const u8,
    vesti_dummy: *fs.Dir,
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
    const exe_dir = try fs.selfExeDirPathAlloc(self.allocator);
    defer self.allocator.free(exe_dir);
    const dll_hash = calculateDllHash(exe_dir) catch |err| switch (err) {
        error.FileNotFound => {
            const io_diag = try diag.IODiagnostic.initWithNote(
                self.diagnostic.allocator,
                null,
                DLL_NOT_FOUND,
                .{TECTONIC_DLL},
                DLL_NOT_FOUND_NOTE,
                .{TECTONIC_DLL},
            );
            self.diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileLatexFailed;
        },
        else => return err,
    };

    if (dll_hash != TECTONIC_DLL_HASH) {
        const io_diag = try diag.IODiagnostic.initWithNote(
            self.diagnostic.allocator,
            null,
            "{s} is poisoned, critical error!!!",
            .{TECTONIC_DLL},
            \\{s} has unexpected hash value.
            \\For the security issue, please replace the dll from the repo.
            \\repo url: https://github.com/e0328eric/vesti
        ,
            .{TECTONIC_DLL},
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.CompileLatexFailed;
    }

    var tectonic_dll = DynLib.open(TECTONIC_DLL) catch {
        const io_diag = try diag.IODiagnostic.initWithNote(
            self.diagnostic.allocator,
            null,
            DLL_NOT_FOUND,
            .{TECTONIC_DLL},
            DLL_NOT_FOUND_NOTE,
            .{TECTONIC_DLL},
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
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
            self.compile_limit,
        )) {
            const io_diag = try diag.IODiagnostic.initWithNote(
                self.diagnostic.allocator,
                null,
                "tectonic gaves an error while processing",
                .{},
                "",
                .{},
            );
            self.diagnostic.initDiagInner(.{ .IOError = io_diag });
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

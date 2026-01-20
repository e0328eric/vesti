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
const EnvMap = std.process.Environ.Map;
const Io = std.Io;
const Lua = @import("Lua.zig");
const LatexEngine = Parser.LatexEngine;
const Parser = @import("parser/Parser.zig");
const Preprocessor = @import("parser/Preprocessor.zig");
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
    engine_already_changed: bool = false,
};

pub const LuaScripts = struct {
    before: []const u8,
    step: []const u8,
};

pub const LuaContents = struct {
    before: ?[:0]const u8 = null,
    step: ?[:0]const u8 = null,

    pub fn init(
        allocator: Allocator,
        io: Io,
        diagnostic: *diag.Diagnostic,
        scripts: *const LuaScripts,
    ) !@This() {
        var output: @This() = .{};

        inline for (&.{ "before", "step" }) |ty| {
            @field(output, ty) = try luascript.getBuildLuaContents(
                allocator,
                io,
                @field(scripts, ty),
                diagnostic,
            );
            errdefer if (@field(output, ty)) |lf| allocator.free(lf);
        }

        return output;
    }

    pub fn deinit(self: *const @This(), allocator: Allocator) void {
        inline for (&.{ "before", "step" }) |ty| {
            if (@field(self, ty)) |lf| allocator.free(lf);
        }
    }
};

allocator: Allocator,
io: Io,
env_map: *const EnvMap,
main_filename: []const u8,
lua: *Lua,
diagnostic: *diag.Diagnostic,
engine: *LatexEngine,
compile_limit: usize,
prev_mtime: *?i96,
luacode_scripts: LuaScripts,
luacode_contents: LuaContents,
global_defkinds: ArrayList(Stmt),
attr: CompileAttribute,

const Self = @This();

pub fn deinit(self: *Self) void {
    self.luacode_contents.deinit(self.allocator);
}

fn raiseMessagebox(
    allocator: Allocator,
    io: Io,
    comptime title: []const u8,
    comptime contents: []const u8,
) !void {
    switch (builtin.os.tag) {
        .windows => {
            const contents_z = try allocator.dupeZ(u8, contents);
            const title_z = try allocator.dupeZ(u8, title);
            defer {
                allocator.free(contents_z);
                allocator.free(title_z);
            }
            _ = win.MessageBoxA(
                null,
                @ptrCast(contents_z),
                @ptrCast(title_z),
                win.MB_OK | win.MB_ICONEXCLAMATION,
            );
        },
        .linux => {
            _ = Child.run(
                allocator,
                io,
                .{
                    .argv = &.{
                        "zenity",
                        "--error",
                        "--text=" ++ contents,
                        "--title=" ++ title,
                    },
                },
            ) catch |err| switch (err) {
                error.FileNotFound => {}, // some machine might not have zenity
                else => return err,
            };
        },
        .macos => {}, // TODO: how can i raise a macos messagebox?
        else => @compileError("Non-Supporting OS"),
    }
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
            try raiseMessagebox(
                self.allocator,
                self.io,
                "vesti compile failed",
                "vesti compilation error occurs. See the console for more information",
            );
            // since diagnostic.prettyPrint is called in compile.compile, we
            // should avoid to print it twice (also on main)
            self.diagnostic.lock_print_at_main = true;
            try self.diagnostic.prettyPrint(self.attr.no_color);

            if (err == error.FailedToOpenFile) return err;
            if (!self.attr.watch) return err;
            if (self.attr.no_exit_err) {
                std.debug.print("Ctrl+C to quit...\n", .{});
                const timestamp = try Io.Clock.now(.real, self.io);
                self.prev_mtime.* = timestamp.toNanoseconds();
                Io.sleep(self.io, .fromMilliseconds(200), .real) catch @panic("sleep failed");
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
    Io.Dir.cwd().createDir(self.io, VESTI_DUMMY_DIR, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var vesti_dummy = try Io.Dir.cwd().openDir(self.io, VESTI_DUMMY_DIR, .{});
    defer vesti_dummy.close(self.io);

    // add .gitignore file in default
    var git_ignore = try vesti_dummy.createFile(self.io, ".gitignore", .{});
    defer git_ignore.close(self.io);

    var write_buf: [120]u8 = undefined;
    var writer = git_ignore.writer(self.io, &write_buf);
    try writer.interface.writeAll("*\n");
    try writer.end();

    // store "absolute paths" for vesti files
    var main_vesti_files: StringArrayHashMap(bool) = .{};
    defer {
        for (main_vesti_files.keys()) |vesti_file|
            // since Io.Dir.realPathFileAlloc returns [:0]u8, we must cast to
            // this pointer before deallocating it.
            self.allocator.free(@as([:0]const u8, @ptrCast(vesti_file)));
        main_vesti_files.deinit(self.allocator);
    }
    if (!mem.eql(u8, path.extension(self.main_filename), ".ves")) {
        const io_diag = try diag.IODiagnostic.init(
            self.diagnostic.allocator,
            null,
            "extension of `{s}` is not `ves`",
            .{self.main_filename},
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.ExtensionDifferent;
    }

    const real_filename = Io.Dir.cwd().realPathFileAlloc(
        self.io,
        self.main_filename,
        self.allocator,
    ) catch {
        const io_diag = try diag.IODiagnostic.init(
            self.diagnostic.allocator,
            null,
            "failed to open file `{s}`",
            .{self.main_filename},
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.FailedToOpenFile;
    };
    // although `real_filename` is allocated, after appending into
    // main_vesti_files, it deallocates when `main_vesti_files` deallocates.
    main_vesti_files.put(self.allocator, real_filename, true) catch |err| {
        self.allocator.free(real_filename);
        return err;
    };

    var vesti_files = if (self.attr.compile_all)
        StringArrayHashMap(bool){}
    else
        main_vesti_files;
    defer {
        if (self.attr.compile_all) {
            for (vesti_files.keys()) |vesti_file|
                self.allocator.free(@as([:0]const u8, @ptrCast(vesti_file)));
            vesti_files.deinit(self.allocator);
        }
    }

    var walk_dir = try Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true });
    defer walk_dir.close(self.io);

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
                const stat = try Io.Dir.cwd().statFile(self.io, vesti_file, .{});
                if (stat.mtime.toNanoseconds() > pmtime) {
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

        const timestamp = try Io.Clock.now(.real, self.io);
        self.prev_mtime.* = timestamp.toNanoseconds();
        Io.sleep(self.io, .fromMilliseconds(200), .real) catch @panic("sleep failed");
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
    var vesti_file_dir = try Io.Dir.openDirAbsolute(self.io, dir_path, .{});
    defer vesti_file_dir.close(self.io);

    var vesti_file = Io.Dir.cwd().openFile(self.io, filename, .{}) catch |err| {
        const io_diag = try diag.IODiagnostic.init(
            self.diagnostic.allocator,
            null,
            "failed to open file `{s}`",
            .{filename},
        );
        self.diagnostic.initDiagInner(.{ .IOError = io_diag });
        return err;
    };
    defer vesti_file.close(self.io);

    var buf: [1024]u8 = undefined;
    var vesti_file_reader = vesti_file.reader(self.io, &buf);

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

    var parser = Parser.init(
        self.allocator,
        self.io,
        self.env_map,
        source,
        &vesti_file_dir,
        self.diagnostic,
        .{
            .luacode = true,
            .global_def = true,
            .is_main = is_main,
            .change_engine = !self.attr.engine_already_changed,
        },
        .{self.engine},
    ) catch |err| switch (err) {
        Preprocessor.PreprocessError.ParseFailed => {
            try self.diagnostic.initMetadataAlloc(filename, source);
            return err;
        },
        else => return err,
    };
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
    vesti_dummy_dir: *Io.Dir,
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
    var output_file = try vesti_dummy_dir.createFile(self.io, output_filename, .{});
    defer output_file.close(self.io);

    // write prologue
    var out_file_buf: [4096]u8 = undefined;
    var out_file_writer = output_file.writer(self.io, &out_file_buf);
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
    vesti_dummy: *Io.Dir,
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

    var from = try vesti_dummy.openFile(self.io, main_pdf_file, .{});
    defer from.close(self.io);
    var into = try Io.Dir.cwd().createFile(self.io, main_pdf_file, .{});
    defer into.close(self.io);

    var reader_buf: [1024]u8 = undefined;
    var writer_buf: [1024]u8 = undefined;
    var from_reader = from.reader(self.io, &reader_buf);
    var into_writer = into.writer(self.io, &writer_buf);

    const pdf_context = try from_reader.interface.allocRemaining(
        self.allocator,
        .unlimited,
    );
    defer self.allocator.free(pdf_context);
    try into_writer.interface.writeAll(pdf_context);
    try into_writer.end();
}

fn compileLatexWithInner(
    self: *Self,
    main_tex_file: []const u8,
    vesti_dummy: *Io.Dir,
) !void {
    var latex_child = try std.process.spawn(self.io, .{
        .argv = &.{ self.engine.toStr(), main_tex_file },
        .cwd = VESTI_DUMMY_DIR,
        .stdout = .pipe,
        .stderr = .pipe,
        // NOTE: https://github.com/ziglang/zig/issues/5190
        //.cwd_dir = vesti_dummy,
    });
    errdefer latex_child.kill(self.io);

    var result_stdout: ArrayList(u8) = .empty;
    var result_stderr: ArrayList(u8) = .empty;
    defer {
        result_stdout.deinit(self.allocator);
        result_stderr.deinit(self.allocator);
    }

    try latex_child.collectOutput(
        self.allocator,
        &result_stdout,
        &result_stderr,
        std.math.maxInt(usize),
    );

    // write stdout and stderr in .vesti_dummy
    try vesti_dummy.writeFile(self.io, .{
        .sub_path = "stdout.txt",
        .data = result_stdout.items,
    });
    try vesti_dummy.writeFile(self.io, .{
        .sub_path = "stderr.txt",
        .data = result_stderr.items,
    });

    const result = try latex_child.wait(self.io);
    switch (result) {
        .exited => |errcode| if (errcode != 0) {
            const io_diag = try diag.IODiagnostic.initWithNote(
                self.diagnostic.allocator,
                null,
                "{s} gaves an error while processing",
                .{self.engine.toStr()},
                "<Latex Engine Log>\n{s}",
                .{result_stdout.items},
            );
            self.diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileLatexFailed;
        },
        else => return error.CompileLatexFailed,
    }
}

fn updateVesFiles(
    self: *Self,
    root_dir: *Io.Dir,
    main_vesti_files: *const StringArrayHashMap(bool),
    vesti_files: *StringArrayHashMap(bool),
) !void {
    // if compile_all is false, just do nothing
    if (!self.attr.compile_all) return;

    var walker = try root_dir.walk(self.allocator);
    defer walker.deinit();

    while (try walker.next(self.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.eql(u8, path.extension(entry.basename), ".ves")) continue;

        const real_filename = try entry.dir.realPathFileAlloc(
            self.io,
            entry.basename,
            self.allocator,
        );
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
    vesti_dummy: *Io.Dir,
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
    const exe_dir = try std.process.executableDirPathAlloc(self.io, self.allocator);
    defer self.allocator.free(exe_dir);
    const dll_hash = calculateDllHash(self.io, exe_dir) catch |err| switch (err) {
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

    var curr_dir = try Io.Dir.cwd().openDir(self.io, ".", .{});
    defer curr_dir.close(self.io);
    try std.process.setCurrentDir(self.io, vesti_dummy.*);
    defer std.process.setCurrentDir(self.io, curr_dir) catch @panic("failed to recover cwd");

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

fn calculateDllHash(io: Io, exe_dir_path: []const u8) !u512 {
    // tectonic dll is assumed to locate at the same directory with the vesti
    // below function follows symlink, which is expected
    var exe_dir = try Io.Dir.openDirAbsolute(io, exe_dir_path, .{});
    defer exe_dir.close(io);

    var dll = try exe_dir.openFile(io, TECTONIC_DLL, .{});
    defer dll.close(io);
    var dll_read_buf: [4096]u8 = undefined;
    var dll_reader = dll.reader(io, &dll_read_buf);

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

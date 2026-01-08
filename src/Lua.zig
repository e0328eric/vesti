const std = @import("std");
const zlua = @import("zlua");
const diag = @import("diagnostic.zig");
const ansi = @import("ansi.zig");
const fs = std.fs;
const zip = std.zip;
const http = std.http;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Codegen = @import("Codegen.zig");
const Config = @import("Config.zig");
const CowStr = @import("CowStr.zig").CowStr;
const CompileAttribute = @import("Compiler.zig").CompileAttribute;
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const LatexEngine = Parser.LatexEngine;
const Parser = @import("parser/Parser.zig");
const ZigLua = zlua.Lua;

const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;

lua: *ZigLua,
allocator: Allocator,
io: Io,
env_map: *const EnvMap,
buf: ArrayList(u8),
engine: LatexEngine,
make_log: bool,
is_first_lua: bool,
line_limit: usize,
main_ves: ?[:0]const u8,
compile_attr: CompileAttribute,

const Self = @This();
pub const Error = Allocator.Error || zlua.Error;

const VESTI_LUA_FUNCTIONS_BUILTINS: [12]zlua.FnReg = .{
    .{ .name = "print", .func = print },
    .{ .name = "parse", .func = parse },
    .{ .name = "getModule", .func = getModule },
    .{ .name = "vestiDummyDir", .func = vestiDummyDir },
    .{ .name = "getCurrentDir", .func = getCurrentDir },
    .{ .name = "setCurrentDir", .func = setCurrentDir },
    .{ .name = "getEngineType", .func = getEngineType },
    .{ .name = "unzip", .func = unzip },
    .{ .name = "download", .func = download },
    .{ .name = "mkdir", .func = mkdir },
    .{ .name = "joinpath", .func = joinpath },
    .{ .name = "compile", .func = compile },
};

pub fn init(
    allocator: Allocator,
    io: Io,
    env_map: *const EnvMap,
    engine: LatexEngine,
    config: *const Config,
    compile_attr: CompileAttribute,
) Error!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    // initialize fields of self
    self.allocator = allocator;
    self.io = io;
    self.env_map = env_map;
    self.engine = engine;
    self.make_log = config.lua.make_log;
    self.line_limit = config.lua.line_limit;
    self.buf = try .initCapacity(self.allocator, 100);
    errdefer self.buf.deinit(self.allocator);
    self.lua = try ZigLua.init(allocator);
    errdefer self.lua.deinit();
    self.is_first_lua = false;
    self.main_ves = null;
    self.compile_attr = compile_attr;

    // open all standard libraries of lua
    self.lua.openLibs();

    // declare vesti table
    self.lua.newLibTable(&VESTI_LUA_FUNCTIONS_BUILTINS);
    self.lua.pushLightUserdata(@ptrCast(self));
    self.lua.setFuncs(&VESTI_LUA_FUNCTIONS_BUILTINS, 1); // since self allocated in upval 1.
    self.lua.setGlobal("vesti");

    return self;
}

pub fn deinit(self: *Self) void {
    const allocator = self.allocator;

    if (self.main_ves) |s| allocator.free(s);
    self.buf.deinit(allocator);
    self.lua.deinit();
    allocator.destroy(self);
}

pub fn getError(self: *Self) ![:0]const u8 {
    return self.err.toOwnedSliceSentinel(self.allocator, 0);
}

pub fn clearVestiOutputStr(self: *Self) void {
    self.buf.clearRetainingCapacity();
}

pub fn evalCode(self: *Self, code: [:0]const u8) !void {
    self.lua.doString(code) catch {
        const err_msg = self.lua.toString(-1) catch unreachable;

        std.debug.print("================== <LUA ERROR> ==================\n", .{});
        std.debug.print("                    <LUACODE>\n", .{});

        // mimic goto
        const Goto = enum {
            start,
            print_console,
            make_log,
        };
        goto: switch (Goto.start) {
            .start => {
                if (self.make_log) {
                    std.debug.print(
                        "luacode is stored in {s}/luacode.lua\n",
                        .{VESTI_DUMMY_DIR},
                    );
                    continue :goto .make_log;
                } else continue :goto .print_console;
            },
            .print_console => {
                const lines_count = std.mem.count(u8, @ptrCast(code), "\n");
                if (lines_count >= self.line_limit) {
                    std.debug.print(
                        "luacode has so many lines than {d}. See {s}/luacode.lua\n",
                        .{ self.line_limit, VESTI_DUMMY_DIR },
                    );
                    continue :goto .make_log;
                }

                // print luacode into the stderr
                const padding = std.math.log10_int(lines_count);
                var line_iter = std.mem.splitScalar(u8, code[0..code.len -| 1], '\n');

                var i: usize = 1;
                while (line_iter.next()) |line| : (i += 1) {
                    std.debug.print("{d}", .{i});
                    for (0..(padding - std.math.log10_int(i))) |_| {
                        std.debug.print(" ", .{});
                    }
                    std.debug.print(" | {s}\n", .{line});
                }
            },
            .make_log => {
                var vesti_dummy = try Io.Dir.cwd().openDir(self.io, VESTI_DUMMY_DIR, .{});
                defer vesti_dummy.close(self.io);

                var lua_log_file = try vesti_dummy.createFile(self.io, "luacode.lua", .{});
                defer lua_log_file.close(self.io);

                var write_buf: [4096]u8 = undefined;
                var writer = lua_log_file.writer(self.io, &write_buf);

                try writer.interface.writeAll(code[0..code.len -| 1]);
                try writer.end();
            },
        }

        std.debug.print("-------------------------------------------------\n", .{});
        std.debug.print("                 <ERROR MESSAGE>\n", .{});
        std.debug.print("{s}\n", .{err_msg});
        std.debug.print("=================================================\n", .{});
        return error.LuaEvalFailed;
    };
}

pub fn getVestiOutputStr(self: *Self) ![:0]const u8 {
    return self.buf.toOwnedSliceSentinel(self.allocator, 0);
}

fn luaType2Str(ty: zlua.LuaType) []const u8 {
    return switch (ty) {
        .none => "none",
        .nil => "nil",
        .boolean => "boolean",
        .light_userdata => "light_userdata",
        .number => "number",
        .string => "string",
        .table => "table",
        .function => "function",
        .userdata => "userdata",
        .thread => "thread",
    };
}

pub fn changeLatexEngine(self: *Self, new_engine: LatexEngine) void {
    self.engine = new_engine;
}

inline fn getSelf(lua: *ZigLua) !*Self {
    return lua.toUserdata(Self, ZigLua.upvalueIndex(1));
}

// NOTE: lua.raiseError() does long jump so that defer does not work anymore.
// write lua wrappers with manual frees!
fn raiseError(lua: *ZigLua, comptime format: []const u8, args: anytype) noreturn {
    const allocator = lua.allocator();

    var err_msg: ArrayList(u8) = .empty;
    errdefer err_msg.deinit(allocator);
    err_msg.print(allocator, format, args) catch @panic("OOM");

    lua.where(1);
    _ = lua.pushString(err_msg.items);
    lua.concat(2);

    // since lua.raiseError() returns nothing, defer does not work. Thus we
    // should deallocate err_msg here
    err_msg.deinit(allocator);
    return lua.raiseError();
}

//          ╭─────────────────────────────────────────────────────────╮
//          │                  Lua Wrapper Functions                  │
//          ╰─────────────────────────────────────────────────────────╯

fn print(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const self = getSelf(lua) catch {
        lua.raiseError();
        return 0;
    };

    var nargs = lua.getTop();
    if (nargs == 0) raiseError(
        lua,
        \\invalid argument
        \\Usage: vesti.print(..., {{ sep = <string>, nl = <number >= 0>}}?)
        \\Default: sep = " ", nl = 1
    ,
        .{},
    );

    // defaults
    var sep: []const u8 = " ";
    var nl: usize = 1;

    if (lua.isTable(nargs)) {
        const sep_ty = lua.getField(nargs, "sep");
        switch (sep_ty) {
            .nil => {},
            .string => sep = @ptrCast(lua.toString(-1) catch unreachable),
            else => {
                raiseError(
                    lua,
                    "`sep` should be a string\n",
                    .{},
                );
                return 0;
            },
        }
        lua.pop(1); // pop "sep"

        const nl_ty = lua.getField(nargs, "nl");
        switch (nl_ty) {
            .nil => {},
            .number => {
                nl = @min(lua.toNumeric(usize, -1) catch unreachable, 2);
            },
            else => {
                raiseError(
                    lua,
                    "`nl` should be a nonnegative number\n",
                    .{},
                );
                return 0;
            },
        }
        lua.pop(1); // pop "nl"

        nargs -= 1;
    }

    // notice that lua index must start from 1. Since we need 1 <= i <= nargs,
    // instead, write 0 <= i < nargs and use i + 1 instead of i
    for (0..@intCast(nargs)) |i| {
        if (i > 0) self.buf.appendSlice(self.allocator, sep) catch @panic("OOM");

        const content = lua.toString(@intCast(i + 1)) catch raiseError(
            lua,
            "given value is not convertible into string\n",
            .{},
        );
        self.buf.appendSlice(self.allocator, @ptrCast(content)) catch @panic("OOM");
    }
    for (0..nl) |_| {
        self.buf.append(self.allocator, '\n') catch @panic("OOM");
    }
    return 0;
}

fn parse(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const self = getSelf(lua) catch {
        lua.raiseError();
        return 0;
    };
    const allocator = self.allocator;
    const io = self.io;

    if (lua.getTop() != 1) raiseError(
        lua,
        \\invalid argument
        \\Usage: vesti.parse(<ves_string: string>) -> string
    ,
        .{},
    );

    _ = lua.pushString("");
    lua.rotate(1, 1);
    lua.concat(lua.getTop());

    const vesti_code = lua.toString(-1) catch {
        const lua_ty = lua.typeOf(-1);
        lua.pop(1);
        raiseError(
            lua,
            "expected string, but got {s}",
            .{luaType2Str(lua_ty)},
        );
    };

    var diagnostic = diag.Diagnostic{ .allocator = allocator, .io = io };
    defer diagnostic.deinit();

    var cwd_dir = Io.Dir.cwd();
    var parser = Parser.init(
        allocator,
        io,
        self.env_map,
        vesti_code,
        &cwd_dir,
        &diagnostic,
        .{
            .luacode = false,
            .global_def = false,
        },
        .{ null, self.engine }, // disallow changing engine type
    ) catch |err| {
        lua.pop(1); // pop vesti_code

        diagnostic.deinit();
        raiseError(
            lua,
            "parser init faield because of {any}",
            .{err},
        );
    };
    defer parser.deinit();

    var ast = parser.parse() catch |err| {
        lua.pop(1); // pop vesti_code
        diagnostic.deinit();
        raiseError(
            lua,
            "parse failed. error: {any}",
            .{err},
        );
    };
    defer {
        for (ast.items) |*stmt| stmt.deinit(allocator);
        ast.deinit(allocator);
    }

    var aw = Io.Writer.Allocating.initCapacity(allocator, 256) catch @panic("OOM");
    defer aw.deinit();

    var codegen = Codegen.init(
        allocator,
        vesti_code,
        ast.items,
        false,
        &diagnostic,
    ) catch |err| {
        lua.pop(1); // pop vesti_code

        // cleanups
        aw.deinit();
        for (ast.items) |*stmt| stmt.deinit(allocator);
        ast.deinit(allocator);
        diagnostic.deinit();

        raiseError(
            lua,
            "parser init faield because of {any}",
            .{err},
        );
    };
    defer codegen.deinit();

    codegen.codegen(null, null, &aw.writer) catch |err| {
        diagnostic.initMetadata(
            CowStr.init(.Borrowed, .{@as([]const u8, "<luacode>")}),
            CowStr.init(.Borrowed, .{@as([]const u8, @ptrCast(vesti_code))}),
        );
        diagnostic.prettyPrint(true) catch @panic("print error");

        // pop vesti_code
        lua.pop(1);

        // cleanups
        codegen.deinit();
        aw.deinit();
        for (ast.items) |*stmt| stmt.deinit(allocator);
        ast.deinit(allocator);
        diagnostic.deinit();

        raiseError(
            lua,
            "parser init faield because of {any}",
            .{err},
        );
    };
    const content = aw.toOwnedSlice() catch @panic("OOM");
    defer allocator.free(content);

    lua.pop(1); // pop vesti_code
    _ = lua.pushString(content);

    return 1;
}

fn vestiDummyDir(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    _ = lua.pushString(VESTI_DUMMY_DIR);
    return 1;
}

fn getCurrentDir(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const allocator = lua.allocator();

    const cwd = std.process.getCwdAlloc(allocator) catch raiseError(
        lua,
        "cannot get the current directory",
        .{},
    );
    defer allocator.free(cwd);
    _ = lua.pushString(cwd);

    return 1;
}

fn setCurrentDir(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const self = getSelf(lua) catch {
        lua.raiseError();
        return 0;
    };
    const io = self.io;

    if (lua.getTop() != 1) raiseError(
        lua,
        \\invalid argument
        \\Usage: vesti.setCurrentDir(<dir_name: string>)
    ,
        .{},
    );

    const dir_path = lua.toString(1) catch raiseError(
        lua,
        \\first argument should be a `string`
        \\Usage: vesti.setCurrentDir(<dir_name: string>)
    ,
        .{},
    );
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch raiseError(
        lua,
        "cannot open directory `{s}`",
        .{dir_path},
    );
    defer dir.close(io);
    std.process.setCurrentDir(io, dir) catch {
        // cleanups
        dir.close(io);

        raiseError(
            lua,
            "failed to change directory into {s}",
            .{dir_path},
        );
    };

    return 0;
}

fn getEngineType(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const self = getSelf(lua) catch {
        lua.raiseError();
        return 0;
    };

    _ = lua.pushString(self.engine.toStr());
    return 1;
}

fn unzip(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const self = getSelf(lua) catch {
        lua.raiseError();
        return 0;
    };
    const io = self.io;

    if (lua.getTop() != 2) raiseError(
        lua,
        \\invalid argument
        \\Usage: vesti.unzip(<filename: string>, <dest_dir: string>)
    ,
        .{},
    );

    const filename = lua.toString(1) catch raiseError(
        lua,
        \\first argument should be a `string`
        \\Usage: vesti.unzip(<filename: string>, <dest_dir: string>)
    ,
        .{},
    );
    const dirpath = lua.toString(2) catch raiseError(
        lua,
        \\second argument should be a `string`
        \\Usage: vesti.unzip(<filename: string>, <dest_dir: string>)
    ,
        .{},
    );

    var zip_file = Io.Dir.cwd().openFile(io, filename, .{}) catch raiseError(
        lua,
        "cannot open a file `{s}`",
        .{filename},
    );
    defer zip_file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var reader = zip_file.reader(io, &reader_buf);

    var dest_dir = Io.Dir.cwd().openDir(io, dirpath, .{}) catch {
        // cleanups
        zip_file.close(io);

        raiseError(
            lua,
            \\cannot open a directory `{s}`.
            \\Notice that this function does not make a directory
        ,
            .{dirpath},
        );
    };
    defer dest_dir.close(io);

    zip.extract(dest_dir, &reader, .{}) catch {
        // cleanups
        dest_dir.close(io);
        zip_file.close(io);

        raiseError(
            lua,
            "failed to extract `{s}`",
            .{filename},
        );
    };

    lua.pushBoolean(true);
    return 1;
}

fn download(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const self = getSelf(lua) catch {
        lua.raiseError();
        return 0;
    };
    const allocator = lua.allocator();
    const io = self.io;

    if (lua.getTop() != 2) raiseError(
        lua,
        \\invalid argument
        \\Usage: vesti.download(<url: string>, <filename: string>)
    ,
        .{},
    );

    const url = lua.toString(1) catch raiseError(
        lua,
        \\first argument should be a `string`
        \\Usage: vesti.download(<url: string>, <filename: string>)
    ,
        .{},
    );
    const filename = lua.toString(2) catch raiseError(
        lua,
        \\second argument should be a `string`
        \\Usage: vesti.download(<url: string>, <filename: string>)
    ,
        .{},
    );

    var client = http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch {
        // cleanups
        client.deinit();

        raiseError(
            lua,
            "failed to parse uri from {s}",
            .{url},
        );
    };
    var req = client.request(.GET, uri, .{}) catch {
        // cleanups
        client.deinit();

        raiseError(
            lua,
            "failed to obtain a request from {s}",
            .{url},
        );
    };
    defer req.deinit();

    req.sendBodiless() catch {
        // cleanups
        req.deinit();
        client.deinit();

        raiseError(
            lua,
            "failed to obtain a response from {s}",
            .{url},
        );
    };

    var redirect_buf: [1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        // cleanups
        req.deinit();
        client.deinit();

        raiseError(
            lua,
            "failed to obtain a response from {s} because of {any}",
            .{ url, err },
        );
    };

    const max_window_len = std.compress.flate.max_window_len;
    var request_buf: [100]u8 = undefined;
    var decompress_buf: [max_window_len]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const reader = response.readerDecompressing(
        &request_buf,
        &decompress,
        &decompress_buf,
    );

    var file = Io.Dir.cwd().createFile(io, filename, .{}) catch {
        // cleanups
        req.deinit();
        client.deinit();

        raiseError(
            lua,
            "cannot create a file `{s}`",
            .{filename},
        );
    };
    defer file.close(io);

    var file_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &file_buf);

    while (true) {
        _ = reader.stream(&writer.interface, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                // cleanups
                file.close(io);
                req.deinit();
                client.deinit();

                raiseError(
                    lua,
                    "error occurs while writing into {s}, error: {any}",
                    .{ filename, err },
                );
            },
        };
    }
    writer.interface.flush() catch {
        // cleanups
        file.close(io);
        req.deinit();
        client.deinit();

        raiseError(
            lua,
            "failed to write into {s}",
            .{filename},
        );
    };

    return 0;
}

fn getModule(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const self = getSelf(lua) catch {
        lua.raiseError();
        return 0;
    };
    const allocator = lua.allocator();
    const io = self.io;

    if (lua.getTop() != 1) raiseError(
        lua,
        \\invalid argument
        \\Usage: vesti.getModule(<mod_name: string>)
    ,
        .{},
    );

    const mod_name = lua.toString(1) catch raiseError(
        lua,
        \\first argument should be a `string`
        \\Usage: vesti.getModule(<mod_name: string>)
    ,
        .{},
    );

    var diagnostic = diag.Diagnostic{ .allocator = allocator, .io = io };
    defer diagnostic.deinit();

    @import("ves_module.zig").downloadModule(
        allocator,
        io,
        self.env_map,
        &diagnostic,
        mod_name,
        null,
    ) catch {
        // cleanups
        diagnostic.deinit();

        raiseError(
            lua,
            "cannot get a vesti module {s}",
            .{mod_name},
        );
    };

    return 0;
}

fn mkdir(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const self = getSelf(lua) catch {
        lua.raiseError();
        return 0;
    };
    const io = self.io;

    if (lua.getTop() != 1) raiseError(
        lua,
        \\invalid argument
        \\Usage: vesti.mkdir(<dir_name: string>)
    ,
        .{},
    );

    const dir_name = lua.toString(1) catch raiseError(
        lua,
        \\first argument should be a `string`
        \\Usage: vesti.mkdir(<dir_name: string>)
    ,
        .{},
    );

    Io.Dir.cwd().createDir(io, dir_name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => raiseError(
            lua,
            "failed to make a directory {s}",
            .{dir_name},
        ),
    };

    return 0;
}

fn joinpath(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const allocator = lua.allocator();

    const nargs = lua.getTop();
    if (nargs == 0) raiseError(
        lua,
        \\invalid argument
        \\Usage: vesti.joinpath(...) -> string
    ,
        .{},
    );

    var args: ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    // notice that lua index must start from 1. Since we need 1 <= i <= nargs,
    // instead, write 0 <= i < nargs and use i + 1 instead of i
    for (0..@intCast(nargs)) |i| {
        const content = lua.toString(@intCast(i + 1)) catch raiseError(
            lua,
            "given value is not convertible into string\n",
            .{},
        );
        args.append(allocator, @ptrCast(content)) catch @panic("OOM");
    }

    const path = std.fs.path.join(allocator, args.items) catch @panic("OOM");
    defer allocator.free(path);

    _ = lua.pushString(path);
    return 1;
}

fn compile(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);
    const self = getSelf(lua) catch {
        lua.raiseError();
        return 0;
    };
    const allocator = self.allocator;

    if (!self.is_first_lua) raiseError(
        lua,
        \\cannot use `vesti.compile` outside of `first.lua`
    ,
        .{},
    );

    const nargs = lua.getTop();
    if (nargs == 0 or nargs > 2) raiseError(
        lua,
        \\invalid argument
        \\Usage: vesti.compile(<main_ves: string>, {{ <configurations> }}?)
        \\Config: `TODO`
    ,
        .{},
    );

    const main_ves = lua.toString(1) catch raiseError(
        lua,
        \\first argument should be a `string`
        \\Usage: vesti.compile(<main_ves: string>, {{ <configurations> }}?)
        \\Config: `TODO`
    ,
        .{},
    );

    const tmp = allocator.allocSentinel(u8, main_ves.len, 0) catch @panic("OOM");
    errdefer allocator.free(tmp);
    @memcpy(tmp, main_ves);
    self.main_ves = tmp;

    if (lua.isTable(nargs)) {
        inline for (.{
            "compile_all",
            "watch",
            "no_color",
            "no_exit_err",
        }) |attr| {
            const ty = lua.getField(nargs, attr);
            switch (ty) {
                .nil => {},
                .boolean => @field(self.compile_attr, attr) = lua.toBoolean(-1),
                else => {
                    raiseError(
                        lua,
                        "`" ++ attr ++ "` should be a boolean\n",
                        .{},
                    );
                    return 0;
                },
            }
            lua.pop(1); // pop attr
        }

        // setting engine
        const engine_ty = lua.getField(nargs, "engine");
        switch (engine_ty) {
            .nil => {},
            .string => blk: {
                const engine_string = lua.toString(-1) catch @panic("Internal Lua Bug");
                inline for (.{
                    .{ "latex", LatexEngine.latex },
                    .{ "pdf", LatexEngine.pdflatex },
                    .{ "xe", LatexEngine.xelatex },
                    .{ "lua", LatexEngine.lualatex },
                    .{ "tect", LatexEngine.tectonic },
                }) |info| {
                    if (std.mem.eql(u8, info[0], @ptrCast(engine_string))) {
                        self.engine = info[1];
                        self.compile_attr.engine_already_changed = true;
                        break :blk;
                    }
                }

                // at this point, engine string did not matched
                raiseError(
                    lua,
                    "invalid `engine`. Must either `latex`, `pdf`, `xe`, `lua`, or `tect`\n",
                    .{},
                );
                return 0;
            },
            else => {
                raiseError(
                    lua,
                    "`engine` should be a string\n",
                    .{},
                );
                return 0;
            },
        }
        lua.pop(1); // pop engine
    }

    return 0;
}

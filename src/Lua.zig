const std = @import("std");
const zlua = @import("zlua");
const diag = @import("./diagnostic.zig");
const ansi = @import("./ansi.zig");
const zip = std.zip;
const http = std.http;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Codegen = @import("Codegen.zig");
const CowStr = @import("CowStr.zig").CowStr;
const Io = std.Io;
const LatexEngine = Parser.LatexEngine;
const Parser = @import("parser/Parser.zig");
const ZigLua = zlua.Lua;

const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;

lua: *ZigLua,
allocator: Allocator,
buf: ArrayList(u8),
engine: LatexEngine,

const Self = @This();
pub const Error = Allocator.Error || zlua.Error;

const VESTI_LUA_FUNCTIONS_BUILTINS: [10]zlua.FnReg = .{
    .{ .name = "print", .func = print },
    .{ .name = "parse", .func = parse },
    .{ .name = "getModule", .func = getModule },
    .{ .name = "vestiDummyDir", .func = vestiDummyDir },
    .{ .name = "setCurrentDir", .func = setCurrentDir },
    .{ .name = "getEngine", .func = getEngine },
    .{ .name = "unzip", .func = unzip },
    .{ .name = "download", .func = download },
    .{ .name = "mkdir", .func = mkdir },
    .{ .name = "joinpath", .func = joinpath },
};

pub fn init(allocator: Allocator, engine: LatexEngine) Error!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    // initialize fields of self
    self.allocator = allocator;
    self.engine = engine;
    self.buf = try .initCapacity(self.allocator, 100);
    errdefer self.buf.deinit(self.allocator);
    self.lua = try ZigLua.init(allocator);
    errdefer self.lua.deinit();

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
        std.debug.print("=================================================\n", .{});
        std.debug.print("                   <LUA ERROR>\n", .{});
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

    var diagnostic = diag.Diagnostic{
        .allocator = allocator,
    };
    defer diagnostic.deinit();

    var cwd_dir = std.fs.cwd();
    var parser = Parser.init(
        allocator,
        vesti_code,
        &cwd_dir,
        &diagnostic,
        false, // disallow nested luacode
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

    codegen.codegen(null, &aw.writer) catch |err| {
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

fn setCurrentDir(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *ZigLua = @ptrCast(lua_state.?);

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
    var dir = std.fs.cwd().openDirZ(dir_path.ptr, .{}) catch raiseError(
        lua,
        "cannot open directory `{s}`",
        .{dir_path},
    );
    defer dir.close();
    dir.setAsCwd() catch {
        // cleanups
        dir.close();

        raiseError(
            lua,
            "failed to change directory into {s}",
            .{dir_path},
        );
    };

    return 0;
}

fn getEngine(lua_state: ?*zlua.LuaState) callconv(.c) c_int {
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

    var zip_file = std.fs.cwd().openFileZ(filename.ptr, .{}) catch raiseError(
        lua,
        "cannot open a file `{s}`",
        .{filename},
    );
    defer zip_file.close();

    var reader_buf: [4096]u8 = undefined;
    var reader = zip_file.reader(&reader_buf);

    var dest_dir = std.fs.cwd().openDirZ(dirpath.ptr, .{}) catch {
        // cleanups
        zip_file.close();

        raiseError(
            lua,
            \\cannot open a directory `{s}`.
            \\Notice that this function does not make a directory
        ,
            .{dirpath},
        );
    };
    defer dest_dir.close();

    zip.extract(dest_dir, &reader, .{}) catch {
        // cleanups
        dest_dir.close();
        zip_file.close();

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
    const allocator = lua.allocator();

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

    var client = http.Client{ .allocator = allocator };
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

    var file = std.fs.cwd().createFileZ(filename.ptr, .{}) catch {
        // cleanups
        req.deinit();
        client.deinit();

        raiseError(
            lua,
            "cannot create a file `{s}`",
            .{filename},
        );
    };
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    var writer = file.writer(&file_buf);

    while (true) {
        _ = reader.stream(&writer.interface, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                // cleanups
                file.close();
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
        file.close();
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
    const allocator = lua.allocator();

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

    var diagnostic = diag.Diagnostic{
        .allocator = allocator,
    };
    defer diagnostic.deinit();

    @import("ves_module.zig").downloadModule(
        allocator,
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

    std.fs.cwd().makeDirZ(dir_name.ptr) catch |err| switch (err) {
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

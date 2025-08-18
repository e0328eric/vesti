// TODO: after implementing pycode, nuke this file

const std = @import("std");
const diag = @import("./diagnostic.zig");
const ansi = @import("./ansi.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const CowStr = @import("./CowStr.zig").CowStr;
const Parser = @import("./parser/Parser.zig");
const Codegen = @import("./Codegen.zig");

const ZigLua = anyopaque;

lua: *opaque {},

const Self = @This();
pub const Error = Allocator.Error;

const VESTI_OUTPUT_STR: [:0]const u8 = "__VESTI_OUTPUT_STR__";
const VESTI_ERROR_STR: [:0]const u8 = "__VESTI_ERROR_STR__";

const VESTI_LUA_FUNCTIONS_BUILTINS: [7]struct {
    name: []const u8,
    val: fn (lua: *ZigLua) i32,
} = .{
    .{ .name = "print", .val = print },
    .{ .name = "printn", .val = printn },
    .{ .name = "println", .val = println },
    .{ .name = "parse", .val = parse },
    .{ .name = "setCurrentDir", .val = setCurrentDir },
    .{ .name = "getManifestDir", .val = getManifestDir },
    .{ .name = "printError", .val = printError },
};

pub fn init(allocator: Allocator) Error!Self {
    _ = allocator;
    return .{
        .lua = @ptrFromInt(1), // please nuke lua
    };
}

pub fn deinit(self: Self) void {
    _ = self;
}

pub fn getError(self: Self) ?[:0]const u8 {
    _ = self;
    return "";
}

pub fn clearVestiOutputStr(self: Self) void {
    _ = self;
}

pub fn evalCode(self: Self, code: [:0]const u8) !void {
    _ = self;
    _ = code;
}

pub fn getVestiOutputStr(self: Self) [:0]const u8 {
    _ = self;
    return "";
}

fn print(lua: *ZigLua) i32 {
    _ = lua;
    return 0;
}

fn printn(lua: *ZigLua) i32 {
    _ = lua;
    return 0;
}

fn println(lua: *ZigLua) i32 {
    _ = lua;
    return 0;
}

fn parse(lua: *ZigLua) i32 {
    _ = lua;
    return 0;
    //     if (lua.getTop() == 0) return 0;
    //     const allocator = lua.allocator();

    //     _ = lua.pushString("");
    //     lua.rotate(1, 1);
    //     lua.concat(lua.getTop());

    //     const vesti_code = lua.toString(-1) catch {
    //         const lua_ty = lua.typeOf(-1);
    //         lua.pop(1);
    //         var err_msg = ArrayList(u8).initCapacity(allocator, 100) catch @panic("OOM");
    //         defer err_msg.deinit();
    //         err_msg.writer().print(
    //             "expected string, but got {s}",
    //             .{luaType2Str(lua_ty)},
    //         ) catch @panic("OOM");
    //         err_msg.append(0) catch @panic("OOM");
    //         _ = lua.pushString(@ptrCast(err_msg.items));
    //         lua.setGlobal(VESTI_ERROR_STR);
    //         return 0;
    //     };

    //     var diagnostic = diag.Diagnostic{
    //         .allocator = allocator,
    //     };
    //     defer diagnostic.deinit();

    //     var cwd_dir = std.fs.cwd();
    //     var parser = Parser.init(
    //         allocator,
    //         vesti_code,
    //         &cwd_dir,
    //         &diagnostic,
    //         false, // disallow nested luacode
    //         null, // disallow changing engine type
    //     ) catch |err| {
    //         // pop vesti_code
    //         lua.pop(1);
    //         var err_msg = ArrayList(u8).initCapacity(allocator, 100) catch @panic("OOM");
    //         defer err_msg.deinit();
    //         err_msg.writer().print("parser init faield because of {!}", .{err}) catch @panic("OOM");
    //         err_msg.append(0) catch @panic("OOM");
    //         _ = lua.pushString(@ptrCast(err_msg.items));
    //         lua.setGlobal(VESTI_ERROR_STR);
    //         return 0;
    //     };

    //     const ast = parser.parse() catch |err| {
    //         switch (err) {
    //             Parser.ParseError.ParseFailed => {
    //                 diagnostic.initMetadata(
    //                     CowStr.init(.Borrowed, .{@as([]const u8, "<luacode>")}),
    //                     CowStr.init(.Borrowed, .{@as([]const u8, @ptrCast(vesti_code))}),
    //                 );
    //                 diagnostic.prettyPrint(true) catch @panic("print error on vesti.parse (lua)");
    //             },
    //             else => {},
    //         }

    //         // pop vesti_code
    //         lua.pop(1);
    //         var err_msg = ArrayList(u8).initCapacity(allocator, 100) catch @panic("OOM");
    //         defer err_msg.deinit();
    //         err_msg.writer().print("parse failed. error: {any}", .{err}) catch @panic("OOM");
    //         err_msg.append(0) catch @panic("OOM");
    //         _ = lua.pushString(@ptrCast(err_msg.items));
    //         lua.setGlobal(VESTI_ERROR_STR);
    //         return 0;
    //     };
    //     defer {
    //         for (ast.items) |stmt| stmt.deinit();
    //         ast.deinit();
    //     }

    //     var content = ArrayList(u8).initCapacity(allocator, 256) catch @panic("OOM");
    //     // content will be assigned into VESTI_OUTPUT_STR global variable
    //     defer content.deinit();

    //     const writer = content.writer();
    //     var codegen = Codegen.init(
    //         allocator,
    //         vesti_code,
    //         ast.items,
    //         &diagnostic,
    //     ) catch |err| {
    //         // pop vesti_code
    //         lua.pop(1);
    //         var err_msg = ArrayList(u8).initCapacity(allocator, 100) catch @panic("OOM");
    //         defer err_msg.deinit();
    //         err_msg.writer().print("parser init faield because of {any}", .{err}) catch @panic("OOM");
    //         err_msg.append(0) catch @panic("OOM");
    //         _ = lua.pushString(@ptrCast(err_msg.items));
    //         lua.setGlobal(VESTI_ERROR_STR);
    //         return 0;
    //     };
    //     defer codegen.deinit();

    //     codegen.codegen(writer) catch |err| {
    //         diagnostic.initMetadata(
    //             CowStr.init(.Borrowed, .{@as([]const u8, "<luacode>")}),
    //             CowStr.init(.Borrowed, .{@as([]const u8, @ptrCast(vesti_code))}),
    //         );
    //         diagnostic.prettyPrint(true) catch @panic("print error");

    //         // pop vesti_code
    //         lua.pop(1);
    //         var err_msg = ArrayList(u8).initCapacity(allocator, 100) catch @panic("OOM");
    //         defer err_msg.deinit();
    //         err_msg.writer().print("parser init faield because of {any}", .{err}) catch @panic("OOM");
    //         err_msg.append(0) catch @panic("OOM");
    //         _ = lua.pushString(@ptrCast(err_msg.items));
    //         lua.setGlobal(VESTI_ERROR_STR);
    //         return 0;
    //     };

    //     // pop vesti_code
    //     lua.pop(1);
    //     _ = lua.pushString(content.items);

    //     return 1;
}

fn getManifestDir(lua: *ZigLua) i32 {
    _ = lua.pushString(Parser.VESTI_LOCAL_DUMMY_DIR);
    return 1;
}

fn setCurrentDir(lua: *ZigLua) i32 {
    _ = lua;
    return 0;
    //     if (lua.getTop() == 0) {
    //         _ = lua.pushString("there is no path given");
    //         return 1;
    //     }

    //     const dir_path = lua.toString(-1) catch {
    //         _ = lua.pushString("failed to get a path");
    //         return 1;
    //     };
    //     var dir = std.fs.cwd().openDirZ(dir_path.ptr, .{}) catch {
    //         var err_msg = ArrayList(u8).initCapacity(lua.allocator(), 120) catch @panic("OOM");
    //         errdefer err_msg.deinit();
    //         err_msg.writer().print("failed to open {s}", .{dir_path}) catch @panic("OOM");
    //         err_msg.append(0) catch @panic("OOM");
    //         _ = lua.pushString(@ptrCast(err_msg.items));
    //         return 1;
    //     };
    //     dir.setAsCwd() catch {
    //         var err_msg = ArrayList(u8).initCapacity(lua.allocator(), 120) catch @panic("OOM");
    //         errdefer err_msg.deinit();
    //         err_msg.writer().print("failed to change directory into {s}", .{dir_path}) catch @panic("OOM");
    //         err_msg.append(0) catch @panic("OOM");
    //         _ = lua.pushString(@ptrCast(err_msg.items));
    //         return 1;
    //     };

    //     return 0;
}

fn printError(lua: *ZigLua) i32 {
    _ = lua;
    return 0;
    //     if (lua.getTop() == 0) return 0;

    //     const stderr_handle = std.fs.File.stderr();
    //     var stderr_buf: [4096]u8 = undefined;
    //     var stderr = stderr_handle.writer(&stderr_buf);
    //     defer stderr.end() catch @panic("IOErr");

    //     const msg = lua.toString(-1) catch return 0;

    //     if (stderr_handle.supportsAnsiEscapeCodes()) {
    //         stderr.interface.print(ansi.@"error" ++ "error: " ++ ansi.makeAnsi(null, .Bold) ++
    //             "{s}" ++ ansi.reset ++ "\n", .{msg}) catch @panic("IOErr");

    //         //if (try self.noteMsg(allocator)) |note_msg| {
    //         //    try stderr.print(
    //         //        ansi.note ++ "note: " ++ ansi.reset ++ "{s}\n",
    //         //        .{note_msg.items},
    //         //    );
    //         //    note_msg.deinit();
    //         //}
    //     } else {
    //         stderr.interface.print("error: {s}\n", .{msg}) catch @panic("IOErr");
    //         //if (try self.noteMsg(allocator)) |note_msg| {
    //         //    try stderr.print("note: {s}\n", .{note_msg.items});
    //         //    note_msg.deinit();
    //         //}
    //     }

    //     return 0;
}

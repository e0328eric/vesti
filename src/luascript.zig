const std = @import("std");
const fs = std.fs;
const diag = @import("diagnostic.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Lua = @import("Lua.zig");
const LatexEngine = @import("parser/Parser.zig").LatexEngine;

pub fn getBuildLuaContents(
    allocator: Allocator,
    io: Io,
    luacode_path: []const u8,
    diagnostic: *diag.Diagnostic,
) !?[:0]const u8 {
    const luacode_file = Io.Dir.cwd().openFile(io, luacode_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            const io_diag = try diag.IODiagnostic.init(
                diagnostic.allocator,
                null,
                "failed to read {s}",
                .{luacode_path},
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileVesFailed;
        },
    };
    defer luacode_file.close(io);

    var buf: [1024]u8 = undefined;
    var buf_reader = luacode_file.reader(io, &buf);

    const luacode_contents = try buf_reader.interface.allocRemainingAlignedSentinel(
        allocator,
        .unlimited,
        .of(u8),
        0,
    );
    return luacode_contents;
}

pub fn runLuaCode(
    lua: *Lua,
    diagnostic: *diag.Diagnostic,
    luacode_contents: [:0]const u8,
    filename: []const u8,
) !void {
    lua.evalCode(luacode_contents) catch {
        const lua_runtime_err = try diag.ParseDiagnostic.luaEvalFailed(
            diagnostic.allocator,
            null,
            "failed to run luacode from {s}",
            .{filename},
            "see above lua error message",
        );
        diagnostic.initDiagInner(.{ .ParseError = lua_runtime_err });
        return error.LuaEvalFailed;
    };
}

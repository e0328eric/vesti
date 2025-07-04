const std = @import("std");
const fs = std.fs;
const diag = @import("./diagnostic.zig");

const Allocator = std.mem.Allocator;
const Lua = @import("./Lua.zig");

pub fn getBuildLuaContents(
    allocator: Allocator,
    luacode_path: []const u8,
    diagnostic: *diag.Diagnostic,
) !?[:0]const u8 {
    const luacode_file = fs.cwd().openFile(luacode_path, .{}) catch |err| switch (err) {
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
    defer luacode_file.close();

    const luacode_contents = try luacode_file.readToEndAllocOptions(
        allocator,
        std.math.maxInt(usize),
        null,
        @alignOf(u8),
        0,
    );

    return luacode_contents;
}

pub fn runLuacode(
    allocator: Allocator,
    diagnostic: *diag.Diagnostic,
    luacode_contents: [:0]const u8,
) !void {
    const lua = Lua.init(allocator) catch {
        const io_diag = try diag.IODiagnostic.init(
            allocator,
            null,
            "failed to initialize lua vm",
            .{},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.LuaInitFailed;
    };
    defer lua.deinit();

    try lua.evalCode(luacode_contents);
}

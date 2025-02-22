const std = @import("std");
const ziglua = @import("ziglua");

const Allocator = std.mem.Allocator;
const ZigLua = ziglua.Lua;

lua: *ZigLua,

const Self = @This();
pub const Error = Allocator.Error || ziglua.Error;

const VESTI_OUTPUT_STR: [:0]const u8 = "__VESTI_OUTPUT_STR__";

const VESTI_LUA_FUNCTIONS_BUILTINS: [3]struct {
    name: []const u8,
    val: fn (lua: *ZigLua) i32,
} = .{
    .{ .name = "sprint", .val = sprint },
    .{ .name = "sprintn", .val = sprintn },
    .{ .name = "sprintln", .val = sprintln },
};

pub fn init(allocator: Allocator) Error!Self {
    const lua = try ZigLua.init(allocator);
    errdefer lua.deinit();

    // open all standard libraries of lua
    lua.openLibs();

    // add global variables that vesti uses
    _ = lua.pushString("");
    lua.setGlobal(VESTI_OUTPUT_STR);

    // declare vesti table
    lua.pushGlobalTable();
    lua.setGlobal("vesti");

    // this function throws error only if there is no global variable `vesti`.
    // however we already DEFINE the table
    _ = lua.getGlobal("vesti") catch unreachable;
    inline for (VESTI_LUA_FUNCTIONS_BUILTINS) |info| {
        _ = lua.pushString(info.name);
        lua.pushFunction(ziglua.wrap(info.val));
        lua.setTable(-3);
    }

    return Self{ .lua = lua };
}

pub fn deinit(self: Self) void {
    self.lua.deinit();
}

pub fn clearVestiOutputStr(self: Self) void {
    _ = self.lua.pushString("");
    self.lua.setGlobal(VESTI_OUTPUT_STR);
}

pub fn evalCode(self: Self, code: [:0]const u8) !void {
    try self.lua.doString(code);
}

pub fn getVestiOutputStr(self: Self) [:0]const u8 {
    _ = self.lua.getGlobal(VESTI_OUTPUT_STR) catch unreachable;
    return self.lua.toString(-1) catch unreachable;
}

fn sprint(lua: *ZigLua) i32 {
    if (lua.getTop() == 0) return 0;

    lua.pushNil();
    lua.rotate(1, 1);
    _ = lua.getGlobal(VESTI_OUTPUT_STR) catch unreachable;
    lua.replace(1);
    lua.concat(lua.getTop());
    lua.setGlobal(VESTI_OUTPUT_STR);

    return 0;
}

fn sprintn(lua: *ZigLua) i32 {
    if (lua.getTop() == 0) return 0;

    lua.pushNil();
    lua.rotate(1, 1);
    _ = lua.getGlobal(VESTI_OUTPUT_STR) catch unreachable;
    lua.replace(1);
    _ = lua.pushString("\n");
    lua.concat(lua.getTop());
    lua.setGlobal(VESTI_OUTPUT_STR);

    return 0;
}

fn sprintln(lua: *ZigLua) i32 {
    if (lua.getTop() == 0) return 0;

    lua.pushNil();
    lua.rotate(1, 1);
    _ = lua.getGlobal(VESTI_OUTPUT_STR) catch unreachable;
    lua.replace(1);
    _ = lua.pushString("\n\n");
    lua.concat(lua.getTop());
    lua.setGlobal(VESTI_OUTPUT_STR);

    return 0;
}

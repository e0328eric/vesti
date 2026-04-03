const builtin = @import("builtin");
const std = @import("std");
const c = @import("vesti_c.zig");
const fmt = std.fmt;
const unicode = std.unicode;

pub const DynLib = if (builtin.os.tag == .windows) WinDynLib else PosixDynLib;
const PosixDynLib = std.DynLib;

pub const WinDynLib = struct {
    inner: std.os.windows.HMODULE,

    const Self = @This();

    pub fn open(dll_name: []const u8) !Self {
        // what kind of dll name exceed 1024 bytes?
        var buf: [1024]u8 = undefined;
        var arena = std.heap.FixedBufferAllocator.init(&buf);
        const allocator = arena.allocator();

        const dll_name_z = try unicode.utf8ToUtf16LeAllocZ(allocator, dll_name);
        const dll_handle = c.LoadLibraryW(@ptrCast(dll_name_z));
        if (dll_handle == null) return error.OpenDllFailed;

        return .{ .inner = dll_handle.? };
    }

    pub fn close(self: *Self) void {
        c.FreeLibrary(self.inner);
    }

    pub fn lookup(self: *Self, comptime T: type, fnt_name: [:0]const u8) ?T {
        if (@typeInfo(T) != .pointer) {
            @compileError("non-pointer type was given");
        }

        const fnt_ptr = c.GetProcAddress(self.inner, @ptrCast(fnt_name));
        if (fnt_ptr == null) return null;
        return @as(T, @ptrCast(fnt_ptr));
    }
};

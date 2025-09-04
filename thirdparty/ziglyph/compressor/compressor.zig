const std = @import("std");
const builtin = @import("builtin");

const ZIG_VERSION = std.SemanticVersion.parse("0.14.1") catch unreachable;
comptime {
    if (builtin.zig_version.order(ZIG_VERSION) != .eq) {
        @compileError("use zig version 0.14.1 to compile this program");
    }
}

const Compressor = extern struct {
    filename: [:0]const u8,
};

export fn createCompressor() Compressor {}

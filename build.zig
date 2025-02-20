const std = @import("std");
const builtin = @import("builtin");
const path = std.fs.path;

const vesti_version = @import("./src/vesti_version.zig").VESTI_VERSION;

const min_zig_string = "0.14.0-dev.3213+53216d2f2";
const program_name = "vesti";

// NOTE: This code came from
// https://github.com/zigtools/zls/blob/master/build.zig.
const Build = blk: {
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(min_zig_string) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version v{} does not meet the minimum build requirement of v{}",
            .{ current_zig, min_zig },
        ));
    }
    break :blk std.Build;
};

const ZG_COMPOMENTS = .{
    "DisplayWidth",
    "PropsData",
};

const LUA_SRCS = .{
    "lapi.c",     "lauxlib.c", "lbaselib.c", "lcode.c",   "lcorolib.c",
    "lctype.c",   "ldblib.c",  "ldebug.c",   "ldo.c",     "ldump.c",
    "lfunc.c",    "lgc.c",     "linit.c",    "liolib.c",  "llex.c",
    "lmathlib.c", "lmem.c",    "loadlib.c",  "lobject.c", "lopcodes.c",
    "loslib.c",   "lparser.c", "lstate.c",   "lstring.c", "lstrlib.c",
    "ltable.c",   "ltablib.c", "ltm.c",      "lundump.c", "lutf8lib.c",
    "lvm.c",      "lzio.c",
};

pub fn build(b: *Build) !void {
    const allocator = std.heap.page_allocator;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlap = b.dependency("zlap", .{});
    const zg = b.dependency("zg", .{});

    const julia_dir = std.process.getEnvVarOwned(allocator, "JULIA_DIR") catch |err|
        switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print("`JULIA_DIR` should be specified\n", .{});
            return error.NeedJuliaDirEnv;
        },
        else => return err,
    };
    defer allocator.free(julia_dir);
    const julia_include_dir = try path.join(allocator, &.{
        julia_dir,
        "include",
        "julia",
    });
    defer allocator.free(julia_include_dir);
    const julia_dll_dir = try path.join(allocator, &.{
        julia_dir,
        "bin",
    });
    defer allocator.free(julia_dll_dir);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zlap", zlap.module("zlap"));
    inline for (ZG_COMPOMENTS) |component| {
        exe_mod.addImport("zg_" ++ component, zg.module(component));
    }
    exe_mod.addIncludePath(b.path("./libs/lua-5.4.7/src"));
    exe_mod.addCSourceFiles(.{
        .root = b.path("./libs/lua-5.4.7/src"),
        .files = &LUA_SRCS,
        .flags = &.{ "-std=gnu99", "-O2", "-Wall", "-DLUA_COMPAT_5_3" },
        .language = .c,
    });
    exe_mod.addIncludePath(.{ .cwd_relative = julia_include_dir });
    exe_mod.addLibraryPath(.{ .cwd_relative = julia_dll_dir });

    const exe = b.addExecutable(.{
        .name = "vesti",
        .version = vesti_version,
        .root_module = exe_mod,
    });
    if (builtin.os.tag == .windows) {
        exe.linkSystemLibrary("libjulia");
    } else {
        exe.linkSystemLibrary("julia");
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    inline for (ZG_COMPOMENTS) |component| {
        exe_unit_tests.root_module.addImport("zg_" ++ component, zg.module(component));
    }

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

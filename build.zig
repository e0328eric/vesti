const std = @import("std");
const builtin = @import("builtin");
const path = std.fs.path;

const vesti_version = @import("./src/vesti_version.zig").VESTI_VERSION;

const min_zig_string = "0.14.0-dev.3286+05d8b565a";
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

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlap = b.dependency("zlap", .{
        .target = target,
        .optimize = optimize,
    });
    const ziglua = b.dependency("ziglua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });
    const zg = b.dependency("zg", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zlap", zlap.module("zlap"));
    exe_mod.addImport("ziglua", ziglua.module("ziglua"));
    inline for (ZG_COMPOMENTS) |component| {
        exe_mod.addImport("zg_" ++ component, zg.module(component));
    }

    const exe = b.addExecutable(.{
        .name = "vesti",
        .version = vesti_version,
        .root_module = exe_mod,
    });
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

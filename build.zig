const std = @import("std");
const builtin = @import("builtin");
const path = std.fs.path;

const VESTI_VERSION_STR = @import("./build.zig.zon").version;
const VESTI_VERSION = std.SemanticVersion.parse(VESTI_VERSION_STR) catch unreachable;

const min_zig_string = "0.15.0-dev.736+b6d904624";
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

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = switch (optimize) {
        .ReleaseFast, .ReleaseSmall => true,
        else => false,
    };

    const zlap = b.dependency("zlap", .{
        .target = target,
        .optimize = optimize,
    });
    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });
    const ziglyph = b.dependency("ziglyph", .{
        .target = target,
        .optimize = optimize,
    });

    const vesti_c_header = b.addTranslateC(.{
        .root_source_file = b.path("./src/vesti_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const vesti_c = b.addModule("vesti-c", .{
        .root_source_file = vesti_c_header.getOutput(),
        .target = target,
        .optimize = optimize,
    });
    const vesti_opt = b.addOptions();
    vesti_opt.addOption(@TypeOf(VESTI_VERSION), "VESTI_VERSION", VESTI_VERSION);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("vesti-version", vesti_opt);
    exe_mod.addImport("zlap", zlap.module("zlap"));
    exe_mod.addImport("zlua", zlua.module("zlua"));
    exe_mod.addImport("ziglyph", ziglyph.module("ziglyph"));
    exe_mod.addImport("c", vesti_c);

    const exe = b.addExecutable(.{
        .name = "vesti",
        .version = VESTI_VERSION,
        .root_module = exe_mod,
        .strip = strip,
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
    exe_unit_tests.root_module.addImport("zlua", zlua.module("zlua"));
    exe_unit_tests.root_module.addImport("ziglyph", ziglyph.module("ziglyph"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

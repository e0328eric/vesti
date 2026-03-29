const std = @import("std");
const builtin = @import("builtin");
const path = std.fs.path;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const VESTI_VERSION_STR = @import("build.zig.zon").version;
const VESTI_VERSION = std.SemanticVersion.parse(VESTI_VERSION_STR) catch unreachable;
const MIN_ZIG_STRING = @import("build.zig.zon").minimum_zig_version;
const PROGRAM_NAME = @tagName(@import("build.zig.zon").name);

// default constants in vesti
const VESTI_DUMMY_DIR = "./.vesti-dummy";

// NOTE: This code came from
// https://github.com/zigtools/zls/blob/master/build.zig.
const Build = blk: {
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(MIN_ZIG_STRING) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version v{f} does not meet the minimum build requirement of v{f}",
            .{ current_zig, min_zig },
        ));
    }
    break :blk std.Build;
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //          ╭─────────────────────────────────────────────────────────╮
    //          │                       Build Step                        │
    //          ╰─────────────────────────────────────────────────────────╯
    // vesti-toolkit module
    _ = try buildVesti(b, target, optimize, .mod);

    const exe = try buildVesti(b, target, optimize, .exe);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    //          ╭─────────────────────────────────────────────────────────╮
    //          │                        Test Step                        │
    //          ╰─────────────────────────────────────────────────────────╯
    const exe_unit_tests = try buildVesti(b, target, optimize, .@"test");
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    //          ╭─────────────────────────────────────────────────────────╮
    //          │                      Release Step                       │
    //          ╰─────────────────────────────────────────────────────────╯
    // TODO: after obtaining tectonic dll for aarch64 linux and windows,
    // add two targets in here
    const release_step = b.step("release", "Make zigup binaries for release");
    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc },
        // NOTE: rpath is ignored, so I remove this target
        //.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    };

    for (targets) |t| {
        const cross_target = b.resolveTargetQuery(t);
        const release_exe = try buildVesti(b, cross_target, optimize, .exe);

        const target_output = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = try t.zigTriple(b.allocator),
                },
            },
        });
        release_step.dependOn(&target_output.step);
    }
}

fn buildVesti(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime build_mode: enum(u2) { mod, exe, @"test" },
) !switch (build_mode) {
    .mod => *Build.Module,
    else => *Build.Step.Compile,
} {
    const strip = switch (optimize) {
        .Debug, .ReleaseSafe => false,
        else => true,
    };

    const zlap = b.dependency("zlap", .{ .target = target, .optimize = optimize });
    const zlua = b.dependency("zlua", .{ .target = target, .optimize = optimize });
    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = b.path("uucode/uucode_config.zig"),
    });

    //const tectonic_lib_name = try getLibName(&target);
    const vesti_opt = b.addOptions();
    vesti_opt.addOption(@TypeOf(VESTI_VERSION), "VESTI_VERSION", VESTI_VERSION);
    vesti_opt.addOption([]const u8, "VESTI_DUMMY_DIR", VESTI_DUMMY_DIR);

    switch (build_mode) {
        .@"test" => {
            const test_mod = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "uucode", .module = uucode.module("uucode") },
                    .{ .name = "zlua", .module = zlua.module("zlua") },
                },
            });
            test_mod.addOptions("vesti-info", vesti_opt);

            return b.addTest(.{
                .name = "vesti-test",
                .root_module = test_mod,
            });
        },
        .exe => {
            const exe_mod = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .strip = strip,
                .imports = &.{
                    .{ .name = "zlap", .module = zlap.module("zlap") },
                    .{ .name = "uucode", .module = uucode.module("uucode") },
                    .{ .name = "zlua", .module = zlua.module("zlua") },
                },
            });
            exe_mod.addOptions("vesti-info", vesti_opt);

            if (target.result.os.tag == .windows) {
                exe_mod.linkSystemLibrary("Kernel32", .{});
                exe_mod.linkSystemLibrary("User32", .{});
            }

            return b.addExecutable(.{
                .name = PROGRAM_NAME,
                .version = VESTI_VERSION,
                .root_module = exe_mod,
            });
        },
        .mod => {
            const vesti_mod = b.addModule("vesti-toolkit", .{
                .root_source_file = b.path("src/vesti-toolkit.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "uucode", .module = uucode.module("uucode") },
                },
            });
            vesti_mod.addOptions("vesti-info", vesti_opt);
            return vesti_mod;
        },
    }
}

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const path = fs.path;

const Allocator = std.mem.Allocator;
const Child = std.process.Child;
const EnvMap = std.process.EnvMap;
const Sha3_256 = std.crypto.hash.sha3.Sha3_256;

const VESTI_VERSION_STR = "0.1.2";
const VESTI_VERSION = std.SemanticVersion.parse(VESTI_VERSION_STR) catch unreachable;

const min_zig_string = "0.14.1";
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

pub fn build(b: *Build) !void {
    const alloc = std.heap.page_allocator;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = switch (optimize) {
        .ReleaseFast, .ReleaseSmall => true,
        else => false,
    };

    const use_tectonic = b.option(bool, "tectonic", "use tectonic backend") orelse false;

    const zlap = b.dependency("zlap", .{
        .target = target,
        .optimize = optimize,
    });
    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });
    const zg = b.dependency("zg", .{
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

    if (use_tectonic) {
        try buildRust(b, alloc, target);
    }

    const vesti_opt = b.addOptions();
    vesti_opt.addOption(@TypeOf(VESTI_VERSION), "VESTI_VERSION", VESTI_VERSION);
    vesti_opt.addOption(bool, "USE_TECTONIC", use_tectonic);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zlap", .module = zlap.module("zlap") },
            .{ .name = "zlua", .module = zlua.module("zlua") },
            .{ .name = "zg_Properties", .module = zg.module("Properties") },
            .{ .name = "zg_DisplayWidth", .module = zg.module("DisplayWidth") },
            .{ .name = "c", .module = vesti_c },
        },
    });
    exe_mod.addOptions("vesti-info", vesti_opt);

    const exe = b.addExecutable(.{
        .name = "vesti",
        .version = VESTI_VERSION,
        .root_module = exe_mod,
    });
    if (use_tectonic) {
        exe.addLibraryPath(.{
            .cwd_relative = b.exe_dir,
        });
        exe.linkSystemLibrary2(
            "vesti_tectonic",
            .{ .search_strategy = .paths_first, .preferred_link_mode = .dynamic },
        );
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zlua", .module = zlua.module("zlua") },
            .{ .name = "zg_Properties", .module = zg.module("Properties") },
            .{ .name = "zg_DisplayWidth", .module = zg.module("DisplayWidth") },
        },
    });
    const exe_unit_tests = b.addTest(.{
        .name = "vesti-test",
        .root_module = test_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn buildRust(
    b: *Build,
    alloc: Allocator,
    target: Build.ResolvedTarget,
) !void {
    var tectonic_dir = try b.build_root.handle.openDir("./vesti-tectonic", .{});
    defer tectonic_dir.close();
    try tectonic_dir.setAsCwd();
    defer b.build_root.handle.setAsCwd() catch unreachable;

    var envmap = try std.process.getEnvMap(alloc);
    defer envmap.deinit();

    if (target.result.os.tag == .windows) {
        const vcpkg_root = try path.join(alloc, &.{
            b.build_root.path.?,
            "vesti-tectonic/target/vcpkg",
        });
        defer alloc.free(vcpkg_root);
        try envmap.put("TECTONIC_DEP_BACKEND", "vcpkg");
        try envmap.put("VCPKGRS_TRIPLET", "x64-windows-static-release");
        try envmap.put("RUSTFLAGS", "-Ctarget-feature=+crt-static");
        try envmap.put("VCPKG_ROOT", vcpkg_root);
    }

    const vcpkg_result = try Child.run(.{
        .allocator = alloc,
        .argv = &.{ "cargo", "vcpkg", "build" },
        .env_map = &envmap,
        .max_output_bytes = 2500 * 1024,
    });
    defer {
        alloc.free(vcpkg_result.stdout);
        alloc.free(vcpkg_result.stderr);
    }
    std.debug.print("stdout: {s}\n\nstderr: {s}\n", .{
        vcpkg_result.stdout,
        vcpkg_result.stderr,
    });

    const cargo_result = try Child.run(.{
        .allocator = alloc,
        .argv = &.{ "cargo", "build", "--release" },
        .env_map = &envmap,
        .max_output_bytes = 2500 * 1024,
    });
    defer {
        alloc.free(cargo_result.stdout);
        alloc.free(cargo_result.stderr);
    }
    std.debug.print("stdout: {s}\n\nstderr: {s}\n", .{
        cargo_result.stdout,
        cargo_result.stderr,
    });

    const dll_name = switch (target.result.os.tag) {
        .windows => "vesti_tectonic.dll",
        .linux => "vesti_tectonic.so",
        .macos => "vesti_tectonic.dylib",
        else => @panic("Not supported"),
    };

    const source_path_rel = try path.join(alloc, &.{
        "./vesti-tectonic/target/release/",
        dll_name,
    });
    defer alloc.free(source_path_rel);
    const source_path = try b.build_root.handle.realpathAlloc(alloc, source_path_rel);
    defer alloc.free(source_path);

    const dest_path = try path.join(alloc, &.{
        b.exe_dir,
        dll_name,
    });
    defer alloc.free(dest_path);

    try fs.cwd().makePath(b.exe_dir);

    std.debug.print(
        \\[NOTE]
        \\moving {s}
        \\ into  {s}
        \\
    , .{ source_path, dest_path });

    try fs.renameAbsolute(source_path, dest_path);
}

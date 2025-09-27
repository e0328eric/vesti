const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const path = fs.path;

const Allocator = std.mem.Allocator;
const Child = std.process.Child;
const EnvMap = std.process.EnvMap;

const VESTI_VERSION_STR = "0.5.0";
const VESTI_VERSION = std.SemanticVersion.parse(VESTI_VERSION_STR) catch unreachable;

// default constants in vesti
const VESTI_DUMMY_DIR = "./.vesti-dummy";

const min_zig_string = "0.16.0-dev.238+580b6d1fa";
const program_name = "vesti";

// NOTE: This code came from
// https://github.com/zigtools/zls/blob/master/build.zig.
const Build = blk: {
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(min_zig_string) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version v{f} does not meet the minimum build requirement of v{f}",
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

    const use_tectonic = b.option(bool, "tectonic", "use tectonic backend") orelse true;
    const use_julia = b.option(bool, "julia", "use jlcode") orelse true;

    const zlap = b.dependency("zlap", .{
        .target = target,
        .optimize = optimize,
    });

    const ziglyph = b.dependency("ziglyph", .{
        .target = target,
        .optimize = optimize,
    });

    const vesti_c_h = b.addTranslateC(.{
        .root_source_file = b.path("./src/vesti_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const vesti_c = b.createModule(.{
        .root_source_file = vesti_c_h.getOutput(),
        .target = target,
        .optimize = optimize,
    });

    var envmap = try std.process.getEnvMap(alloc);
    defer envmap.deinit();

    const jl_include, const jl_libs = blk: {
        if (!use_julia) break :blk .{ null, null };

        const jl_dir = envmap.get("JULIA_DIR") orelse {
            std.debug.print("`JULIA_DIR` env is not defined\n", .{});
            return error.BuildFailed;
        };
        const include = try std.fs.path.join(alloc, &.{
            jl_dir,
            "include",
            "julia",
        });
        errdefer alloc.free(include);
        const libs = try std.fs.path.join(alloc, &.{
            jl_dir,
            if (target.result.os.tag == .windows) "bin" else "lib",
        });
        errdefer alloc.free(libs);
        break :blk .{ include, libs };
    };
    defer {
        if (jl_include) |s| alloc.free(s);
        if (jl_libs) |s| alloc.free(s);
    }

    const tectonic_dll_name = try getDllName(&target);
    const vesti_opt = b.addOptions();
    vesti_opt.addOption(@TypeOf(VESTI_VERSION), "VESTI_VERSION", VESTI_VERSION);
    vesti_opt.addOption(bool, "USE_TECTONIC", use_tectonic);
    vesti_opt.addOption(bool, "USE_JULIA", use_julia);
    vesti_opt.addOption([]const u8, "VESTI_DUMMY_DIR", VESTI_DUMMY_DIR);
    vesti_opt.addOption([]const u8, "TECTONIC_DLL", tectonic_dll_name[0]);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .imports = &.{
            .{ .name = "zlap", .module = zlap.module("zlap") },
            .{ .name = "ziglyph", .module = ziglyph.module("ziglyph") },
            .{ .name = "c", .module = vesti_c },
        },
    });
    if (use_julia) {
        exe_mod.addCSourceFile(.{
            .file = b.path("src/julia/vesjulia.c"),
            .flags = &.{
                "-std=c11",
                "-Wno-implicit-int",
                "-DVESTI_DUMMY_DIR=\"" ++ VESTI_DUMMY_DIR ++ "\"",
            },
        });

        // note that both jl_include and jl_libs are well-defined in this scope
        exe_mod.addIncludePath(.{ .cwd_relative = jl_include.? });
        exe_mod.addLibraryPath(.{ .cwd_relative = jl_libs.? });
        switch (target.result.os.tag) {
            .windows => exe_mod.linkSystemLibrary("libjulia", .{
                .preferred_link_mode = .dynamic,
            }),
            else => exe_mod.linkSystemLibrary("julia", .{
                .preferred_link_mode = .dynamic,
            }),
        }
    }
    if (use_tectonic) exe_mod.addRPath(.{ .cwd_relative = b.exe_dir });
    exe_mod.addOptions("vesti-info", vesti_opt);

    const exe = b.addExecutable(.{
        .name = "vesti",
        .version = VESTI_VERSION,
        .root_module = exe_mod,
    });
    if (use_tectonic) {
        const install_dll = InstallDll.create(b, target);
        b.getInstallStep().dependOn(&install_dll.step);
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const build_rust = BuildRust.create(b, target);
    const build_rust_cmd = b.step("rust", "Build vesti-tectonic rust code");
    build_rust_cmd.dependOn(&build_rust.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ziglyph", .module = ziglyph.module("ziglyph") },
        },
    });
    if (use_julia) {
        test_mod.addCSourceFile(.{
            .file = b.path("src/julia/vesjulia.c"),
            .flags = &.{
                "-std=c11",
                "-Wno-implicit-int",
                "-DVESTI_DUMMY_DIR=\"" ++ VESTI_DUMMY_DIR ++ "\"",
            },
        });
        test_mod.addIncludePath(.{ .cwd_relative = jl_include.? });
        switch (target.result.os.tag) {
            .windows => {
                test_mod.addLibraryPath(.{ .cwd_relative = jl_libs.? });
                test_mod.linkSystemLibrary("libjulia", .{
                    .preferred_link_mode = .dynamic,
                });
            },
            else => test_mod.linkSystemLibrary("julia", .{
                .preferred_link_mode = .dynamic,
            }),
        }
    }
    test_mod.addOptions("vesti-info", vesti_opt);

    const exe_unit_tests = b.addTest(.{
        .name = "vesti-test",
        .root_module = test_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

const BuildRust = struct {
    step: Build.Step,
    target: Build.ResolvedTarget,

    fn create(owner: *Build, target: Build.ResolvedTarget) *BuildRust {
        const build_rust = owner.allocator.create(BuildRust) catch @panic("OOM");

        build_rust.* = .{
            .step = .init(.{
                .id = .custom,
                .name = "buildrust",
                .owner = owner,
                .makeFn = makeBuildRust,
            }),
            .target = target,
        };

        return build_rust;
    }
};

fn makeBuildRust(step: *Build.Step, options: Build.Step.MakeOptions) anyerror!void {
    _ = options;

    const b = step.owner;
    const alloc = b.allocator;
    const build_rust: *BuildRust = @fieldParentPtr("step", step);

    var envmap = try std.process.getEnvMap(alloc);
    defer envmap.deinit();

    if (build_rust.target.result.os.tag == .windows) {
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

    var tectonic_dir = try b.build_root.handle.openDir("./vesti-tectonic", .{});
    defer tectonic_dir.close();
    try tectonic_dir.setAsCwd();
    defer b.build_root.handle.setAsCwd() catch unreachable;

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

    const dll_names = try getDllName(&build_rust.target);
    for (dll_names) |name| {
        const source_path = try path.join(alloc, &.{
            "vesti-tectonic/target/release/",
            name,
        });
        defer alloc.free(source_path);

        const dest_path = try path.join(alloc, &.{
            "vesti-tectonic/bin/",
            name,
        });
        errdefer alloc.free(dest_path);

        std.debug.print(
            \\[NOTE]
            \\coping {s}
            \\ into  {s}
            \\
        , .{ source_path, dest_path });

        try b.build_root.handle.copyFile(
            source_path,
            b.build_root.handle,
            dest_path,
            .{},
        );

        const dll_path = try path.join(alloc, &.{
            "bin/",
            name,
        });
        errdefer alloc.free(dll_path);

        // compress binary using upx
        if (build_rust.target.result.os.tag == .windows) {
            const upx = try Child.run(.{
                .allocator = alloc,
                .argv = &.{ "upx", "-9", dll_path },
                .env_map = &envmap,
                .max_output_bytes = 2500 * 1024,
            });
            defer {
                alloc.free(upx.stdout);
                alloc.free(upx.stderr);
            }
            std.debug.print("stdout: {s}\n\nstderr: {s}\n", .{
                upx.stdout,
                upx.stderr,
            });
        }
    }
}

const InstallDll = struct {
    step: Build.Step,
    target: Build.ResolvedTarget,

    fn create(owner: *Build, target: Build.ResolvedTarget) *InstallDll {
        const install_dll = owner.allocator.create(InstallDll) catch @panic("OOM");

        install_dll.* = .{
            .step = .init(.{
                .id = .custom,
                .name = "install_dll",
                .owner = owner,
                .makeFn = makeInstallDll,
            }),
            .target = target,
        };

        return install_dll;
    }
};

fn makeInstallDll(step: *Build.Step, options: Build.Step.MakeOptions) anyerror!void {
    _ = options;

    const b = step.owner;
    const alloc = b.allocator;
    const install_dll: *InstallDll = @fieldParentPtr("step", step);

    const dll_names = try getDllName(&install_dll.target);
    const source_path_rel = try path.join(alloc, &.{
        "./vesti-tectonic/bin/",
        dll_names[0],
    });
    defer alloc.free(source_path_rel);
    const source_path = try b.build_root.handle.realpathAlloc(alloc, source_path_rel);
    defer alloc.free(source_path);

    const dest_path = try path.join(alloc, &.{
        b.exe_dir,
        dll_names[0],
    });
    errdefer alloc.free(dest_path);

    try fs.cwd().makePath(b.exe_dir);

    std.debug.print(
        \\[NOTE]
        \\coping {s}
        \\ into  {s}
        \\
    , .{ source_path, dest_path });

    try fs.copyFileAbsolute(source_path, dest_path, .{});
}

fn getDllName(target: *const Build.ResolvedTarget) error{NotSupport}![]const []const u8 {
    const os_tag = target.result.os.tag;
    const cpu_arch_tag = target.result.cpu.arch;

    return switch (os_tag) {
        .windows => switch (cpu_arch_tag) {
            .x86_64 => &.{
                "vesti_tectonic_x86_64.dll",
                "vesti_tectonic_x86_64.dll.lib",
            },
            .aarch64 => &.{
                "vesti_tectonic_aarch64.dll",
                "vesti_tectonic_aarch64.dll.lib",
            }, // TODO: compile prebuilt dll
            else => blk: {
                std.debug.print(
                    "Not supported for cpu architecture {} on Windows",
                    .{cpu_arch_tag},
                );
                break :blk error.NotSupport;
            },
        },
        .linux => switch (cpu_arch_tag) {
            .x86_64 => &.{"libvesti_tectonic_x86_64.so"},
            .x86 => &.{"libvesti_tectonic_x86.so"}, // TODO: compile prebuilt dll
            .aarch64 => &.{"libvesti_tectonic_aarch64.so"}, // TODO: compile prebuilt dll
            .arm => &.{"libvesti_tectonic_arm.so"}, // TODO: compile prebuilt dll
            else => blk: {
                std.debug.print(
                    "Not supported for cpu architecture {} on Linux",
                    .{cpu_arch_tag},
                );
                break :blk error.NotSupport;
            },
        },
        .macos => switch (cpu_arch_tag) {
            .aarch64 => &.{"libvesti_tectonic.dylib"},
            else => blk: {
                std.debug.print("Only arm MacOs is supported", .{});
                break :blk error.NotSupport;
            },
        },
        else => @panic("Not supported"),
    };
}

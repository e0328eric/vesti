const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const path = fs.path;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const EnvMap = std.process.EnvMap;
const Sha3 = std.crypto.hash.sha3.Sha3_512;

const VESTI_VERSION_STR = "0.6.0";
const VESTI_VERSION = std.SemanticVersion.parse(VESTI_VERSION_STR) catch unreachable;

// default constants in vesti
const VESTI_DUMMY_DIR = "./.vesti-dummy";

const min_zig_string = "0.15.2";
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
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //          ╭─────────────────────────────────────────────────────────╮
    //          │                       Build Step                        │
    //          ╰─────────────────────────────────────────────────────────╯
    const exe = try buildVesti(b, target, optimize);
    const install_dll = InstallDll.create(b, target, null);
    b.getInstallStep().dependOn(&install_dll.step);
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

    //          ╭─────────────────────────────────────────────────────────╮
    //          │                        Test Step                        │
    //          ╰─────────────────────────────────────────────────────────╯
    const ziglyph = b.dependency("ziglyph", .{
        .target = target,
        .optimize = optimize,
    });

    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
    });

    const tectonic_dll_name = try getDllName(&target);
    const tectonic_dll_hash = try calculateDllHash(b.allocator, tectonic_dll_name[1]);
    const vesti_opt = b.addOptions();
    vesti_opt.addOption(@TypeOf(VESTI_VERSION), "VESTI_VERSION", VESTI_VERSION);
    vesti_opt.addOption([]const u8, "VESTI_DUMMY_DIR", VESTI_DUMMY_DIR);
    vesti_opt.addOption([]const u8, "TECTONIC_DLL", tectonic_dll_name[1]);
    vesti_opt.addOption(u512, "TECTONIC_DLL_HASH", tectonic_dll_hash);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ziglyph", .module = ziglyph.module("ziglyph") },
            .{ .name = "zlua", .module = zlua.module("zlua") },
        },
    });
    test_mod.addOptions("vesti-info", vesti_opt);

    const exe_unit_tests = b.addTest(.{
        .name = "vesti-test",
        .root_module = test_mod,
    });

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
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        // NOTE: rpath is ignored, so I remove this target
        //.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    };

    for (targets) |t| {
        const cross_target = b.resolveTargetQuery(t);
        const release_exe = try buildVesti(b, cross_target, optimize);

        const target_output = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = try t.zigTriple(b.allocator),
                },
            },
        });
        release_step.dependOn(&target_output.step);

        // since this is a build script, leaking memories are safe
        const dir_path = try fs.path.join(b.allocator, &.{
            b.install_prefix,
            target_output.dest_dir.?.custom,
        });

        const release_install_dll = InstallDll.create(b, cross_target, dir_path);
        release_step.dependOn(&release_install_dll.step);
    }
}

fn buildVesti(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*Build.Step.Compile {
    const strip = switch (optimize) {
        .ReleaseFast, .ReleaseSmall => true,
        else => false,
    };

    const zlap = b.dependency("zlap", .{ .target = target, .optimize = optimize });
    const ziglyph = b.dependency("ziglyph", .{ .target = target, .optimize = optimize });
    const zlua = b.dependency("zlua", .{ .target = target, .optimize = optimize });

    const tectonic_dll_name = try getDllName(&target);
    const tectonic_dll_hash = try calculateDllHash(b.allocator, tectonic_dll_name[1]);
    const vesti_opt = b.addOptions();
    vesti_opt.addOption(@TypeOf(VESTI_VERSION), "VESTI_VERSION", VESTI_VERSION);
    vesti_opt.addOption([]const u8, "VESTI_DUMMY_DIR", VESTI_DUMMY_DIR);
    vesti_opt.addOption([]const u8, "TECTONIC_DLL", tectonic_dll_name[1]);
    vesti_opt.addOption(u512, "TECTONIC_DLL_HASH", tectonic_dll_hash);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .imports = &.{
            .{ .name = "zlap", .module = zlap.module("zlap") },
            .{ .name = "ziglyph", .module = ziglyph.module("ziglyph") },
            .{ .name = "zlua", .module = zlua.module("zlua") },
        },
    });
    switch (target.result.os.tag) {
        .linux => exe_mod.addRPath(.{ .cwd_relative = "$ORIGIN" }),
        .macos => exe_mod.addRPath(.{ .cwd_relative = "@executable_path" }),
        .windows => {}, // windows does not use rpath
        else => @panic("Non supported OS"),
    }
    exe_mod.addOptions("vesti-info", vesti_opt);

    return b.addExecutable(.{
        .name = "vesti",
        .version = VESTI_VERSION,
        .root_module = exe_mod,
    });
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

    const dll_name = try getDllName(&build_rust.target);
    const source_path = try path.join(alloc, &.{
        "vesti-tectonic/target/release/",
        dll_name[0],
    });
    defer alloc.free(source_path);

    const dest_path = try path.join(alloc, &.{
        "vesti-tectonic/bin/",
        dll_name[1],
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
        dll_name[1],
    });
    errdefer alloc.free(dll_path);

    // compress binary using upx
    switch (build_rust.target.result.os.tag) {
        .windows, .linux => {
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
        },
        else => {},
    }
}

const InstallDll = struct {
    step: Build.Step,
    target: Build.ResolvedTarget,
    dest_path: ?[]const u8,

    fn create(
        owner: *Build,
        target: Build.ResolvedTarget,
        dest_path: ?[]const u8,
    ) *InstallDll {
        const install_dll = owner.allocator.create(InstallDll) catch @panic("OOM");

        install_dll.* = .{
            .step = .init(.{
                .id = .custom,
                .name = "install_dll",
                .owner = owner,
                .makeFn = makeInstallDll,
            }),
            .target = target,
            .dest_path = dest_path,
        };

        return install_dll;
    }
};

fn makeInstallDll(
    step: *Build.Step,
    options: Build.Step.MakeOptions,
) anyerror!void {
    _ = options;

    const b = step.owner;
    const alloc = b.allocator;
    const install_dll: *InstallDll = @fieldParentPtr("step", step);

    const dll_name = try getDllName(&install_dll.target);
    const source_path_rel = try path.join(alloc, &.{
        "./vesti-tectonic/bin/",
        dll_name[1],
    });
    defer alloc.free(source_path_rel);
    const source_path = try b.build_root.handle.realpathAlloc(alloc, source_path_rel);
    defer alloc.free(source_path);

    const dest_path = install_dll.dest_path orelse b.exe_dir;
    const dest_path_with_dll = try path.join(alloc, &.{
        dest_path,
        dll_name[1],
    });
    defer alloc.free(dest_path_with_dll);

    try fs.cwd().makePath(dest_path);

    std.debug.print(
        \\[NOTE]
        \\coping {s}
        \\ into  {s}
        \\
    , .{ source_path, dest_path_with_dll });

    try fs.copyFileAbsolute(source_path, dest_path_with_dll, .{});
}

fn getDllName(target: *const Build.ResolvedTarget) error{NotSupport}![]const []const u8 {
    const os_tag = target.result.os.tag;
    const cpu_arch_tag = target.result.cpu.arch;

    return switch (os_tag) {
        .windows => switch (cpu_arch_tag) {
            .x86_64 => &.{
                "vesti_tectonic.dll",
                "vesti_tectonic_x86_64.dll",
            },
            .aarch64 => &.{
                "vesti_tectonic.dll",
                "vesti_tectonic_aarch64.dll",
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
            .x86_64 => &.{
                "libvesti_tectonic.so",
                "libvesti_tectonic_x86_64.so",
            },
            .x86 => &.{
                "libvesti_tectonic.so",
                "libvesti_tectonic_x86.so",
            }, // TODO: compile prebuilt dll
            .aarch64 => &.{
                "libvesti_tectonic.so",
                "libvesti_tectonic_aarch64.so",
            }, // TODO: compile prebuilt dll
            .arm => &.{
                "libvesti_tectonic.so",
                "libvesti_tectonic_arm.so",
            }, // TODO: compile prebuilt dll
            else => blk: {
                std.debug.print(
                    "Not supported for cpu architecture {} on Linux",
                    .{cpu_arch_tag},
                );
                break :blk error.NotSupport;
            },
        },
        .macos => switch (cpu_arch_tag) {
            .aarch64 => &.{
                "libvesti_tectonic.dylib",
                "libvesti_tectonic.dylib",
            },
            else => blk: {
                std.debug.print("Only arm MacOS is supported", .{});
                break :blk error.NotSupport;
            },
        },
        else => @panic("Not supported"),
    };
}

fn calculateDllHash(allocator: Allocator, tectonic_dll_name: []const u8) !u512 {
    const dll_path = try path.join(allocator, &.{
        "./vesti-tectonic/bin/",
        tectonic_dll_name,
    });
    defer allocator.free(dll_path);

    var dll = try std.fs.cwd().openFile(dll_path, .{});
    defer dll.close();
    var dll_read_buf: [4096]u8 = undefined;
    var dll_reader = dll.reader(&dll_read_buf);

    var sha_out: [Sha3.digest_length]u8 = undefined;
    var sha3 = Sha3.init(.{});

    var block: [Sha3.block_length]u8 = @splat(0);
    while (dll_reader.interface.readSliceAll(&block)) {
        sha3.update(&block);
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => return err,
    }
    sha3.final(&sha_out);

    return std.mem.bytesToValue(u512, &sha_out);
}

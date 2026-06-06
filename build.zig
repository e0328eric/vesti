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
    const macos_sdk_path = b.option(
        []const u8,
        "macos-sdk",
        "Path to MacOSX.sdk for macOS Rust/vcpkg cross builds",
    );

    //          ╭─────────────────────────────────────────────────────────╮
    //          │                       Build Step                        │
    //          ╰─────────────────────────────────────────────────────────╯
    const exe = try buildVesti(b, target, optimize, .exe);
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

    const build_rust = BuildRust.create(b, target, macos_sdk_path);
    const build_rust_cmd = b.step("rust", "Build vesti-tectonic rust code");
    build_rust_cmd.dependOn(&build_rust.step);

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
        const release_exe = try buildVesti(
            b,
            cross_target,
            optimize,
            .exe,
        );

        const target_output = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = try t.zigTriple(b.allocator),
                },
            },
        });
        release_step.dependOn(&target_output.step);

        // since this is a build script, leaking memories are safe
        const dir_path = try path.join(b.allocator, &.{
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
    comptime build_mode: enum(u1) { exe, @"test" },
) !*Build.Step.Compile {
    const strip = switch (optimize) {
        .Debug, .ReleaseSafe => false,
        else => true,
    };

    const zlap = b.dependency("zlap", .{ .target = target, .optimize = optimize });
    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua55,
    });
    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = b.path("src/uucode/uucode_config.zig"),
    });

    const tectonic_dll_name = try getDllName(&target);
    const vesti_opt = b.addOptions();
    vesti_opt.addOption(@TypeOf(VESTI_VERSION), "VESTI_VERSION", VESTI_VERSION);
    vesti_opt.addOption([]const u8, "VESTI_DUMMY_DIR", VESTI_DUMMY_DIR);
    vesti_opt.addOption([]const u8, "TECTONIC_DLL", tectonic_dll_name[1]);

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

            // TODO: link static library
            return b.addExecutable(.{
                .name = PROGRAM_NAME,
                .version = VESTI_VERSION,
                .root_module = exe_mod,
            });
        },
    }
}

const BuildRust = struct {
    step: Build.Step,
    target: Build.ResolvedTarget,
    macos_sdk_path: ?[]const u8,

    fn create(
        owner: *Build,
        target: Build.ResolvedTarget,
        macos_sdk_path: ?[]const u8,
    ) *BuildRust {
        const build_rust = owner.allocator.create(BuildRust) catch @panic("OOM");

        build_rust.* = .{
            .step = .init(.{
                .id = .custom,
                .name = "buildrust",
                .owner = owner,
                .makeFn = makeBuildRust,
            }),
            .target = target,
            .macos_sdk_path = macos_sdk_path,
        };

        return build_rust;
    }
};

fn makeBuildRust(
    step: *Build.Step,
    options: Build.Step.MakeOptions,
) anyerror!void {
    _ = options;

    const b = step.owner;
    const alloc = b.allocator;
    const io = b.graph.io;
    const build_rust: *BuildRust = @fieldParentPtr("step", step);
    var envmap = try b.graph.environ_map.clone(alloc);
    defer envmap.deinit();

    switch (build_rust.target.result.os.tag) {
        .windows => {
            const vcpkg_root = try path.join(alloc, &.{
                b.build_root.path.?,
                "vesti-tectonic/target/vcpkg",
            });
            defer alloc.free(vcpkg_root);
            try envmap.put("TECTONIC_DEP_BACKEND", "vcpkg");
            try envmap.put("VCPKGRS_TRIPLET", "x64-windows-static-release");
            try envmap.put("RUSTFLAGS", "-Ctarget-feature=+crt-static");
            try envmap.put("VCPKG_ROOT", vcpkg_root);
        },
        .macos => {
            // such setting is need when one compile macos dylib on either linux
            // or windows
            if (builtin.os.tag != .macos) {
                try configureMacosRustEnv(b, alloc, &envmap, build_rust);
            }

            // on macos, additional configuration is not needed
        },
        else => {},
    }

    var tectonic_dir = try b.build_root.handle.openDir(io, "./vesti-tectonic", .{});
    defer tectonic_dir.close(io);
    try std.process.setCurrentDir(io, tectonic_dir);
    defer std.process.setCurrentDir(io, b.build_root.handle) catch unreachable;

    const target_string = blk: {
        const target = build_rust.target;
        const os_tag = target.result.os.tag;
        const cpu_arch_tag = target.result.cpu.arch;
        const abi_tag = target.result.abi;

        break :blk switch (os_tag) {
            .windows => switch (cpu_arch_tag) {
                // Do we need musl on windows?
                .x86_64 => "x86_64-pc-windows-msvc",
                .aarch64 => "aarch64-pc-windows-msvc",
                else => {
                    std.debug.print(
                        "Not supported for cpu architecture {} on Windows",
                        .{cpu_arch_tag},
                    );
                    return error.NotSupport;
                },
            },
            .linux => switch (cpu_arch_tag) {
                .x86_64 => switch (abi_tag) {
                    .gnu => "x86_64-unknown-linux-gnu",
                    .musl => "x86_64-unknown-linux-musl",
                    else => {
                        std.debug.print(
                            "Not supported for abi {} on Linux x86_64",
                            .{abi_tag},
                        );
                        return error.NotSupport;
                    },
                },
                .x86 => "i686-unknwon-linux-gnu",
                .aarch64 => "aarch64_be-unknown-linux-gnu",
                .arm => "arm-unknown-linux-gnueabi",
                else => {
                    std.debug.print(
                        "Not supported for cpu architecture {} on Linux",
                        .{cpu_arch_tag},
                    );
                    return error.NotSupport;
                },
            },
            .macos => switch (cpu_arch_tag) {
                .aarch64 => "aarch64-apple-darwin",
                else => {
                    std.debug.print("Only arm MacOS is supported", .{});
                    return error.NotSupport;
                },
            },
            else => @panic("Not supported"),
        };
    };

    const vcpkg = try std.process.run(b.allocator, io, .{
        .argv = &.{ "cargo", "vcpkg", "-v", "build", "--target", target_string },
        .environ_map = &envmap,
    });
    defer {
        b.allocator.free(vcpkg.stdout);
        b.allocator.free(vcpkg.stderr);
    }

    std.debug.print("<vcpkg>\nstdout: {s}\n\nstderr: {s}\n", .{
        vcpkg.stdout,
        vcpkg.stderr,
    });
    try checkRunResult("cargo vcpkg build", vcpkg);

    const cargo_argv: []const []const u8 = switch (build_rust.target.result.os.tag) {
        .macos => &.{ "cargo", "zigbuild", "--release", "--target", target_string },
        else => &.{ "cargo", "build", "--release", "--target", target_string },
    };
    const cargo = try std.process.run(b.allocator, io, .{
        .argv = cargo_argv,
        .environ_map = &envmap,
    });
    defer {
        b.allocator.free(cargo.stdout);
        b.allocator.free(cargo.stderr);
    }

    std.debug.print("<cargo>\nstdout: {s}\n\nstderr: {s}\n", .{
        cargo.stdout,
        cargo.stderr,
    });
    try checkRunResult("cargo build", cargo);

    try getTectonic(b, alloc, io, build_rust, &envmap, target_string);
}

fn checkRunResult(name: []const u8, result: std.process.RunResult) !void {
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return;
            std.debug.print("{s} exited with code {}\n", .{ name, code });
        },
        .signal => |signal| {
            std.debug.print("{s} terminated by signal {}\n", .{ name, signal });
        },
        .stopped => |signal| {
            std.debug.print("{s} stopped by signal {}\n", .{ name, signal });
        },
        .unknown => |code| {
            std.debug.print("{s} ended with unknown status {}\n", .{ name, code });
        },
    }
    return error.CommandFailed;
}

fn configureMacosRustEnv(
    b: *Build,
    alloc: Allocator,
    envmap: *std.process.Environ.Map,
    build_rust: *BuildRust,
) !void {
    const vcpkg_root = try path.join(alloc, &.{
        b.build_root.path.?,
        "vesti-tectonic/target/vcpkg",
    });
    defer alloc.free(vcpkg_root);

    const triplet = switch (build_rust.target.result.cpu.arch) {
        .aarch64 => "arm64-osx-zig",
        else => return error.NotSupport,
    };

    try envmap.put("TECTONIC_DEP_BACKEND", "vcpkg");
    try envmap.put("VCPKG_ROOT", vcpkg_root);
    try envmap.put("VCPKGRS_TRIPLET", triplet);
    try envmap.put("MACOSX_DEPLOYMENT_TARGET", "13.0");

    if (envmap.get("ZIG") == null) {
        try envmap.put("ZIG", b.graph.zig_exe);
    }

    if (envmap.get("ZIG_LIBC_INCLUDE") == null) {
        const zig_libc_include = try path.join(alloc, &.{
            b.graph.zig_lib_directory.path.?,
            "libc",
            "include",
        });
        defer alloc.free(zig_libc_include);
        try envmap.put("ZIG_LIBC_INCLUDE", zig_libc_include);
    }

    if (envmap.get("ZIG_GLOBAL_CACHE_DIR") == null) {
        const zig_global_cache_dir = try path.join(alloc, &.{
            b.build_root.path.?,
            ".zig-global-cache",
        });
        defer alloc.free(zig_global_cache_dir);
        try envmap.put("ZIG_GLOBAL_CACHE_DIR", zig_global_cache_dir);
    }

    if (build_rust.macos_sdk_path) |sdk_path| {
        try putMacosSdkEnv(alloc, envmap, sdk_path);
        return;
    }

    if (envmap.get("SDKROOT")) |sdk_path| {
        try putMacosSdkEnv(alloc, envmap, sdk_path);
        return;
    }

    if (envmap.get("MACOSX_SDK")) |sdk_path| {
        try putMacosSdkEnv(alloc, envmap, sdk_path);
        return;
    }

    std.debug.print(
        \\Missing MacOSX.sdk for macOS Rust/vcpkg build.
        \\Pass -Dmacos-sdk=PATH, or set SDKROOT/MACOSX_SDK in the environment.
        \\
    , .{});
    return error.MissingMacosSdk;
}

fn putMacosSdkEnv(
    alloc: Allocator,
    envmap: *std.process.Environ.Map,
    sdk_path: []const u8,
) !void {
    const normalized_sdk_path = try normalizeCmakePath(alloc, sdk_path);
    defer alloc.free(normalized_sdk_path);
    try envmap.put("SDKROOT", normalized_sdk_path);
    try envmap.put("MACOSX_SDK", normalized_sdk_path);
}

fn normalizeCmakePath(alloc: Allocator, input: []const u8) ![]u8 {
    const trimmed = trimTrailingPathSeparators(input);
    const output = try alloc.dupe(u8, trimmed);
    for (output) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return output;
}

fn trimTrailingPathSeparators(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 0) {
        const last = input[end - 1];
        if (last != '/' and last != '\\') break;
        if (end == 1) break;
        if (end == 3 and input[1] == ':') break;
        end -= 1;
    }
    return input[0..end];
}

fn getTectonic(
    b: *Build,
    alloc: Allocator,
    io: Io,
    build_rust: *BuildRust,
    envmap: *std.process.Environ.Map,
    target_string: []const u8,
) !void {
    const name = try getDllName(&build_rust.target);
    const source_path = try path.join(alloc, &.{
        "vesti-tectonic/target/",
        target_string,
        "release",
        name[0],
    });
    defer alloc.free(source_path);

    const dest_path = try path.join(alloc, &.{
        "vesti-tectonic/bin/",
        name[1],
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
        io,
        .{},
    );

    const dll_path = try path.join(alloc, &.{
        "bin/",
        name[1],
    });
    errdefer alloc.free(dll_path);

    // compress binary using upx (only for dll)
    switch (build_rust.target.result.os.tag) {
        .windows, .linux => {
            const upx = try std.process.run(alloc, io, .{
                .argv = &.{ "upx", "-9", dll_path },
                .environ_map = envmap,
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
    const io = b.graph.io;
    const install_dll: *InstallDll = @fieldParentPtr("step", step);

    const dll_name = try getDllName(&install_dll.target);
    const source_path_rel = try path.join(alloc, &.{
        "./vesti-tectonic/bin/",
        dll_name[1],
    });
    defer alloc.free(source_path_rel);
    const source_path = try b.build_root.handle.realPathFileAlloc(
        io,
        source_path_rel,
        alloc,
    );
    defer alloc.free(source_path);

    const dest_path = install_dll.dest_path orelse b.exe_dir;
    const dest_path_with_dll = try path.join(alloc, &.{
        dest_path,
        dll_name[1],
    });
    defer alloc.free(dest_path_with_dll);

    try Io.Dir.cwd().createDirPath(io, dest_path);

    std.debug.print(
        \\[NOTE]
        \\coping {s}
        \\ into  {s}
        \\
    , .{ source_path, dest_path_with_dll });

    try Io.Dir.copyFileAbsolute(source_path, dest_path_with_dll, io, .{});
}

fn getDllName(target: *const Build.ResolvedTarget) error{NotSupport}![]const []const u8 {
    const os_tag = target.result.os.tag;
    const cpu_arch_tag = target.result.cpu.arch;
    const abi_tag = target.result.abi;

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
            .x86_64 => switch (abi_tag) {
                .gnu => &.{
                    "libvesti_tectonic.so",
                    "libvesti_tectonic_x86_64_gnu.so",
                },
                .musl => &.{
                    "libvesti_tectonic.so",
                    "libvesti_tectonic_x86_64_musl.so",
                }, // TODO: compile prebuilt dll
                else => blk: {
                    std.debug.print(
                        "Not supported for abi {} on Linux x86_64",
                        .{abi_tag},
                    );
                    break :blk error.NotSupport;
                },
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

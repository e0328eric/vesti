const std = @import("std");
const builtin = @import("builtin");
const path = std.fs.path;

const Allocator = std.mem.Allocator;

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
    const no_cargo_vcpkg = b.option(
        bool,
        "no-cargo-vcpkg",
        "compile vesti_tectonic dll without using cargo-vcpkg",
    ) orelse false; // use cargo-vcpkg in default

    //          ╭─────────────────────────────────────────────────────────╮
    //          │                       Build Step                        │
    //          ╰─────────────────────────────────────────────────────────╯
    const exe = try buildVesti(b, target, optimize, .exe);
    const install_dll = try addInstallDll(b, target, .bin);
    b.getInstallStep().dependOn(&install_dll.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const build_rust_cmd = b.step("rust", "Build vesti-tectonic rust code");
    try addBuildRust(b, build_rust_cmd, target, macos_sdk_path, no_cargo_vcpkg);

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

        // since this is a build script, leaking memories are safe
        const release_dir: Build.InstallDir = .{
            .custom = try t.zigTriple(b.allocator),
        };

        const target_output = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = release_dir },
        });
        release_step.dependOn(&target_output.step);

        const release_install_dll = try addInstallDll(b, cross_target, release_dir);
        release_step.dependOn(&release_install_dll.step);
    }
}

fn buildVesti(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    comptime build_mode: enum(u1) { exe, @"test" },
) !*Build.Step.Compile {
    const strip = switch (optimize) {
        .debug, .safe => false,
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

/// Builds the vesti-tectonic dynamic library with cargo, copies it into
/// `vesti-tectonic/bin` and compresses it with upx.
///
/// Zig 0.17 no longer supports custom build steps, so this is expressed as a
/// chain of `Run` and `UpdateSourceFiles` steps.
fn addBuildRust(
    b: *Build,
    parent_step: *Build.Step,
    target: Build.ResolvedTarget,
    macos_sdk_path: ?[]const u8,
    no_cargo_vcpkg: bool,
) !void {
    const target_string = getRustTarget(&target) catch |err| switch (err) {
        error.NotSupport => {
            const fail = b.addFail(b.fmt(
                "building vesti-tectonic is not supported for {s}",
                .{try target.result.zigTriple(b.allocator)},
            ));
            parent_step.dependOn(&fail.step);
            return;
        },
    };

    var env: std.process.Environ.Map = .init(b.allocator);
    switch (target.result.os.tag) {
        .windows => {
            if (!no_cargo_vcpkg) {
                try env.put("VCPKG_ROOT", try vcpkgRoot(b));
            }
            try env.put("TECTONIC_DEP_BACKEND", "vcpkg");
            try env.put("VCPKGRS_TRIPLET", "x64-windows-static-release");
            try env.put("RUSTFLAGS", "-Ctarget-feature=+crt-static");
        },
        .macos => {
            // such setting is need when one compile macos dylib on either linux
            // or windows
            if (builtin.os.tag != .macos) {
                configureMacosRustEnv(b, &env, &target, macos_sdk_path) catch |err| {
                    const fail = b.addFail(switch (err) {
                        error.MissingMacosSdk =>
                        \\Missing MacOSX.sdk for macOS Rust/vcpkg build.
                        \\Pass -Dmacos-sdk=PATH, or set SDKROOT/MACOSX_SDK in the environment.
                        ,
                        else => b.fmt("failed to configure macOS rust environment: {t}", .{err}),
                    });
                    parent_step.dependOn(&fail.step);
                    return;
                };
            }

            // on macos, additional configuration is not needed
        },
        else => {},
    }

    const tectonic_dir = b.path("vesti-tectonic");
    var last_step: ?*Build.Step = null;

    if (!no_cargo_vcpkg) {
        const vcpkg = b.addSystemCommand(&.{ "cargo", "vcpkg", "-v", "build", "--target", target_string });
        vcpkg.setName("cargo vcpkg build");
        vcpkg.setCwd(tectonic_dir);
        setRunEnv(vcpkg, &env);
        last_step = &vcpkg.step;
    }

    const cargo_argv: []const []const u8 = switch (target.result.os.tag) {
        .macos => if (builtin.os.tag == .macos)
            &.{ "cargo", "build", "--release", "--target", target_string }
        else
            &.{ "cargo", "zigbuild", "--release", "--target", target_string },
        else => &.{ "cargo", "build", "--release", "--target", target_string },
    };
    const cargo = b.addSystemCommand(cargo_argv);
    cargo.setName("cargo build");
    cargo.setCwd(tectonic_dir);
    setRunEnv(cargo, &env);
    if (last_step) |step| cargo.step.dependOn(step);

    // copy the compiled dll into vesti-tectonic/bin
    const name = try getDllName(&target);
    const copy_dll = b.addUpdateSourceFiles();
    copy_dll.addCopyFileToSource(
        b.path(b.pathJoin(&.{ "vesti-tectonic/target", target_string, "release", name[0] })),
        b.pathJoin(&.{ "vesti-tectonic/bin", name[1] }),
    );
    copy_dll.step.dependOn(&cargo.step);

    // compress binary using upx (only for dll)
    switch (target.result.os.tag) {
        .windows, .linux => {
            const upx = b.addSystemCommand(&.{ "upx", "-9", b.pathJoin(&.{ "bin", name[1] }) });
            upx.setCwd(tectonic_dir);
            setRunEnv(upx, &env);
            upx.step.dependOn(&copy_dll.step);
            parent_step.dependOn(&upx.step);
        },
        else => parent_step.dependOn(&copy_dll.step),
    }
}

fn setRunEnv(run: *Build.Step.Run, env: *const std.process.Environ.Map) void {
    var it = env.iterator();
    while (it.next()) |entry| {
        run.setEnvironmentVariable(entry.key_ptr.*, entry.value_ptr.*);
    }
}

/// Absolute path of the directory containing this build.zig.
fn buildRootPath(b: *Build) ![]const u8 {
    return b.root.root_dir.handle.realPathFileAlloc(
        b.graph.io,
        if (b.root.sub_path.len == 0) "." else b.root.sub_path,
        b.allocator,
    );
}

fn vcpkgRoot(b: *Build) ![]const u8 {
    return path.join(b.allocator, &.{
        try buildRootPath(b),
        "vesti-tectonic/target/vcpkg",
    });
}

fn getRustTarget(target: *const Build.ResolvedTarget) error{NotSupport}![]const u8 {
    const os_tag = target.result.os.tag;
    const cpu_arch_tag = target.result.cpu.arch;
    const abi_tag = target.result.abi;

    return switch (os_tag) {
        .windows => switch (cpu_arch_tag) {
            // Do we need musl on windows?
            .x86_64 => "x86_64-pc-windows-msvc",
            .aarch64 => "aarch64-pc-windows-msvc",
            else => error.NotSupport,
        },
        .linux => switch (cpu_arch_tag) {
            .x86_64 => switch (abi_tag) {
                .gnu => "x86_64-unknown-linux-gnu",
                .musl => "x86_64-unknown-linux-musl",
                else => error.NotSupport,
            },
            .x86 => "i686-unknwon-linux-gnu",
            .aarch64 => "aarch64_be-unknown-linux-gnu",
            .arm => "arm-unknown-linux-gnueabi",
            else => error.NotSupport,
        },
        .macos => switch (cpu_arch_tag) {
            .aarch64 => "aarch64-apple-darwin",
            else => error.NotSupport,
        },
        else => error.NotSupport,
    };
}

fn configureMacosRustEnv(
    b: *Build,
    envmap: *std.process.Environ.Map,
    target: *const Build.ResolvedTarget,
    macos_sdk_path: ?[]const u8,
) !void {
    const alloc = b.allocator;
    const host_env = &b.graph.environ_map;

    const triplet = switch (target.result.cpu.arch) {
        .aarch64 => "arm64-osx-zig",
        else => return error.NotSupport,
    };

    try envmap.put("TECTONIC_DEP_BACKEND", "vcpkg");
    try envmap.put("VCPKG_ROOT", try vcpkgRoot(b));
    try envmap.put("VCPKGRS_TRIPLET", triplet);
    try envmap.put("MACOSX_DEPLOYMENT_TARGET", "13.0");

    if (host_env.get("ZIG") == null) {
        try envmap.put("ZIG", b.graph.zig_exe);
    }

    if (host_env.get("ZIG_LIBC_INCLUDE") == null) {
        const zig_libc_include = try path.join(alloc, &.{
            try zigLibDir(b),
            "libc",
            "include",
        });
        try envmap.put("ZIG_LIBC_INCLUDE", zig_libc_include);
    }

    if (host_env.get("ZIG_GLOBAL_CACHE_DIR") == null) {
        const zig_global_cache_dir = try path.join(alloc, &.{
            try buildRootPath(b),
            ".zig-global-cache",
        });
        try envmap.put("ZIG_GLOBAL_CACHE_DIR", zig_global_cache_dir);
    }

    if (macos_sdk_path) |sdk_path| {
        try putMacosSdkEnv(alloc, envmap, sdk_path);
        return;
    }

    if (host_env.get("SDKROOT")) |sdk_path| {
        try putMacosSdkEnv(alloc, envmap, sdk_path);
        return;
    }

    if (host_env.get("MACOSX_SDK")) |sdk_path| {
        try putMacosSdkEnv(alloc, envmap, sdk_path);
        return;
    }

    return error.MissingMacosSdk;
}

/// Asks the running zig executable where its lib directory is.
/// (`std.Build.Graph` no longer exposes it as a string.)
fn zigLibDir(b: *Build) ![]const u8 {
    const env_out = b.run(&.{ b.graph.zig_exe, "env" });
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const ZigEnv = struct { lib_dir: []const u8 };
    const zig_env = std.zon.parse.fromSlice(ZigEnv, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = try b.allocator.dupeSentinel(u8, env_out, 0),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("failed to parse the output of `zig env`: {t}\n", .{err});
        return err;
    };
    return zig_env.lib_dir;
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

/// Installs the prebuilt vesti-tectonic dll into `install_dir`.
fn addInstallDll(
    b: *Build,
    target: Build.ResolvedTarget,
    install_dir: Build.InstallDir,
) !*Build.Step.InstallFile {
    const dll_name = try getDllName(&target);
    return b.addInstallFileWithDir(
        b.path(b.pathJoin(&.{ "vesti-tectonic/bin", dll_name[1] })),
        install_dir,
        dll_name[1],
    );
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
                    "Not supported for cpu architecture {t} on Windows",
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
                        "Not supported for abi {t} on Linux x86_64",
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
                    "Not supported for cpu architecture {t} on Linux",
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

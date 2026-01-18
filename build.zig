const std = @import("std");
const builtin = @import("builtin");
const path = std.fs.path;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Sha3 = std.crypto.hash.sha3.Sha3_512;

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

    const tectonic_static = b.option(
        bool,
        "static",
        "link tectonic statically",
    ) orelse false;

    //          ╭─────────────────────────────────────────────────────────╮
    //          │                       Build Step                        │
    //          ╰─────────────────────────────────────────────────────────╯
    // vesti-toolkit module
    _ = try buildVesti(b, target, optimize, .mod, tectonic_static);

    const exe = try buildVesti(b, target, optimize, .exe, tectonic_static);
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
    const exe_unit_tests = try buildVesti(
        b,
        target,
        optimize,
        .@"test",
        tectonic_static,
    );
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
        const release_exe = try buildVesti(
            b,
            cross_target,
            optimize,
            .exe,
            tectonic_static,
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
    comptime build_mode: enum(u2) { mod, exe, @"test" },
    tectonic_static: bool,
) !switch (build_mode) {
    .mod => *Build.Module,
    else => *Build.Step.Compile,
} {
    const strip = switch (optimize) {
        .Debug => false,
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
    const tectonic_dll_name = try getDllName(&target);
    const tectonic_dll_hash = try calculateDllHash(b.allocator, b.graph.io, tectonic_dll_name[1]);
    const vesti_opt = b.addOptions();
    vesti_opt.addOption(@TypeOf(VESTI_VERSION), "VESTI_VERSION", VESTI_VERSION);
    vesti_opt.addOption([]const u8, "VESTI_DUMMY_DIR", VESTI_DUMMY_DIR);
    vesti_opt.addOption([]const u8, "TECTONIC_DLL", tectonic_dll_name[1]);
    vesti_opt.addOption(u512, "TECTONIC_DLL_HASH", tectonic_dll_hash);
    vesti_opt.addOption(bool, "TECTONIC_STATIC", tectonic_static);

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
            if (!tectonic_static) {
                switch (target.result.os.tag) {
                    .linux => exe_mod.addRPath(.{ .cwd_relative = "$ORIGIN" }),
                    .macos => exe_mod.addRPath(.{ .cwd_relative = "@executable_path" }),
                    .windows => {}, // windows does not use rpath
                    else => @panic("Non supported OS"),
                }
            }
            exe_mod.addOptions("vesti-info", vesti_opt);

            // TODO: link static library
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

    var tectonic_dir = try b.build_root.handle.openDir(io, "./vesti-tectonic", .{});
    defer tectonic_dir.close(io);
    try std.process.setCurrentDir(io, tectonic_dir);
    defer std.process.setCurrentDir(io, b.build_root.handle) catch unreachable;

    var vcpkg_child = try std.process.spawn(io, .{
        .argv = &.{ "cargo", "vcpkg", "build" },
        .environ_map = &envmap,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer vcpkg_child.kill(io);

    var vcpkg_result_stdout: ArrayList(u8) = .empty;
    var vcpkg_result_stderr: ArrayList(u8) = .empty;
    defer {
        vcpkg_result_stdout.deinit(alloc);
        vcpkg_result_stderr.deinit(alloc);
    }
    try vcpkg_child.collectOutput(
        alloc,
        &vcpkg_result_stdout,
        &vcpkg_result_stderr,
        2500 * 1024,
    );
    _ = try vcpkg_child.wait(io);
    std.debug.print("stdout: {s}\n\nstderr: {s}\n", .{
        vcpkg_result_stdout.items,
        vcpkg_result_stderr.items,
    });

    var cargo_child = try std.process.spawn(io, .{
        .argv = &.{ "cargo", "build", "--release" },
        .environ_map = &envmap,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer cargo_child.kill(io);

    var cargo_result_stdout: ArrayList(u8) = .empty;
    var cargo_result_stderr: ArrayList(u8) = .empty;
    defer {
        cargo_result_stdout.deinit(alloc);
        cargo_result_stderr.deinit(alloc);
    }
    try cargo_child.collectOutput(
        alloc,
        &cargo_result_stdout,
        &cargo_result_stderr,
        2500 * 1024,
    );
    _ = try cargo_child.wait(io);
    std.debug.print("stdout: {s}\n\nstderr: {s}\n", .{
        cargo_result_stdout.items,
        cargo_result_stderr.items,
    });

    try getTectonic(b, alloc, io, build_rust, &envmap, .lib);
    try getTectonic(b, alloc, io, build_rust, &envmap, .dll);
}

fn getTectonic(
    b: *Build,
    alloc: Allocator,
    io: Io,
    build_rust: *BuildRust,
    envmap: *std.process.Environ.Map,
    comptime ty: enum(u1) { lib, dll },
) !void {
    const name = switch (ty) {
        .lib => try getLibName(&build_rust.target),
        .dll => try getDllName(&build_rust.target),
    };
    const source_path = try path.join(alloc, &.{
        "vesti-tectonic/target/release/",
        name[0],
    });
    defer alloc.free(source_path);

    const dest_path = try path.join(alloc, &.{
        switch (ty) {
            .lib => "vesti-tectonic/lib/",
            .dll => "vesti-tectonic/bin/",
        },
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

    if (ty == .dll) {
        const dll_path = try path.join(alloc, &.{
            "bin/",
            name[1],
        });
        errdefer alloc.free(dll_path);

        // compress binary using upx (only for dll)
        switch (build_rust.target.result.os.tag) {
            .windows, .linux => {
                var upx_child = try std.process.spawn(io, .{
                    .argv = &.{ "upx", "-9", dll_path },
                    .environ_map = envmap,
                    .stdout = .pipe,
                    .stderr = .pipe,
                });
                errdefer upx_child.kill(io);

                var upx_stdout: ArrayList(u8) = .empty;
                var upx_stderr: ArrayList(u8) = .empty;
                defer {
                    upx_stdout.deinit(alloc);
                    upx_stderr.deinit(alloc);
                }
                try upx_child.collectOutput(
                    alloc,
                    &upx_stdout,
                    &upx_stderr,
                    2500 * 1024,
                );
                _ = try upx_child.wait(io);
                std.debug.print("stdout: {s}\n\nstderr: {s}\n", .{
                    upx_stdout.items,
                    upx_stderr.items,
                });
            },
            else => {},
        }
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
    const source_path = try b.build_root.handle.realPathFileAlloc(io, source_path_rel, alloc);
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

fn getLibName(target: *const Build.ResolvedTarget) error{NotSupport}![]const []const u8 {
    const os_tag = target.result.os.tag;
    const cpu_arch_tag = target.result.cpu.arch;

    return switch (os_tag) {
        .windows => switch (cpu_arch_tag) {
            .x86_64 => &.{
                "vesti_tectonic.lib",
                "vesti_tectonic_x86_64.lib",
            },
            .aarch64 => &.{
                "vesti_tectonic.lib",
                "vesti_tectonic_aarch64.lib",
            }, // TODO: compile prebuilt lib
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
                "libvesti_tectonic.a",
                "libvesti_tectonic_x86_64.a",
            },
            .x86 => &.{
                "libvesti_tectonic.a",
                "libvesti_tectonic_x86.a",
            }, // TODO: compile prebuilt lib
            .aarch64 => &.{
                "libvesti_tectonic.a",
                "libvesti_tectonic_aarch64.a",
            }, // TODO: compile prebuilt lib
            .arm => &.{
                "libvesti_tectonic.a",
                "libvesti_tectonic_arm.a",
            }, // TODO: compile prebuilt lib
            else => blk: {
                std.debug.print(
                    "Not supported for cpu architecture {} on Linux",
                    .{cpu_arch_tag},
                );
                break :blk error.NotSupport;
            },
        },
        .macos => { // switch (cpu_arch_tag) {
            std.debug.print(
                "Not supported for MacOS",
                .{},
            );
            return error.NotSupport;
            //.aarch64 => &.{
            //    "libvesti_tectonic.dylib",
            //    "libvesti_tectonic.dylib",
            //},
            //else => blk: {
            //    std.debug.print("Only arm MacOS is supported", .{});
            //    break :blk error.NotSupport;
            //},
        },
        else => @panic("Not supported"),
    };
}

fn calculateDllHash(allocator: Allocator, io: Io, tectonic_dll_name: []const u8) !u512 {
    const dll_path = try path.join(allocator, &.{
        "./vesti-tectonic/bin/",
        tectonic_dll_name,
    });
    defer allocator.free(dll_path);

    var dll = Io.Dir.cwd().openFile(io, dll_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0, // zig build rust will make a dll
        else => return err,
    };
    defer dll.close(io);
    var dll_read_buf: [4096]u8 = undefined;
    var dll_reader = dll.reader(io, &dll_read_buf);

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

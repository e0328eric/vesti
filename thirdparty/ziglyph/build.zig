const std = @import("std");
const builtin = @import("builtin");

const UNICODE_VERSION = "16.0.0";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // Export module
    _ = b.addModule("ziglyph", .{ .root_source_file = b.path("src/ziglyph.zig") });
    const ziglyph_opt = b.addOptions();
    ziglyph_opt.addOption([]const u8, "UNICODE_VERSION", UNICODE_VERSION);

    // Fetch Unicode files step.
    const fetch_exe = b.addExecutable(.{
        .name = "fetch_unicode_files",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fetch_unicode_files.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fetch_exe.root_module.addOptions("unicode", ziglyph_opt);

    const run_fetch_exe = b.addRunArtifact(fetch_exe);
    run_fetch_exe.setCwd(b.path("."));
    run_fetch_exe.step.dependOn(&fetch_exe.step);
    if (b.args) |args| run_fetch_exe.addArgs(args);

    const fetch_step = b.step("fetch", "Fetch Unicode files from the Internet.");
    fetch_step.dependOn(&run_fetch_exe.step);

    // Generate Zig files step.
    const gen_exe = b.addExecutable(.{
        .name = "gen_zig_code",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_zig_code.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gen_exe.root_module.addOptions("unicode", ziglyph_opt);
    gen_exe.step.dependOn(&run_fetch_exe.step);

    const run_gen_exe = b.addRunArtifact(gen_exe);
    run_gen_exe.setCwd(b.path("."));
    run_gen_exe.step.dependOn(&gen_exe.step);
    if (b.args) |args| run_gen_exe.addArgs(args);

    // Fmt step
    const gen_fmt = b.addFmt(.{ .paths = &.{"src"} });
    gen_fmt.step.dependOn(&run_gen_exe.step);

    const gen_step = b.step("gen", "Generate Zig code from Unicode files.");
    gen_step.dependOn(&gen_fmt.step);

    // Main tests
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Main tests run step
    const run_main_tests = b.addRunArtifact(main_tests);
    // Main tests top level step
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    // Internal tests
    const unicode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Main tests run step
    const run_unicode_tests = b.addRunArtifact(unicode_tests);
    // Main tests top level step
    const unicode_test_step = b.step("unicode-test", "Run Unicode tests.");
    unicode_test_step.dependOn(&run_unicode_tests.step);

    // allkeys.txt compression
    const ak_exe = b.addExecutable(.{
        .name = "compress_allkeys",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/akcompress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_ak_exe = b.addRunArtifact(ak_exe);
    run_ak_exe.setCwd(b.path("."));
    run_ak_exe.step.dependOn(&ak_exe.step);
    if (b.args) |args| run_ak_exe.addArgs(args);

    const ak_step = b.step("akcompress", "Compress tailored allkeys.txt file.");
    ak_step.dependOn(&run_ak_exe.step);
}

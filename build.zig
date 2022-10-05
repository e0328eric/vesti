const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const strip = b.option(bool, "strip", "Omit debug information") orelse false;

    b.install_path = "~/.local/bin";

    const ziglyph_pkg = std.build.Pkg{
        .name = "ziglyph",
        .source = .{ .path = "libs/ziglyph/src/ziglyph.zig" },
    };

    const exe = b.addExecutable("vesti", "src/main.zig");
    exe.strip = strip;
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addCSourceFile("libs/drapeau/drapeau.c", &[_][]const u8{"-std=c11"});
    exe.addPackage(ziglyph_pkg);
    exe.addIncludePath("libs/drapeau");
    exe.linkSystemLibrary("c");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("test/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);
    exe_tests.addPackage(.{
        .name = "vesti_test",
        .source = .{ .path = "src/tests.zig" },
        .dependencies = &.{ziglyph_pkg},
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

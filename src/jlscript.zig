const std = @import("std");
const fs = std.fs;
const diag = @import("diagnostic.zig");

const Allocator = std.mem.Allocator;
const Julia = @import("julia/Julia.zig");
const LatexEngine = @import("parser/Parser.zig").LatexEngine;

pub fn getBuildJlContents(
    allocator: Allocator,
    jlcode_path: []const u8,
    diagnostic: *diag.Diagnostic,
) !?[]const u8 {
    const jlcode_file = fs.cwd().openFile(jlcode_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            const io_diag = try diag.IODiagnostic.init(
                diagnostic.allocator,
                null,
                "failed to read {s}",
                .{jlcode_path},
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileVesFailed;
        },
    };
    defer jlcode_file.close();

    var buf: [1024]u8 = undefined;
    var buf_reader = jlcode_file.reader(&buf);
    const reader = &buf_reader.interface;

    const jlcode_contents = try reader.allocRemaining(allocator, .unlimited);
    return jlcode_contents;
}

pub fn runJlCode(
    julia: *Julia,
    diagnostic: *diag.Diagnostic,
    jlcode_contents: []const u8,
    filename: []const u8,
) !void {
    julia.runJlCode(jlcode_contents, false, filename) catch |err| switch (err) {
        error.JlEvalFailed => {
            const jl_runtime_err = try diag.ParseDiagnostic.jlEvalFailed(
                diagnostic.allocator,
                null,
                "failed to run jlcode",
                .{},
                "see above julia error message",
            );
            diagnostic.initDiagInner(.{ .ParseError = jl_runtime_err });
            return error.JlEvalFailed;
        },
        else => return err,
    };
}

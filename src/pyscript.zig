const std = @import("std");
const fs = std.fs;
const diag = @import("./diagnostic.zig");

const Allocator = std.mem.Allocator;
const Python = @import("./Python.zig");
const LatexEngine = @import("./parser/Parser.zig").LatexEngine;

pub fn getBuildPyContents(
    allocator: Allocator,
    pycode_path: []const u8,
    diagnostic: *diag.Diagnostic,
) !?[:0]const u8 {
    const pycode_file = fs.cwd().openFile(pycode_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            const io_diag = try diag.IODiagnostic.init(
                diagnostic.allocator,
                null,
                "failed to read {s}",
                .{pycode_path},
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileVesFailed;
        },
    };
    defer pycode_file.close();

    var buf: [1024]u8 = undefined;
    var buf_reader = pycode_file.reader(&buf);
    const reader = &buf_reader.interface;

    const pycode_contents = try reader.allocRemainingAlignedSentinel(
        allocator,
        .unlimited,
        .of(u8),
        0,
    );

    return pycode_contents;
}

pub fn runPyCode(
    allocator: Allocator,
    diagnostic: *diag.Diagnostic,
    engine: LatexEngine,
    pycode_contents: [:0]const u8,
) !void {
    var py = Python.init(engine) catch {
        const io_diag = try diag.IODiagnostic.init(
            allocator,
            null,
            "failed to initialize python vm",
            .{},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.PyInitFailed;
    };
    defer py.deinit();

    if (!py.runPyCode(pycode_contents, false)) {
        const py_runtime_err = try diag.ParseDiagnostic.pyEvalFailed(
            diagnostic.allocator,
            null,
            "vesti library in python emits an error",
            .{},
            "see above python error message",
        );
        diagnostic.initDiagInner(.{ .ParseError = py_runtime_err });
        return error.PyEvalFailed;
    }
}

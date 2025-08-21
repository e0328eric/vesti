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

    const pycode_contents = try pycode_file.readToEndAllocOptions(
        allocator,
        std.math.maxInt(usize),
        null,
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

    if (!py.runPyCode(pycode_contents)) {
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

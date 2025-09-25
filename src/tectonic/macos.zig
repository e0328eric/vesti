const std = @import("std");
const fs = std.fs;
const diag = @import("../diagnostic.zig");

const DynLib = std.DynLib;
const TectonicFnt = *const fn ([*]const u8, usize, [*]const u8, usize, usize) callconv(.c) bool;

const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;

pub fn compileLatexWithTectonic(
    diagnostic: *diag.Diagnostic,
    main_tex_file: []const u8,
    vesti_dummy: *fs.Dir,
    compile_limit: usize,
) !void {
    var tectonic_dll = try DynLib.open("libvesti_tectonic.dylib");
    defer tectonic_dll.close();

    const compile_latex_with_tectonic = tectonic_dll.lookup(
        TectonicFnt,
        "compile_latex_with_tectonic",
    );

    var curr_dir = try fs.cwd().openDir(".", .{});
    defer curr_dir.close();
    try vesti_dummy.setAsCwd();
    defer curr_dir.setAsCwd() catch @panic("failed to recover cwd");

    if (compile_latex_with_tectonic) |fnt| {
        if (!fnt(
            main_tex_file.ptr,
            main_tex_file.len,
            @ptrCast(VESTI_DUMMY_DIR),
            VESTI_DUMMY_DIR.len,
            compile_limit,
        )) {
            const io_diag = try diag.IODiagnostic.initWithNote(
                diagnostic.allocator,
                null,
                "tectonic gaves an error while processing",
                .{},
                "",
                .{},
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.CompileLatexFailed;
        }
    } else return error.FindTectonicFunctionFailed;
}

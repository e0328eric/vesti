const std = @import("std");
const fs = std.fs;
const diag = @import("../diagnostic.zig");

const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;

extern fn compile_latex_with_tectonic(
    latex_filename_ptr: [*]const u8,
    latex_filename_len: usize,
    vesti_local_dummy_dir_ptr: [*]const u8,
    vesti_local_dummy_dir_len: usize,
    compile_limit: usize,
) bool;

pub fn compileLatexWithTectonic(
    diagnostic: *diag.Diagnostic,
    main_tex_file: []const u8,
    vesti_dummy: *fs.Dir,
    compile_limit: usize,
) !void {
    var curr_dir = try fs.cwd().openDir(".", .{});
    defer curr_dir.close();
    try vesti_dummy.setAsCwd();
    defer curr_dir.setAsCwd() catch @panic("failed to recover cwd");

    if (!compile_latex_with_tectonic(
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
}

const std = @import("std");
const diag = @import("diagnostic.zig");
const zlap = @import("zlap");

const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const Compiler = @import("Compiler.zig");
const CompileAttribute = Compiler.CompileAttribute;
const Diagnostic = diag.Diagnostic;
const EnvMap = std.process.Environ.Map;
const Io = std.Io;
const Preprocessor = @import("parser/Preprocessor.zig");

pub fn experimentalStep(
    allocator: Allocator,
    io: Io,
    env_map: *const EnvMap,
    diagnostic: *Diagnostic,
    experimental_subcmd: *const zlap.Subcmd,
) !void {
    _ = env_map;

    const filename = experimental_subcmd.args.get("FILENAME").?.value.string;

    var vesti_file = Io.Dir.cwd().openFile(io, filename, .{}) catch |err| {
        const io_diag = try diag.IODiagnostic.init(
            diagnostic.allocator,
            null,
            "failed to open file `{s}`",
            .{filename},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return err;
    };
    defer vesti_file.close(io);

    var buf: [1024]u8 = undefined;
    var vesti_file_reader = vesti_file.reader(io, &buf);

    const source = vesti_file_reader.interface.allocRemaining(allocator, .unlimited) catch {
        const io_diag = try diag.IODiagnostic.init(
            diagnostic.allocator,
            null,
            "failed to read from {s}",
            .{filename},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.CompileVesFailed;
    };
    defer allocator.free(source);

    var preprocessor = try Preprocessor.init(allocator, diagnostic, source);
    defer preprocessor.deinit();
    var tokens = preprocessor.preprocess() catch |err| {
        try diagnostic.initMetadataAlloc(filename, source);
        return err;
    };
    defer tokens.deinit(allocator);

    for (0..tokens.inner.len) |i| {
        std.debug.print("Token: {f}\n", .{tokens.get(i)});
    }
}

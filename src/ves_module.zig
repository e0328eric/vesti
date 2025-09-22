const std = @import("std");
const fs = std.fs;
const diag = @import("diagnostic.zig");
const zon = std.zon;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Span = @import("location.zig").Span;

const getConfigPath = @import("Config.zig").getConfigPath;

const VESTI_DUMMY_DIR = @import("vesti-info").VESTI_DUMMY_DIR;

pub const VestiModule = struct {
    name: []const u8,
    version: ?[]const u8,
    exports: []const struct {
        name: []const u8,
        location: ?[]const u8 = null,
    },
};

pub fn downloadModule(
    allocator: Allocator,
    diagnostic: *diag.Diagnostic,
    mod_name: []const u8,
    import_file_loc: ?Span,
) !void {
    var mod_dir_path = try ArrayList(u8).initCapacity(allocator, 30);
    defer mod_dir_path.deinit(allocator);

    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    try mod_dir_path.print(allocator, "{s}/{s}", .{ config_path, mod_name });

    var mod_data_path = try ArrayList(u8).initCapacity(
        allocator,
        mod_dir_path.items.len + 15,
    );
    defer mod_data_path.deinit(allocator);
    try mod_data_path.print(allocator, "{s}/vesti.zon", .{mod_dir_path.items});

    var mod_zon_file = fs.cwd().openFile(mod_data_path.items, .{}) catch {
        const io_diag = try diag.IODiagnostic.init(
            allocator,
            import_file_loc,
            "cannot open file {s}",
            .{
                mod_data_path.items,
            },
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.FailedGetModule;
    };
    defer mod_zon_file.close();

    var buf: [1024]u8 = undefined;
    var mod_zon_file_reader = mod_zon_file.reader(&buf);

    // what kind of such simple config file has 4MB size?
    const context = mod_zon_file_reader.interface.allocRemainingAlignedSentinel(
        allocator,
        .limited(4 * 1024 * 1024),
        .of(u8),
        0,
    ) catch {
        const io_diag = try diag.IODiagnostic.init(
            allocator,
            import_file_loc,
            "cannot read context from {s}",
            .{
                mod_data_path.items,
            },
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.FailedGetModule;
    };
    defer allocator.free(context);
    const ves_module = try zon.parse.fromSliceAlloc(
        VestiModule,
        allocator,
        context,
        null,
        .{},
    );
    defer zon.parse.free(allocator, ves_module);

    for (ves_module.exports) |@"export"| {
        var mod_filename = try ArrayList(u8).initCapacity(
            allocator,
            @"export".name.len + mod_dir_path.items.len,
        );
        defer mod_filename.deinit(allocator);
        try mod_filename.print(
            allocator,
            "{s}/{s}",
            .{ mod_dir_path.items, @"export".name },
        );

        const location = @"export".location orelse VESTI_DUMMY_DIR;
        var into_copy_filename = try ArrayList(u8).initCapacity(
            allocator,
            @"export".name.len + location.len,
        );
        defer into_copy_filename.deinit(allocator);
        try into_copy_filename.print(
            allocator,
            "{s}/{s}",
            .{ location, @"export".name },
        );

        fs.cwd().copyFile(
            mod_filename.items,
            fs.cwd(),
            into_copy_filename.items,
            .{},
        ) catch {
            const io_diag = try diag.IODiagnostic.init(
                allocator,
                import_file_loc,
                "cannot copy from {s} into {s}",
                .{
                    mod_filename.items,
                    into_copy_filename.items,
                },
            );
            diagnostic.initDiagInner(.{ .IOError = io_diag });
            return error.FailedGetModule;
        };
    }
}

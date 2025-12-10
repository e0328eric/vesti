const std = @import("std");
const builtin = @import("builtin");
const diag = @import("diagnostic.zig");
const fs = std.fs;
const process = std.process;
const zon = std.zon;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Diagnostic = diag.Diagnostic;
const Io = std.Io;
const LatexEngine = @import("parser/Parser.zig").LatexEngine;

engine: LatexEngine = .tectonic,
lua: struct {
    make_log: bool = false,
    line_limit: usize = 45,
} = .{},

const Self = @This();

pub fn init(allocator: Allocator, diagnostic: *Diagnostic) !Self {
    const config_dir_path = try getConfigPath(allocator);
    defer allocator.free(config_dir_path);

    const config_path = try fs.path.join(allocator, &.{
        config_dir_path,
        "config.zon",
    });
    defer allocator.free(config_path);

    var config_zon = fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer config_zon.close();

    var buf: [1024]u8 = undefined;
    var config_zon_reader = config_zon.reader(&buf);

    // what kind of such simple config file has 4MB size?
    // TODO: if 0.16.0 is finalized, replace this code with the following
    //
    //config_zon_reader.interface.allocRemainingAlignedSentinel(
    //  allocator,
    //  .limited(4 * 1024 * 1024),
    //  .of(u8),
    //  0,
    //)
    const context = blk: {
        const reader = &config_zon_reader.interface;
        var tmp = Io.Writer.Allocating.init(allocator);
        defer tmp.deinit();

        var remaining: Io.Limit = .limited(4 * 1024 * 1024);
        while (remaining.nonzero()) {
            const n = Io.Reader.stream(reader, &tmp.writer, remaining) catch |err| switch (err) {
                error.EndOfStream => break :blk try tmp.toOwnedSliceSentinel(0),
                error.WriteFailed => break :blk error.OutOfMemory,
                error.ReadFailed => break :blk error.ReadFailed,
            };
            remaining = remaining.subtract(n).?;
        }
        break :blk error.StreamTooLong;
    } catch {
        const io_diag = try diag.IODiagnostic.init(
            allocator,
            null,
            "cannot read context from {s}",
            .{config_path},
        );
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.FailedOpenConfig;
    };
    defer allocator.free(context);

    return zon.parse.fromSlice(
        Self,
        allocator,
        context,
        null,
        .{},
    ) catch |err| {
        const io_diag = switch (err) {
            error.ParseZon => try diag.IODiagnostic.init(
                allocator,
                null,
                "invalid config.ves format",
                .{},
            ),
            else => return err, // OOM
        };
        diagnostic.initDiagInner(.{ .IOError = io_diag });
        return error.FailedOpenConfig;
    };
}

pub fn deinit(self: Self, allocator: Allocator) void {
    zon.parse.free(allocator, self);
}

pub fn getConfigPath(allocator: Allocator) ![]const u8 {
    var output = try ArrayList(u8).initCapacity(allocator, 30);
    errdefer output.deinit(allocator);

    switch (builtin.os.tag) {
        .linux, .macos => {
            try output.appendSlice(allocator, std.posix.getenv("HOME").?);
            try output.appendSlice(allocator, "/.config/vesti");
        },
        .windows => {
            const appdata_location = try process.getEnvVarOwned(
                allocator,
                "APPDATA",
            );
            defer allocator.free(appdata_location);
            try output.appendSlice(allocator, appdata_location);
            try output.appendSlice(allocator, "\\vesti");
        },
        else => @compileError("only linux, macos and windows are supported"),
    }

    return try output.toOwnedSlice(allocator);
}

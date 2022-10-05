const std = @import("std");
const codegen = @import("codegen.zig");
const diagonosis = @import("diagonosis.zig");
const mem = std.mem;

const print = std.debug.print;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const FileInfo = @import("FileInfo.zig");
const Thread = std.Thread;
const Parser = @import("Parser.zig");

pub fn compile(
    comptime is_continuous: bool,
    input_filenames: [][]const u8,
    keep_running: *bool,
    alloc: Allocator,
) !void {
    var threads = ArrayList(Thread).init(alloc);
    defer threads.deinit();
    var file_info_containers = ArrayList(FileInfo).init(alloc);
    defer {
        for (file_info_containers.items) |file_info| {
            file_info.deinit();
        }
        file_info_containers.deinit();
    }

    for (input_filenames) |input_filename| {
        const input_file_kind = blk: {
            var input_file = try std.fs.cwd().openFile(input_filename, .{});
            defer input_file.close();
            const metadata = try input_file.metadata();
            break :blk metadata.kind();
        };

        switch (input_file_kind) {
            .File => {
                const thread = try if (is_continuous) std.Thread.spawn(
                    .{},
                    compileVestiMultiple,
                    .{
                        input_filename,
                        keep_running,
                        alloc,
                    },
                ) else std.Thread.spawn(
                    .{},
                    compileVestiOnce,
                    .{ input_filename, alloc },
                );
                try threads.append(thread);
            },
            .Directory => {
                var file_info = try FileInfo.init(input_filename, alloc);
                try file_info_containers.append(file_info);

                for (file_info.file_info.items) |filename| {
                    const thread = try if (is_continuous) std.Thread.spawn(
                        .{},
                        compileVestiMultiple,
                        .{
                            filename.filename,
                            keep_running,
                            alloc,
                        },
                    ) else std.Thread.spawn(
                        .{},
                        compileVestiOnce,
                        .{ filename.filename, alloc },
                    );
                    try threads.append(thread);
                }
            },
            else => {
                print(
                    "{s}ERROR: {s}invalid file/directory was found\n",
                    .{ diagonosis.err_color, diagonosis.reset_color },
                );
                return;
            },
        }
    }

    for (threads.items) |thread| {
        thread.join();
    }
}

fn compileVestiMultiple(
    input_filename: []const u8,
    keep_running: *bool,
    alloc: Allocator,
) !void {
    var init_modified = blk: {
        const input_file = try std.fs.cwd().openFile(input_filename, .{});
        defer input_file.close();
        const metadata = try input_file.metadata();
        break :blk metadata.modified();
    };
    var modified: i128 = undefined;

    compileVestiOnce(input_filename, alloc) catch |err| {
        keep_running.* = false;
        return err;
    };

    while (keep_running.*) {
        std.time.sleep(500 * 1000 * 1000);
        modified = blk: {
            const input_file = try std.fs.cwd().openFile(input_filename, .{});
            defer input_file.close();
            const metadata = try input_file.metadata();
            break :blk metadata.modified();
        };
        if (modified != init_modified) {
            init_modified = modified;
            compileVestiOnce(input_filename, alloc) catch |err| {
                keep_running.* = false;
                return err;
            };
            std.debug.print("Press Ctrl-C to finish the program.\n", .{});
        }
    }
}

fn compileVestiOnce(
    input_filename: []const u8,
    alloc: Allocator,
) !void {
    const output_filename = try takeOutputFilename(alloc, input_filename);
    defer alloc.free(output_filename);

    var input_file = try std.fs.cwd().openFile(input_filename, .{});
    defer input_file.close();

    var output_file = try std.fs.cwd().createFile(output_filename, .{});
    defer output_file.close();

    var writer = output_file.writer();

    // reading a file
    const file_size = try input_file.getEndPos();
    var buffer: []u8 = try alloc.alloc(u8, file_size);
    defer alloc.free(buffer);
    _ = try input_file.readAll(buffer);

    // generating a latex code
    var parser = Parser.init(buffer, alloc);
    const latex_ast = parser.parse() catch |err| {
        switch (err) {
            error.ParseFailed => try diagonosis.prettyPrint(
                buffer,
                parser.error_info.?,
                input_filename,
                alloc,
            ),
            else => {},
        }
        return err;
    };
    defer latex_ast.deinit();

    const latex_string = try codegen.latexToString(&latex_ast, alloc);
    defer latex_string.deinit();

    try writer.writeAll(latex_string.items);
}

fn takeOutputFilename(
    alloc: Allocator,
    input_filename: []const u8,
) ![]const u8 {
    const filename_without_extension = blk: {
        var iter = mem.splitBackwards(u8, input_filename, ".");
        _ = iter.next();
        break :blk iter.rest();
    };

    var output = try alloc.alloc(u8, filename_without_extension.len + 4);
    mem.copy(u8, output, filename_without_extension);
    mem.copy(u8, output[filename_without_extension.len..], ".tex");

    return output;
}

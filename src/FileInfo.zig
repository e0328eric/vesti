const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const FileName = struct {
    filename: []const u8,

    fn init(filename: []const u8, alloc: Allocator) !@This() {
        var copied_filename = try alloc.alloc(u8, filename.len);
        mem.copy(u8, copied_filename, filename);

        return .{ .filename = copied_filename };
    }

    fn deinit(self: @This(), alloc: Allocator) void {
        alloc.free(self.filename);
    }
};

// FileInfo Fields
allocator: Allocator,
file_info: ArrayList(FileName),
// END Fields

const Self = @This();

pub fn init(base_dir: []const u8, alloc: Allocator) !Self {
    var dir = try fs.cwd().openIterableDir(base_dir, .{});
    defer dir.close();
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var output = ArrayList(FileName).init(alloc);
    errdefer {
        for (output.items) |filename| {
            filename.deinit(alloc);
        }
        output.deinit();
    }

    while (try walker.next()) |walker_entry| {
        if (blk: {
            var splitter = mem.splitBackwards(u8, walker_entry.path, ".");
            const extension = splitter.next();
            break :blk extension == null or !mem.eql(u8, extension.?, "ves");
        }) {
            continue;
        }

        var filename = try FileName.init(walker_entry.path, alloc);
        errdefer filename.deinit(alloc);
        try output.append(filename);
    }

    return .{ .allocator = alloc, .file_info = output };
}

pub fn deinit(self: Self) void {
    for (self.file_info.items) |filename| {
        filename.deinit(self.allocator);
    }
    self.file_info.deinit();
}

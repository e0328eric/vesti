const builtin = @import("builtin");
const std = @import("std");
const c = @import("c.zig");
const mem = std.mem;

const Allocator = std.mem.Allocator;

pub const InitSubcmd = struct {
    filenames: ?[][]const u8,
};

pub const RunSubcmd = struct {
    allocator: Allocator,
    input_filenames: ?[][]const u8,
    continuous: bool,

    pub fn deinit(self: @This()) void {
        if (self.input_filenames) |filenames| {
            self.allocator.free(filenames);
        }
    }
};

pub const Commands = union(enum) {
    no_cmd: void,
    init: InitSubcmd,
    run: RunSubcmd,

    pub fn parseCommands(orig_args: [][:0]u8, alloc: Allocator) !@This() {
        var args = try convertToCArray(orig_args, alloc);
        defer alloc.free(args);

        // Parsing Command Line Arguments
        c.drapeauStart("vesti", "A LateX preprocessor");
        defer c.drapeauClose();

        const init_mode = c.drapeauSubcmd("init", "initialize new vesti project");
        const raw_file_name_init = c.drapeauMainArg("FILE", "a file to make", "init");

        const run_mode = c.drapeauSubcmd("run", "run vesti");
        const run_conti = c.drapeauBool("cont", 'c', false, "compile vesti continuously", "run");
        const raw_file_name_run = c.drapeauMainArg("FILE", "a file to compile", "run");

        _ = c.drapeauParse(@intCast(c_int, args.len), @ptrCast([*c][*c]u8, args.ptr));

        // Help flag was found
        if (c.drapeauIsHelp()) {
            return Commands.no_cmd;
        }

        // Init mode was on
        if (init_mode.*) {
            return Commands{ .init = .{ .filenames = try takeFilenamesFromRaw(
                alloc,
                @ptrCast(
                    ?[*][*]const u8,
                    @alignCast(8, raw_file_name_init.*.items),
                ),
                raw_file_name_init.*.len,
            ) } };
        } else if (run_mode.*) {
            const input_filenames = try takeFilenamesFromRaw(
                alloc,
                @ptrCast(
                    ?[*][*]const u8,
                    @alignCast(8, raw_file_name_run.*.items),
                ),
                raw_file_name_run.*.len,
            );

            return Commands{ .run = .{
                .allocator = alloc,
                .input_filenames = input_filenames,
                .continuous = run_conti.*,
            } };
        } else {
            return Commands.no_cmd;
        }
    }

    pub fn deinit(self: @This()) void {
        switch (self) {
            .run => |run_subcmd| run_subcmd.deinit(),
            else => {},
        }
    }
};

fn convertToCArray(from: [][:0]u8, alloc: Allocator) ![][*c]u8 {
    var output = try alloc.alloc([*c]u8, from.len);
    for (output) |*ptr, i|
        ptr.* = @ptrCast([*c]u8, from[i].ptr);

    return output;
}

fn takeFilenamesFromRaw(
    alloc: Allocator,
    raw_file_items: ?[*][*]const u8,
    raw_file_len: usize,
) !?[][]const u8 {
    var file_name_len: usize = undefined;
    if (raw_file_items == null) {
        return null;
    }

    var output = try alloc.alloc([]const u8, raw_file_len);
    var i: usize = 0;
    while (i < raw_file_len) : (i += 1) {
        file_name_len = c.strlen(raw_file_items.?[i]);
        output[i] = raw_file_items.?[i][0..file_name_len];
    }

    return output;
}

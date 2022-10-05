const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const compile = @import("compile.zig");
const diagonosis = @import("diagonosis.zig");

const print = std.debug.print;
const mem = std.mem;

const Commands = @import("commands.zig").Commands;
const InitSubcmd = @import("commands.zig").InitSubcmd;
const RunSubcmd = @import("commands.zig").RunSubcmd;

// Global Variable
var g_keep_running: bool = true;

export fn signalHandler(signal: c_int) void {
    _ = signal;
    g_keep_running = false;
}

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const leaked = gpa.deinit();
        if (leaked) @panic("some memories are leaking!!!");
    }

    // TODO: not work
    _ = c.signal(c.SIGINT, signalHandler);

    var args = std.process.argsAlloc(allocator) catch {
        print(
            "{s}ERROR: {s}allocation of making arguments failed.\n",
            .{ diagonosis.err_color, diagonosis.reset_color },
        );
        return 1;
    };
    defer std.process.argsFree(allocator, args);

    // Parse command line arguments
    const commands = Commands.parseCommands(args, allocator) catch {
        print(
            "{s}ERROR: {s}parsing command failed.\n",
            .{ diagonosis.err_color, diagonosis.reset_color },
        );
        return 1;
    };
    defer commands.deinit();

    return switch (commands) {
        Commands.init => |init_subcmd| initVesti(init_subcmd),
        Commands.run => |run_subcmd| runVesti(run_subcmd),
        Commands.no_cmd => blk: {
            c.drapeauPrintHelp();
            break :blk 1;
        },
    };
}

fn initVesti(init_subcmd: InitSubcmd) u8 {
    std.debug.print("currently it does nothing\n", .{});
    _ = init_subcmd;

    return 0;
}

fn runVesti(run_subcmd: RunSubcmd) u8 {
    const is_continuous = run_subcmd.continuous;
    if (is_continuous) {
        if (run_subcmd.input_filenames) |input_filenames| {
            compile.compile(
                true,
                input_filenames,
                &g_keep_running,
                run_subcmd.allocator,
            ) catch {
                return 1;
            };
        } else {
            c.drapeauPrintHelp();
            print(
                "{s}ERROR: {s}filename was not found\n",
                .{ diagonosis.err_color, diagonosis.reset_color },
            );
            return 1;
        }
    } else {
        if (run_subcmd.input_filenames) |input_filenames| {
            compile.compile(
                false,
                input_filenames,
                &g_keep_running,
                run_subcmd.allocator,
            ) catch {
                return 1;
            };
        } else {
            c.drapeauPrintHelp();
            print(
                "{s}ERROR: {s}filename was not found\n",
                .{ diagonosis.err_color, diagonosis.reset_color },
            );
            return 1;
        }
    }

    return 0;
}

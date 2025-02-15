const std = @import("std");
const fmt = std.fmt;
const io = std.io;
const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Span = @import("./location.zig").Span;
const TokenType = @import("./lexer/Token.zig").TokenType;

err_info: ParseErrorInfo = .None,
span: ?Span = null,

const Self = @This();

pub const ParseErrKind = enum(u8) {
    None = 0,
    EofErr,
    PremiereErr,
    TokenExpected,
    NameMissErr,
    IsNotOpened,
    IsNotClosed,
    IllegalUseErr,
    Deprecated,
    IOErr,
    VestiInternal,
};

pub const ParseErrorInfo = union(ParseErrKind) {
    None,
    EofErr,
    PremiereErr,
    TokenExpected: struct {
        expected: []const TokenType,
        obtained: ?TokenType,
    },
    NameMissErr: TokenType,
    IsNotOpened: struct {
        open: []const TokenType,
        close: TokenType,
    },
    IsNotClosed: struct {
        open: []const TokenType,
        close: TokenType,
    },
    IllegalUseErr: []const u8,
    Deprecated: []const u8,
    IOErr: ArrayList(u8),
    VestiInternal: []const u8,

    fn deinit(self: @This()) void {
        switch (self) {
            .IOErr => |msg| msg.deinit(),
            else => {},
        }
    }
};

pub inline fn deinit(self: Self) void {
    self.err_info.deinit();
}

pub fn addIOErrorInfo(
    self: *Self,
    allocator: Allocator,
    span: Span,
    comptime fmt_str: []const u8,
    args: anytype,
) !void {
    var io_err_msg = try ArrayList(u8).initCapacity(allocator, 30);
    errdefer io_err_msg.deinit();

    try io_err_msg.writer().print(fmt_str, args);

    self.err_info = .{ .IOErr = io_err_msg };
    self.span = span;
}

pub fn prettyPrint(
    self: Self,
    allocator: Allocator,
    absolute_filename: []const u8,
    source: []const u8,
) !void {
    const stderr_handle = io.getStdErr();
    var stderr_buf = io.bufferedWriter(stderr_handle.writer());
    const stderr = stderr_buf.writer();

    var line_iter = mem.tokenizeScalar(u8, source, '\n');
    const current_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(current_dir);
    const filename = try std.fs.path.relative(allocator, current_dir, absolute_filename);
    defer allocator.free(filename);

    if (self.span) |span| {
        for (1..span.start.row) |_| _ = line_iter.next();
        const line = line_iter.next() orelse @panic("span.start.row is invalid");
        const err_msg = try self.errorMsg(allocator);
        defer err_msg.deinit();

        // TODO: add color
        try stderr.print(
            \\{s}:{}:{}: error: {s}
            \\    {s}
            \\
            //\\    {s}
        , .{
            filename, span.start.row, span.start.col,
            err_msg.items, mem.trimRight(u8, line, "\r"), //"",
        });
    } else {
        const err_msg = try self.errorMsg(allocator);
        defer err_msg.deinit();

        // TODO: add color
        try stderr.print(
            \\{s}: error: {s}
        , .{ filename, err_msg.items });
    }

    try stderr_buf.flush();
}

fn errorMsg(
    self: Self,
    allocator: Allocator,
) !ArrayList(u8) {
    var output = try ArrayList(u8).initCapacity(allocator, 50);
    errdefer output.deinit();
    const writer = output.writer();

    switch (self.err_info) {
        .None => try writer.writeAll("<none>"), // TODO: is it the best?
        .EofErr => try writer.print("EOF character was found", .{}),
        .PremiereErr => try writer.print("PremiereErr\n", .{}),
        .TokenExpected => |info| try writer.print(
            "{any} was expected but got {?}",
            .{ info.expected, info.obtained },
        ),
        .NameMissErr => |toktype| try writer.print(
            "{} should have a name",
            .{toktype},
        ),
        .IsNotOpened => |info| try writer.print(
            "either {} was not opened with {any}",
            .{ info.close, info.open },
        ),
        .IsNotClosed => |info| try writer.print(
            "either {any} was not closed with {}",
            .{ info.open, info.close },
        ),
        .IOErr => |info| try writer.print("{s}", .{info.items}),
        .Deprecated => |info| try writer.print(
            "deprecated token was found. Replace `{s}` instead",
            .{info},
        ),
        inline .IllegalUseErr,
        .VestiInternal,
        => |info| try writer.writeAll(info),
    }

    return output;
}

const std = @import("std");
const fmt = std.fmt;
const io = std.io;
const mem = std.mem;
const ansi = @import("./ansi.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Span = @import("./location.zig").Span;
const TokenType = @import("./lexer/Token.zig").TokenType;

pub const Diagnostic = struct {
    allocator: Allocator,
    absolute_filename: ?[]const u8 = null,
    source: ?[]const u8 = null,
    inner: ?DiagnosticInner = null,

    const Self = @This();

    pub fn initMetadata(
        self: *Self,
        absolute_filename: ?[]const u8,
        source: ?[]const u8,
    ) !void {
        if (absolute_filename) |af| {
            if (self.absolute_filename != null) {
                @panic(
                    \\Diagnostic.initMetadata is intended to be initialize it once.
                    \\If this error occurs, then add an issue for it.
                );
            }

            const af_copy = try self.allocator.alloc(u8, af.len);
            errdefer self.allocator.free(af_copy);
            @memcpy(af_copy, af);
            self.absolute_filename = af_copy;
        }
        if (source) |s| {
            if (self.source != null) {
                @panic(
                    \\Diagnostic.initMetadata is intended to be initialize it once.
                    \\If this error occurs, then add an issue for it.
                );
            }

            const source_copy = try self.allocator.alloc(u8, s.len);
            errdefer self.allocator.free(source_copy);
            @memcpy(source_copy, s);
            self.source = source_copy;
        }
    }

    pub fn initDiagInner(self: *Self, diag_inner: DiagnosticInner) void {
        if (self.inner == null) {
            self.inner = diag_inner;
        } else {
            @panic(
                \\Diagnostic.initDiagInner is intended to be initialize it once.
                \\If this error occurs, then add an issue for it.
            );
        }
    }

    pub fn deinit(self: Self) void {
        if (self.absolute_filename) |af| self.allocator.free(af);
        if (self.source) |source| self.allocator.free(source);
        if (self.inner) |inner| inner.deinit();
    }

    pub fn prettyPrint(
        self: Self,
        no_color: bool,
    ) !void {
        if (self.inner) |inner| try inner.prettyPrint(
            self.allocator,
            self.absolute_filename,
            self.source,
            no_color,
        );
    }
};

pub const DiagnosticKind = enum {
    ParseError,
    IOError,
};

pub const DiagnosticInner = union(DiagnosticKind) {
    ParseError: ParseDiagnostic,
    IOError: IODiagnostic,

    const Self = @This();

    pub fn deinit(self: Self) void {
        switch (self) {
            inline else => |inner| inner.deinit(),
        }
    }

    fn prettyPrint(
        self: Self,
        allocator: Allocator,
        absolute_filename: ?[]const u8,
        source: ?[]const u8,
        no_color: bool,
    ) !void {
        switch (self) {
            inline else => |diag| try diag.prettyPrint(
                allocator,
                absolute_filename,
                source,
                no_color,
            ),
        }
    }
};

pub const IODiagnostic = struct {
    msg: ArrayList(u8),
    span: ?Span,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        span: ?Span,
        comptime fmt_str: []const u8,
        args: anytype,
    ) !Self {
        var io_err_msg = try ArrayList(u8).initCapacity(allocator, 30);
        errdefer io_err_msg.deinit();

        try io_err_msg.writer().print(fmt_str, args);

        return Self{ .msg = io_err_msg, .span = span };
    }

    pub inline fn deinit(self: Self) void {
        self.msg.deinit();
    }

    fn prettyPrint(
        self: Self,
        allocator: Allocator,
        absolute_filename: ?[]const u8,
        source: ?[]const u8,
        no_color: bool,
    ) !void {
        _ = allocator;
        _ = absolute_filename;
        _ = source;

        const stderr_handle = io.getStdErr();
        var stderr_buf = io.bufferedWriter(stderr_handle.writer());
        const stderr = stderr_buf.writer();

        if (stderr_handle.supportsAnsiEscapeCodes() and !no_color) {
            try stderr.print(
                ansi.@"error" ++ "error: " ++ ansi.reset ++ "{s}\n",
                .{self.msg.items},
            );
        } else {
            try stderr.print("error: {s}\n", .{self.msg.items});
        }

        try stderr_buf.flush();
    }
};

pub const ParseDiagnostic = struct {
    err_info: ParseErrorInfo = .None,
    span: Span = Span{},

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
        LuaLabelNotFound,
        DuplicatedLuaLabel,
        LuaEvalFailed,
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
        LuaLabelNotFound: ArrayList(u8),
        DuplicatedLuaLabel: []const u8,
        LuaEvalFailed: struct {
            err_msg: ArrayList(u8),
            err_detail: ArrayList(u8),
        },
        VestiInternal: []const u8,

        fn deinit(self: @This()) void {
            switch (self) {
                .LuaLabelNotFound => |label| label.deinit(),
                .LuaEvalFailed => |inner| {
                    inner.err_msg.deinit();
                    inner.err_detail.deinit();
                },
                else => {},
            }
        }
    };

    pub fn luaLabelNotFound(
        allocator: Allocator,
        span: Span,
        label_str: []const u8,
    ) !Self {
        var label = try ArrayList(u8).initCapacity(allocator, label_str.len);
        errdefer label.deinit();
        try label.appendSlice(label_str);

        return Self{
            .err_info = ParseErrorInfo{ .LuaLabelNotFound = label },
            .span = span,
        };
    }

    pub fn luaEvalFailed(
        allocator: Allocator,
        span: Span,
        comptime fmt_str: []const u8,
        args: anytype,
        err_detail_str: [:0]const u8,
    ) !Self {
        var err_msg = try ArrayList(u8).initCapacity(allocator, 30);
        errdefer err_msg.deinit();
        try err_msg.writer().print(fmt_str, args);

        var err_detail = try ArrayList(u8).initCapacity(allocator, err_detail_str.len);
        errdefer err_detail.deinit();
        try err_detail.appendSlice(err_detail_str);

        return Self{
            .err_info = ParseErrorInfo{ .LuaEvalFailed = .{
                .err_msg = err_msg,
                .err_detail = err_detail,
            } },
            .span = span,
        };
    }

    pub inline fn deinit(self: Self) void {
        self.err_info.deinit();
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
            .Deprecated => |info| try writer.print(
                "deprecated token was found. Replace `{s}` instead",
                .{info},
            ),
            inline .IllegalUseErr,
            .VestiInternal,
            => |info| try writer.writeAll(info),
            .LuaLabelNotFound => |label| try writer.print(
                "label `{s}` is not found",
                .{label.items},
            ),
            .DuplicatedLuaLabel => |label| try writer.print(
                "label `{s}` is duplicated",
                .{label},
            ),
            .LuaEvalFailed => |inner| try writer.print(
                "lua exception occured: {s}",
                .{inner.err_msg.items},
            ),
        }

        return output;
    }

    fn noteMsg(
        self: Self,
        allocator: Allocator,
    ) !?ArrayList(u8) {
        return switch (self.err_info) {
            .LuaLabelNotFound => blk: {
                var output = try ArrayList(u8).initCapacity(allocator, 50);
                errdefer output.deinit();
                const writer = output.writer();

                try writer.writeAll("labels should be declared before it is used");
                break :blk output;
            },
            .LuaEvalFailed => |inner| blk: {
                var output = try ArrayList(u8).initCapacity(allocator, 50);
                errdefer output.deinit();
                const writer = output.writer();

                try writer.writeAll(inner.err_detail.items);
                break :blk output;
            },
            else => null,
        };
    }

    fn prettyPrint(
        self: Self,
        allocator: Allocator,
        absolute_filename: ?[]const u8,
        source: ?[]const u8,
        no_color: bool,
    ) !void {
        std.debug.assert(absolute_filename != null and source != null);

        const stderr_handle = io.getStdErr();
        var stderr_buf = io.bufferedWriter(stderr_handle.writer());
        const stderr = stderr_buf.writer();

        var line_iter = mem.tokenizeScalar(u8, source.?, '\n');
        const current_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(current_dir);
        const filename = try std.fs.path.relative(
            allocator,
            current_dir,
            absolute_filename.?,
        );
        defer allocator.free(filename);

        for (1..self.span.start.row) |_| _ = line_iter.next();
        const line = line_iter.next() orelse @panic("span.start.row is invalid");
        const err_msg = try self.errorMsg(allocator);
        defer err_msg.deinit();

        const source_trim = mem.trimRight(u8, line, "\r");
        const underline = if (self.span.start.row == self.span.end.row) blk: {
            @branchHint(.likely);
            break :blk try allocator.alloc(u8, self.span.end.col - 1);
        } else blk: {
            break :blk try allocator.alloc(u8, source_trim.len);
        };
        defer allocator.free(underline);

        @memset(underline[0 .. self.span.start.col - 1], ' ');
        if (self.span.start.row == self.span.end.row) {
            @branchHint(.likely);
            @memset(underline[self.span.start.col - 1 .. self.span.end.col - 1], '^');
        } else {
            @memset(underline[self.span.start.col - 1 ..], '^');
        }

        if (stderr_handle.supportsAnsiEscapeCodes() and !no_color) {
            try stderr.print(
                ansi.makeAnsi(null, .Bold) ++ "{s}:{}:{}: " ++ ansi.@"error" ++
                    "error: " ++ ansi.reset ++ "{s}\n" ++
                    "    {s}\n" ++
                    ansi.makeAnsi(.BrightGreen, null) ++ "    {s}\n" ++ ansi.reset,
                .{
                    filename,      self.span.start.row, self.span.start.col,
                    err_msg.items, source_trim,         underline,
                },
            );

            if (try self.noteMsg(allocator)) |note_msg| {
                try stderr.print(
                    ansi.note ++ "note: " ++ ansi.reset ++ "{s}\n",
                    .{note_msg.items},
                );
                note_msg.deinit();
            }
        } else {
            try stderr.print(
                \\{s}:{}:{}: error: {s}
                \\    {s}
                \\    {s}
                \\
            , .{
                filename,      self.span.start.row, self.span.start.col,
                err_msg.items, source_trim,         underline,
            });
            if (try self.noteMsg(allocator)) |note_msg| {
                try stderr.print("note: {s}\n", .{note_msg.items});
                note_msg.deinit();
            }
        }

        try stderr_buf.flush();
    }
};

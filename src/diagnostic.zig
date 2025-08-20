const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const ansi = @import("./ansi.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Span = @import("./location.zig").Span;
const TokenType = @import("./lexer/Token.zig").TokenType;
const CowStr = @import("./CowStr.zig").CowStr;

pub const Diagnostic = struct {
    allocator: Allocator,
    absolute_filename: ?CowStr = null,
    source: ?CowStr = null,
    inner: ?DiagnosticInner = null,

    const Self = @This();

    /// This function takes ownerships of CowStrs.
    pub fn initMetadata(
        self: *Self,
        absolute_filename: ?CowStr,
        source: ?CowStr,
    ) void {
        if (absolute_filename) |af| {
            if (self.absolute_filename) |*old_af| {
                old_af.deinit(self.allocator);
                old_af.* = af;
            } else {
                self.absolute_filename = af;
            }
        }
        if (source) |s| {
            if (self.source) |*old_s| {
                old_s.deinit(self.allocator);
                old_s.* = s;
            } else {
                self.source = s;
            }
        }
    }

    pub fn initMetadataAlloc(
        self: *Self,
        absolute_filename: ?[]const u8,
        source: ?[]const u8,
    ) !void {
        if (absolute_filename) |af| {
            const new_af = try CowStr.init(.Owned, .{
                self.allocator,
                af,
            });
            if (self.absolute_filename) |*old_af| {
                old_af.deinit(self.allocator);
                old_af.* = new_af;
            } else {
                self.absolute_filename = new_af;
            }
        }
        errdefer if (self.absolute_filename) |*af| af.deinit(self.allocator);

        if (source) |s| {
            const new_s = try CowStr.init(.Owned, .{
                self.allocator,
                s,
            });
            if (self.source) |*old_s| {
                old_s.deinit(self.allocator);
                old_s.* = new_s;
            } else {
                self.source = new_s;
            }
        }
    }

    pub fn initDiagInner(self: *Self, diag_inner: DiagnosticInner) void {
        if (self.inner) |*old_inner| {
            old_inner.deinit(self.allocator);
            old_inner.* = diag_inner;
        } else {
            self.inner = diag_inner;
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.absolute_filename) |*af| af.deinit(self.allocator);
        if (self.source) |*source| source.deinit(self.allocator);
        if (self.inner) |*inner| inner.deinit(self.allocator);
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

    pub fn reset(self: *Self) void {
        self.deinit();
        self.* = .{};
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

    pub fn deinit(self: *Self, allocator: Allocator) void {
        switch (self.*) {
            inline else => |*inner| inner.deinit(allocator),
        }
    }

    fn prettyPrint(
        self: Self,
        allocator: Allocator,
        absolute_filename: ?CowStr,
        source: ?CowStr,
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
    note_msg: ?ArrayList(u8) = null,
    span: ?Span,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        span: ?Span,
        comptime fmt_str: []const u8,
        args: anytype,
    ) !Self {
        var io_err_msg = try ArrayList(u8).initCapacity(allocator, 30);
        errdefer io_err_msg.deinit(allocator);

        try io_err_msg.print(allocator, fmt_str, args);

        return Self{ .msg = io_err_msg, .span = span };
    }

    pub fn initWithNote(
        allocator: Allocator,
        span: ?Span,
        comptime fmt_str: []const u8,
        args: anytype,
        comptime fmt_note_str: []const u8,
        note_args: anytype,
    ) !Self {
        var io_err_msg = try ArrayList(u8).initCapacity(allocator, 30);
        errdefer io_err_msg.deinit(allocator);
        var io_note_msg = try ArrayList(u8).initCapacity(allocator, 30);
        errdefer io_note_msg.deinit(allocator);

        try io_err_msg.print(allocator, fmt_str, args);
        try io_note_msg.print(allocator, fmt_note_str, note_args);

        return Self{ .msg = io_err_msg, .note_msg = io_note_msg, .span = span };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.msg.deinit(allocator);
        if (self.note_msg) |*note_msg| note_msg.deinit(allocator);
    }

    fn prettyPrint(
        self: Self,
        allocator: Allocator,
        absolute_filename: ?CowStr,
        source: ?CowStr,
        no_color: bool,
    ) !void {
        _ = allocator;
        _ = absolute_filename;
        _ = source;

        const stderr_handle = std.fs.File.stderr();
        var stderr_buf: [4096]u8 = undefined;
        var stderr = stderr_handle.writer(&stderr_buf);

        if (stderr_handle.supportsAnsiEscapeCodes() and !no_color) {
            try stderr.interface.print(
                ansi.@"error" ++ "error: " ++ ansi.reset ++ "{s}\n",
                .{self.msg.items},
            );
            if (self.note_msg) |note_msg| {
                try stderr.interface.print(
                    ansi.note ++ "note: " ++ ansi.reset ++ "{s}\n",
                    .{note_msg.items},
                );
            }
        } else {
            try stderr.interface.print("error: {s}\n", .{self.msg.items});
            if (self.note_msg) |note_msg| {
                try stderr.interface.print("note: {s}\n", .{note_msg.items});
            }
        }

        try stderr.interface.flush();
    }
};

pub const ParseDiagnostic = struct {
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
        LuaLabelNotFound,
        DuplicatedPyLabel,
        InvalidPycode,
        DisallowPycode,
        PyEvalFailed,
        NotLocatedInVeryFirst,
        DoubleUsed,
        InvalidLatexEngine,
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
        DuplicatedPyLabel: []const u8,
        InvalidPycode,
        DisallowPycode,
        PyEvalFailed: struct {
            err_msg: ArrayList(u8),
            err_detail: ArrayList(u8),
        },
        NotLocatedInVeryFirst: TokenType,
        DoubleUsed: TokenType,
        InvalidLatexEngine: []const u8,
        VestiInternal: []const u8,

        fn deinit(self: *@This(), allocator: Allocator) void {
            switch (self.*) {
                .LuaLabelNotFound => |*label| label.deinit(allocator),
                .PyEvalFailed => |*inner| {
                    inner.err_msg.deinit(allocator);
                    inner.err_detail.deinit(allocator);
                },
                else => {},
            }
        }
    };

    pub fn pyLabelNotFound(
        allocator: Allocator,
        span: Span,
        label_str: []const u8,
    ) !Self {
        var label = try ArrayList(u8).initCapacity(allocator, label_str.len);
        errdefer label.deinit(allocator);
        try label.appendSlice(allocator, label_str);

        return Self{
            .err_info = ParseErrorInfo{ .LuaLabelNotFound = label },
            .span = span,
        };
    }

    pub fn pyEvalFailed(
        allocator: Allocator,
        span: ?Span,
        comptime fmt_str: []const u8,
        args: anytype,
        err_detail_str: [:0]const u8,
    ) !Self {
        var err_msg = try ArrayList(u8).initCapacity(allocator, 30);
        errdefer err_msg.deinit(allocator);
        try err_msg.print(allocator, fmt_str, args);

        var err_detail = try ArrayList(u8).initCapacity(allocator, err_detail_str.len);
        errdefer err_detail.deinit(allocator);
        try err_detail.appendSlice(allocator, err_detail_str);

        return Self{
            .err_info = ParseErrorInfo{ .PyEvalFailed = .{
                .err_msg = err_msg,
                .err_detail = err_detail,
            } },
            .span = span,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.err_info.deinit(allocator);
    }

    fn errorMsg(
        self: Self,
        allocator: Allocator,
    ) !ArrayList(u8) {
        var output = try ArrayList(u8).initCapacity(allocator, 50);
        errdefer output.deinit(allocator);
        var aw: Io.Writer.Allocating = .fromArrayList(allocator, &output);
        errdefer aw.deinit();

        switch (self.err_info) {
            .None => try aw.writer.writeAll("<none>"), // TODO: is it the best?
            .EofErr => try aw.writer.print("EOF character was found", .{}),
            .PremiereErr => try aw.writer.print("PremiereErr\n", .{}),
            .TokenExpected => |info| {
                if (info.expected.len == 1) {
                    try aw.writer.print(
                        "{f} was expected but got {?f}",
                        .{ info.expected[0], info.obtained },
                    );
                } else {
                    var tmp = Io.Writer.Allocating.init(allocator);
                    defer tmp.deinit();

                    try tmp.writer.writeByte('[');
                    for (info.expected) |info_inner| {
                        try tmp.writer.print(" {f}", .{info_inner});
                    }
                    try tmp.writer.writeAll(" ]");

                    try aw.writer.print(
                        "{s} was expected but got {?f}",
                        .{ tmp.written(), info.obtained },
                    );
                }
            },
            .NameMissErr => |toktype| try aw.writer.print(
                "{f} should have a name",
                .{toktype},
            ),
            .IsNotOpened => |info| {
                if (info.open.len == 1) {
                    try aw.writer.print(
                        "either {f} was not opened with {f}",
                        .{ info.close, info.open[0] },
                    );
                } else {
                    var tmp = Io.Writer.Allocating.init(allocator);
                    defer tmp.deinit();

                    try tmp.writer.writeByte('[');
                    for (info.open) |info_inner| {
                        try tmp.writer.print(" {f}", .{info_inner});
                    }
                    try tmp.writer.writeAll(" ]");

                    try aw.writer.print(
                        "either {f} was not opened with {s}",
                        .{ info.close, tmp.written() },
                    );
                }
            },
            .IsNotClosed => |info| {
                if (info.open.len == 1) {
                    try aw.writer.print(
                        "{f} was not closed with {f}",
                        .{ info.open[0], info.close },
                    );
                } else {
                    var tmp = Io.Writer.Allocating.init(allocator);
                    defer tmp.deinit();

                    try tmp.writer.writeByte('[');
                    for (info.open) |info_inner| {
                        try tmp.writer.print(" {f}", .{info_inner});
                    }
                    try tmp.writer.writeAll(" ]");

                    try aw.writer.print(
                        "either {s} was not closed with {f}",
                        .{ tmp.written(), info.close },
                    );
                }
            },
            .Deprecated => |info| try aw.writer.print(
                "deprecated token was found. Replace `{s}` instead",
                .{info},
            ),
            inline .IllegalUseErr,
            .VestiInternal,
            => |info| try aw.writer.writeAll(info),
            .InvalidPycode => try aw.writer.writeAll("invalid pycode was found"),
            .DisallowPycode => try aw.writer.writeAll("nested pycode is not allowed"),
            .LuaLabelNotFound => |label| try aw.writer.print(
                "label `{s}` is not found",
                .{label.items},
            ),
            .DuplicatedPyLabel => |label| try aw.writer.print(
                "label `{s}` is duplicated",
                .{label},
            ),
            .PyEvalFailed => |inner| try aw.writer.print(
                "python exception occured: {s}",
                .{inner.err_msg.items},
            ),
            .NotLocatedInVeryFirst => |tok| try aw.writer.print(
                "{f} must located in the very first line of the vesti code",
                .{tok},
            ),
            .DoubleUsed => |tok| try aw.writer.print(
                "{f} must be used only once",
                .{tok},
            ),
            .InvalidLatexEngine => |engine| try aw.writer.print(
                "invalid latex engine name {s} was found",
                .{engine},
            ),
        }

        return aw.toArrayList();
    }

    fn noteMsg(
        self: Self,
        allocator: Allocator,
    ) !?ArrayList(u8) {
        return switch (self.err_info) {
            .LuaLabelNotFound => blk: {
                var output = try ArrayList(u8).initCapacity(allocator, 50);
                errdefer output.deinit(allocator);

                try output.print(
                    allocator,
                    "labels should be declared before it is used",
                    .{},
                );
                break :blk output;
            },
            .PyEvalFailed => |inner| blk: {
                var output = try ArrayList(u8).initCapacity(allocator, 50);
                errdefer output.deinit(allocator);

                try output.print(allocator, "{s}", .{inner.err_detail.items});
                break :blk output;
            },
            .InvalidLatexEngine => blk: {
                var output = try ArrayList(u8).initCapacity(allocator, 50);
                errdefer output.deinit(allocator);

                try output.print(
                    allocator,
                    "valid ones are `plain`, `pdf`, `xe`, and `lua`",
                    .{},
                );
                break :blk output;
            },
            else => null,
        };
    }

    fn prettyPrint(
        self: Self,
        allocator: Allocator,
        absolute_filename: ?CowStr,
        source: ?CowStr,
        no_color: bool,
    ) !void {
        std.debug.assert(source != null);

        const stderr_handle = std.fs.File.stderr();
        var stderr_buf: [4096]u8 = undefined;
        var stderr = stderr_handle.writer(&stderr_buf);

        const filename = if (absolute_filename) |af| blk: {
            const current_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
            defer allocator.free(current_dir);
            break :blk try std.fs.path.relative(
                allocator,
                current_dir,
                af.toStr(),
            );
        } else "^.^";
        defer if (absolute_filename != null) allocator.free(filename);

        var err_msg = try self.errorMsg(allocator);
        defer err_msg.deinit(allocator);

        if (self.span) |span| {
            var line_iter = mem.splitScalar(u8, source.?.toStr(), '\n');

            for (1..span.start.row) |_| _ = line_iter.next();
            const line = line_iter.next() orelse @panic("span.start.row is invalid");

            const source_trim = mem.trimRight(u8, line, "\r");
            const underline = if (span.start.row == span.end.row) blk: {
                @branchHint(.likely);
                break :blk try allocator.alloc(u8, span.end.col - 1);
            } else blk: {
                break :blk try allocator.alloc(u8, source_trim.len);
            };
            defer allocator.free(underline);

            @memset(underline[0 .. span.start.col - 1], ' ');
            if (span.start.row == span.end.row) {
                @branchHint(.likely);
                @memset(underline[span.start.col - 1 .. span.end.col - 1], '^');
            } else {
                @memset(underline[span.start.col - 1 ..], '^');
            }

            if (stderr_handle.supportsAnsiEscapeCodes() and !no_color) {
                try stderr.interface.print(
                    ansi.makeAnsi(null, .Bold) ++ "{s}:{}:{}: " ++ ansi.@"error" ++
                        "error: " ++ ansi.reset ++ "{s}\n" ++
                        "    {s}\n" ++
                        ansi.makeAnsi(.BrightGreen, null) ++ "    {s}\n" ++ ansi.reset,
                    .{
                        filename,      span.start.row, span.start.col,
                        err_msg.items, source_trim,    underline,
                    },
                );

                var note_msg = try self.noteMsg(allocator);
                if (note_msg) |*nm| {
                    defer nm.deinit(allocator);
                    try stderr.interface.print(
                        ansi.note ++ "note: " ++ ansi.reset ++ "{s}\n",
                        .{nm.items},
                    );
                }
            } else {
                try stderr.interface.print(
                    \\{s}:{}:{}: error: {s}
                    \\    {s}
                    \\    {s}
                    \\
                , .{
                    filename,      span.start.row, span.start.col,
                    err_msg.items, source_trim,    underline,
                });
                var note_msg = try self.noteMsg(allocator);
                if (note_msg) |*nm| {
                    defer nm.deinit(allocator);
                    try stderr.interface.print("note: {s}\n", .{nm.items});
                }
            }
        } else {
            if (stderr_handle.supportsAnsiEscapeCodes() and !no_color) {
                try stderr.interface.print(
                    ansi.makeAnsi(null, .Bold) ++ "{s}: " ++ ansi.@"error" ++
                        "error: " ++ ansi.reset ++ "{s}\n" ++ ansi.reset,
                    .{ filename, err_msg.items },
                );

                var note_msg = try self.noteMsg(allocator);
                if (note_msg) |*nm| {
                    defer nm.deinit(allocator);
                    try stderr.interface.print(
                        ansi.note ++ "note: " ++ ansi.reset ++ "{s}\n",
                        .{nm.items},
                    );
                }
            } else {
                try stderr.interface.print(
                    \\{s}: error: {s}
                    \\
                , .{ filename, err_msg.items });

                var note_msg = try self.noteMsg(allocator);
                if (note_msg) |*nm| {
                    defer nm.deinit(allocator);
                    try stderr.interface.print("note: {s}\n", .{nm.items});
                }
            }
        }

        try stderr.interface.flush();
    }
};

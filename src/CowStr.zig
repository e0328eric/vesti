//! copy-on-write data structure.
const std = @import("std");
const mem = std.mem;

const assert = std.debug.assert;
const fmtStr = std.fmt.comptimePrint;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const CowStrState = enum(u2) {
    Empty = 0,
    Borrowed,
    Owned,
};

fn validInnerType(comptime inner: type) void {
    comptime {
        const typeinfo = @typeInfo(inner);
        if (typeinfo != .pointer) {
            @compileError(fmtStr(
                "expected pointer, got {s}",
                .{@typeName(inner)},
            ));
        }

        if (!typeinfo.pointer.is_const) {
            @compileError("non-const pointer was given");
        }
        switch (typeinfo.pointer.size) {
            .one => {
                const child_typeinfo = @typeInfo(typeinfo.pointer.child);
                if (child_typeinfo != .array) {
                    @compileError(fmtStr(
                        "pointer of u8 array was expected, got {s}",
                        .{@typeName(inner)},
                    ));
                }
                if (child_typeinfo.array.child != u8) {
                    @compileError(fmtStr(
                        "pointer of u8 array was expected, got {s}",
                        .{@typeName(inner)},
                    ));
                }
            },
            .slice => if (inner != []const u8) {
                @compileError(fmtStr(
                    "expected []const u8, got {s}",
                    .{@typeName(inner)},
                ));
            },
            else => @compileError(fmtStr(
                "pointer of type [*] or [*c] is invalid, got {s}",
                .{@typeName(inner)},
            )),
        }
    }
}

pub const CowStr = union(CowStrState) {
    Empty,
    Borrowed: []const u8,
    Owned: ArrayList(u8),

    const Self = @This();

    pub fn init(comptime state: CowStrState, initializer: anytype) switch (state) {
        .Empty, .Borrowed => Self,
        .Owned => Allocator.Error!Self,
    } {
        switch (state) {
            .Empty => return @unionInit(Self, "Empty", {}),
            .Borrowed => {
                comptime {
                    const typeinfo = @typeInfo(@TypeOf(initializer));
                    assert(typeinfo == .@"struct");
                    validInnerType(@TypeOf(initializer[0]));
                }
                return @unionInit(Self, "Borrowed", initializer[0]);
            },
            .Owned => {
                comptime {
                    const typeinfo = @typeInfo(@TypeOf(initializer));
                    assert(typeinfo == .@"struct");
                    assert(@TypeOf(initializer[0]) == Allocator);
                    validInnerType(@TypeOf(initializer[1]));
                }
                const allocator = initializer[0];
                const str = initializer[1];

                var inner = try ArrayList(u8).initCapacity(allocator, str.len);
                errdefer inner.deinit(allocator);
                try inner.appendSlice(allocator, str);
                return @unionInit(Self, "Owned", inner);
            },
        }
    }

    pub fn initPrint(allocator: Allocator, comptime fmt: []const u8, args: anytype) !Self {
        var inner: ArrayList(u8) = .empty;
        try inner.print(allocator, fmt, args);
        return @unionInit(Self, "Owned", inner);
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        switch (self.*) {
            .Owned => |*inner| inner.deinit(allocator),
            else => {},
        }
    }

    pub fn fromArrayList(arr_list: ArrayList(u8)) Self {
        return @unionInit(Self, "Owned", arr_list);
    }

    pub fn fromOwnedSlice(owned_str: []u8) Self {
        const inner = ArrayList(u8).fromOwnedSlice(owned_str);
        return @unionInit(Self, "Owned", inner);
    }

    pub fn append(
        self: *Self,
        allocator: Allocator,
        to_append: []const u8,
    ) !void {
        switch (self.*) {
            .Empty => self.* = Self.init(.Borrowed, .{to_append}),
            .Borrowed => |inner| {
                var output = try ArrayList(u8).initCapacity(
                    allocator,
                    inner.len + to_append.len,
                );
                errdefer output.deinit(allocator);

                try output.appendSlice(allocator, inner);
                try output.appendSlice(allocator, to_append);

                // Since self.* is .Borrowed, this operation is  memory safe
                self.* = @unionInit(Self, "Owned", output);
            },
            .Owned => |*inner| try inner.appendSlice(allocator, to_append),
        }
    }

    pub fn eqlStr(self: Self, rhs: []const u8) bool {
        return switch (self) {
            .Empty => rhs.len == 0,
            .Borrowed => |inner| mem.eql(u8, inner, rhs),
            .Owned => |inner| mem.eql(u8, inner.items, rhs),
        };
    }

    pub fn toStr(self: Self) []const u8 {
        return switch (self) {
            .Empty => "",
            .Borrowed => |inner| inner,
            .Owned => |inner| inner.items,
        };
    }

    pub fn format(
        self: Self,
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            .Empty => try writer.writeAll(""),
            .Borrowed => |inner| try writer.print("{s}", .{inner}),
            .Owned => |inner| try writer.print("{s}", .{inner.items}),
        }
    }
};

//! copy-on-write data structure.
const std = @import("std");
const mem = std.mem;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const CowStrState = enum(u2) {
    Empty = 0,
    Borrowed,
    Owned,
};

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
                    assert(@TypeOf(initializer[0]) == []const u8);
                }
                return @unionInit(Self, "Borrowed", initializer[0]);
            },
            .Owned => {
                comptime {
                    const typeinfo = @typeInfo(@TypeOf(initializer));
                    assert(typeinfo == .@"struct");
                    assert(@TypeOf(initializer[0]) == Allocator);
                    assert(@TypeOf(initializer[1]) == []const u8);
                }
                const allocator = initializer[0];
                const str = initializer[1];

                var inner = try ArrayList(u8).initCapacity(allocator, str.len);
                errdefer inner.deinit();
                try inner.appendSlice(str);
                return @unionInit(Self, "Owned", inner);
            },
        }
    }

    pub fn deinit(self: Self) void {
        switch (self) {
            .Owned => |inner| inner.deinit(),
            else => {},
        }
    }

    pub fn fromOwnedStr(allocator: Allocator, owned_str: []u8) Self {
        const inner = ArrayList(u8).fromOwnedSlice(allocator, owned_str);
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
                errdefer output.deinit();

                try output.appendSlice(inner);
                try output.appendSlice(to_append);

                // Since self.* is .Borrowed, this operation is  memory safe
                self.* = @unionInit(Self, "Owned", output);
            },
            .Owned => |*inner| try inner.appendSlice(to_append),
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

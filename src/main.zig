const std = @import("std");

const Location = @import("location.zig").Location;
const DisplayWidth = @import("zg_DisplayWidth");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const dwd = try DisplayWidth.DisplayWidthData.init(allocator);
    defer dwd.deinit();
    const dw = DisplayWidth{ .data = &dwd };

    var loc = Location{};
    loc.move(dw, '가');

    std.debug.print("{any}\n", .{loc});
}

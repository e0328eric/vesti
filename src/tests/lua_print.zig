const std = @import("std");
const Config = @import("../Config.zig");
const Lua = @import("../Lua.zig");

fn expectOutput(code: [:0]const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(allocator);
    defer env_map.deinit();
    const config: Config = .{};
    const lua = try Lua.init(allocator, std.testing.io, &env_map, .xelatex, &config, .{
        .compile_all = false,
        .watch = false,
        .no_color = true,
        .no_exit_err = false,
    });
    defer lua.deinit();

    try lua.lua.doString(code);
    try std.testing.expectEqualStrings(expected, lua.buf.items);
    try std.testing.expectEqual(@as(c_int, 0), lua.lua.getTop());
}

test "vesti.print separators and newlines" {
    const cases = .{
        .{ "vesti.print('a', 'b', 'c')", "a b c\n" },
        .{ "vesti.print('a', 'b', 'c', {sep = ', '})", "a, b, c\n" },
        .{ "vesti.print('a', 'b', {sep = '', nl = 0})", "ab" },
        .{ "vesti.print('only', {sep = '|'})", "only\n" },
        .{ "vesti.print('', '', {sep = ':', nl = 2})", ":\n\n" },
        .{ "vesti.print(1, 2, 3, {sep = '/'})", "1/2/3\n" },
        .{ "vesti.print('a', 'b', {})", "a b\n" },
        .{ "vesti.print('a', 'b', {sep = nil, nl = 0})", "a b" },
        .{ "vesti.print('a', 'b', {nl = 3})", "a b\n\n" },
        .{ "vesti.print('a', 'b', {sep = '\\n', nl = 0})", "a\nb" },
        .{ "vesti.print('a', 'b', {sep = '·'})", "a·b\n" },
        .{ "vesti.print('a', 'b', {sep = '\\0', nl = 0})", "a\x00b" },
        .{ "vesti.print('a', 'b', {sep = '|', nl = 0}); vesti.print('c', 'd')", "a|bc d\n" },
    };
    inline for (cases) |case| try expectOutput(case[0], case[1]);
}

test "vesti.print keeps a generated separator alive during option lookup" {
    try expectOutput(
        \\local options = setmetatable({}, {
        \\    __index = function(_, key)
        \\        if key == 'sep' then
        \\            return string.rep(':', 256)
        \\        end
        \\        collectgarbage('collect')
        \\        return 0
        \\    end,
        \\})
        \\vesti.print('a', 'b', options)
    , "a" ++ ":" ** 256 ++ "b");
}

test "vesti.print separates unpacked values when options are unpacked with them" {
    try expectOutput(
        \\local values = {'true', 'false', 'true'}
        \\-- Lua expands every result only when unpack is the final argument.
        \\table.insert(values, {sep = '&', nl = 0})
        \\vesti.print(table.unpack(values))
    , "true&false&true");
}

test "vesti.print keeps a separator alive when an option getter removes it" {
    try expectOutput(
        \\local options = setmetatable({sep = string.rep('|', 256)}, {
        \\    __index = function(self, key)
        \\        self.sep = nil
        \\        collectgarbage('collect')
        \\        return 0
        \\    end,
        \\})
        \\vesti.print('a', 'b', options)
    , "a" ++ "|" ** 256 ++ "b");
}

test "vesti.print rejects invalid newline counts without crashing" {
    try expectOutput(
        \\for _, nl in ipairs({-1, 0.5, math.huge, -math.huge, 0/0, 1e30, '1', false}) do
        \\    local ok, err = pcall(vesti.print, 'a', 'b', {sep = '|', nl = nl})
        \\    assert(not ok)
        \\    assert(err:find('`nl` should be a nonnegative integer', 1, true))
        \\end
        \\vesti.print('a', 'b', {sep = '|'})
    , "a|b\n");
}

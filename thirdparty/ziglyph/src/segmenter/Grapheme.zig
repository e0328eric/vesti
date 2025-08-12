//! `Grapheme` represents a Unicode grapheme cluster by its length and offset in the source bytes.

const std = @import("std");
const unicode = std.unicode;

const CodePoint = @import("CodePoint.zig");
const CodePointIterator = CodePoint.CodePointIterator;
const readCodePoint = CodePoint.readCodePoint;
const emoji = @import("../autogen/emoji_data.zig");
const gbp = @import("../autogen/grapheme_break_property.zig");

pub const Grapheme = @This();

len: usize,
offset: usize,

/// `eql` comparse `str` with the bytes of this grapheme cluster in `src` for equality.
pub fn eql(self: Grapheme, src: []const u8, other: []const u8) bool {
    return std.mem.eql(u8, src[self.offset .. self.offset + self.len], other);
}

/// `slice` returns the bytes that correspond to this grapheme cluster in `src`.
pub fn slice(self: Grapheme, src: []const u8) []const u8 {
    return src[self.offset .. self.offset + self.len];
}

/// `GraphemeIterator` iterates a sting of UTF-8 encoded bytes one grapheme cluster at-a-time.
pub const GraphemeIterator = struct {
    buf: [2]?CodePoint = [_]?CodePoint{ null, null },
    cp_iter: CodePointIterator,

    const Self = @This();

    /// Assumes `src` is valid UTF-8.
    pub fn init(str: []const u8) Self {
        var self = Self{ .cp_iter = CodePointIterator{ .bytes = str } };
        self.buf[1] = self.cp_iter.next();

        return self;
    }

    fn advance(self: *Self) void {
        self.buf[0] = self.buf[1];
        self.buf[1] = self.cp_iter.next();
    }

    pub fn next(self: *Self) ?Grapheme {
        self.advance();

        // If at end
        if (self.buf[0] == null) return null;
        if (self.buf[1] == null) return Grapheme{ .len = self.buf[0].?.len, .offset = self.buf[0].?.offset };

        const gc_start = self.buf[0].?.offset;
        var gc_len: usize = self.buf[0].?.len;
        var state: u3 = 0;

        if (graphemeBreak(
            self.buf[0].?.code,
            self.buf[1].?.code,
            &state,
        )) return Grapheme{ .len = gc_len, .offset = gc_start };

        while (true) {
            self.advance();
            if (self.buf[0] == null) break;

            gc_len += self.buf[0].?.len;

            if (graphemeBreak(
                self.buf[0].?.code,
                if (self.buf[1]) |ncp| ncp.code else 0,
                &state,
            )) break;
        }

        return Grapheme{ .len = gc_len, .offset = gc_start };
    }
};

/// `StreamingGraphemeIterator` iterates a `std.io.Reader` one grapheme cluster at-a-time.
/// Note that, given the steaming context, each grapheme cluster is returned as a slice of bytes.
pub fn StreamingGraphemeIterator(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        buf: [2]?u21 = [_]?u21{ null, null },
        reader: T,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, reader: anytype) !Self {
            var self = Self{ .allocator = allocator, .reader = reader };
            self.buf[1] = try readCodePoint(self.reader);

            return self;
        }

        /// Caller must free returned bytes with `allocator` passed to `init`.
        pub fn next(self: *Self) !?[]u8 {
            const code = (try self.advance()) orelse return null;

            var all_bytes = std.ArrayList(u8).init(self.allocator);
            errdefer all_bytes.deinit();

            try encode_and_append(code, &all_bytes);

            // If at end
            if (self.buf[1] == null) return try all_bytes.toOwnedSlice();

            // Instant breakers
            // CR
            if (code == '\x0d') {
                if (self.buf[1].? == '\x0a') {
                    // CRLF
                    try encode_and_append(self.buf[1].?, &all_bytes);
                    _ = self.advance() catch unreachable;
                }

                return try all_bytes.toOwnedSlice();
            }
            // LF
            if (code == '\x0a') return try all_bytes.toOwnedSlice();
            // Control
            if (gbp.isControl(code)) return try all_bytes.toOwnedSlice();

            // Common chars
            if (code < 0xa9) {
                // Extend / ignorables loop
                while (self.buf[1]) |next_cp| {
                    if (next_cp >= 0x300 and isIgnorable(next_cp)) {
                        try encode_and_append(next_cp, &all_bytes);
                        _ = self.advance() catch unreachable;
                    } else {
                        break;
                    }
                }

                return try all_bytes.toOwnedSlice();
            }

            if (emoji.isExtendedPictographic(code)) {
                var after_zwj = false;

                // Extend / ignorables loop
                while (self.buf[1]) |next_cp| {
                    if (next_cp >= 0x300 and
                        after_zwj and
                        emoji.isExtendedPictographic(next_cp))
                    {
                        try encode_and_append(next_cp, &all_bytes);
                        _ = self.advance() catch unreachable;
                        after_zwj = false;
                    } else if (next_cp >= 0x300 and isIgnorable(next_cp)) {
                        try encode_and_append(next_cp, &all_bytes);
                        _ = self.advance() catch unreachable;
                        if (next_cp == '\u{200d}') after_zwj = true;
                    } else {
                        break;
                    }
                }

                return try all_bytes.toOwnedSlice();
            }

            if (0x1100 <= code and code <= 0xd7c6) {
                const next_cp = self.buf[1].?;

                if (gbp.isL(code)) {
                    if (next_cp >= 0x1100 and
                        (gbp.isL(next_cp) or
                        gbp.isV(next_cp) or
                        gbp.isLv(next_cp) or
                        gbp.isLvt(next_cp)))
                    {
                        try encode_and_append(next_cp, &all_bytes);
                        _ = self.advance() catch unreachable;
                    }
                } else if (gbp.isLv(code) or gbp.isV(code)) {
                    if (next_cp >= 0x1100 and
                        (gbp.isV(next_cp) or
                        gbp.isT(next_cp)))
                    {
                        try encode_and_append(next_cp, &all_bytes);
                        _ = self.advance() catch unreachable;
                    }
                } else if (gbp.isLvt(code) or gbp.isT(code)) {
                    if (next_cp >= 0x1100 and gbp.isT(next_cp)) {
                        try encode_and_append(next_cp, &all_bytes);
                        _ = self.advance() catch unreachable;
                    }
                }
            } else if (0x600 <= code and code <= 0x11f02) {
                if (gbp.isPrepend(code)) {
                    const next_cp = self.buf[1].?;

                    if (isBreaker(next_cp)) {
                        return try all_bytes.toOwnedSlice();
                    } else {
                        try encode_and_append(next_cp, &all_bytes);
                        _ = self.advance() catch unreachable;
                    }
                }
            } else if (0x1f1e6 <= code and code <= 0x1f1ff) {
                if (gbp.isRegionalIndicator(code)) {
                    const next_cp = self.buf[1].?;

                    if (next_cp >= 0x1f1e6 and gbp.isRegionalIndicator(next_cp)) {
                        try encode_and_append(next_cp, &all_bytes);
                        _ = self.advance() catch unreachable;
                    }
                }
            }

            // Extend / ignorables loop
            while (self.buf[1]) |next_cp| {
                if (next_cp >= 0x300 and isIgnorable(next_cp)) {
                    try encode_and_append(next_cp, &all_bytes);
                    _ = self.advance() catch unreachable;
                } else {
                    break;
                }
            }

            return try all_bytes.toOwnedSlice();
        }

        fn advance(self: *Self) !?u21 {
            self.buf[0] = self.buf[1];
            self.buf[1] = try readCodePoint(self.reader);

            return self.buf[0];
        }

        fn peek(self: Self) ?u21 {
            return self.buf[1];
        }

        fn encode_and_append(cp: u21, list: *std.ArrayList(u8)) !void {
            var tmp: [4]u8 = undefined;
            const len = try unicode.utf8Encode(cp, &tmp);
            try list.appendSlice(tmp[0..len]);
        }
    };
}

// Predicates
fn isBreaker(cp: u21) bool {
    return cp == '\x0d' or cp == '\x0a' or gbp.isControl(cp);
}

fn isIgnorable(cp: u21) bool {
    return gbp.isExtend(cp) or gbp.isSpacingmark(cp) or cp == '\u{200d}';
}

test "Segmentation comptime GraphemeIterator" {
    const want = [_][]const u8{ "H", "é", "l", "l", "o" };

    comptime {
        const src = "Héllo";
        var ct_iter = GraphemeIterator.init(src);
        var i = 0;
        while (ct_iter.next()) |grapheme| : (i += 1) {
            try std.testing.expect(grapheme.eql(src, want[i]));
        }
    }
}

test "Simple StreamingGraphemeIterator" {
    var buf = "abe\u{301}😹".*;
    var fis = std.io.fixedBufferStream(&buf);
    const reader = fis.reader();
    var iter = try StreamingGraphemeIterator(@TypeOf(reader)).init(std.testing.allocator, reader);
    const want = [_][]const u8{ "a", "b", "e\u{301}", "😹" };

    for (want) |str| {
        const gc = (try iter.next()).?;
        defer std.testing.allocator.free(gc);
        try std.testing.expectEqualStrings(gc, str);
    }

    try std.testing.expectEqual(@as(?[]u8, null), try iter.next());
}

test "Segmentation ZWJ and ZWSP emoji sequences" {
    const seq_1 = "\u{1F43B}\u{200D}\u{2744}\u{FE0F}";
    const seq_2 = "\u{1F43B}\u{200D}\u{2744}\u{FE0F}";
    const with_zwj = seq_1 ++ "\u{200D}" ++ seq_2;
    const with_zwsp = seq_1 ++ "\u{200B}" ++ seq_2;
    const no_joiner = seq_1 ++ seq_2;

    var ct_iter = GraphemeIterator.init(with_zwj);
    var i: usize = 0;
    while (ct_iter.next()) |_| : (i += 1) {}
    try std.testing.expectEqual(@as(usize, 1), i);

    ct_iter = GraphemeIterator.init(with_zwsp);
    i = 0;
    while (ct_iter.next()) |_| : (i += 1) {}
    try std.testing.expectEqual(@as(usize, 3), i);

    ct_iter = GraphemeIterator.init(no_joiner);
    i = 0;
    while (ct_iter.next()) |_| : (i += 1) {}
    try std.testing.expectEqual(@as(usize, 2), i);
}

// Grapheme break state.
fn hasXpic(state: *const u3) bool {
    return state.* & 1 == 1;
}

fn setXpic(state: *u3) void {
    state.* |= 1;
}

fn unsetXpic(state: *u3) void {
    state.* ^= 1;
}

fn hasRegional(state: *const u3) bool {
    return state.* & 2 == 2;
}

fn setRegional(state: *u3) void {
    state.* |= 2;
}

fn unsetRegional(state: *u3) void {
    state.* ^= 2;
}

/// `graphemeBreak` returns true only if a grapheme break point is required
/// between `cp1` and `cp2`. `state` should start out as 0. If calling
/// iteratively over a sequence of code points, this function must be called
/// IN ORDER on ALL potential breaks in a string.
/// Modeled after the API of utf8proc's `utf8proc_grapheme_break_stateful`.
/// https://github.com/JuliaStrings/utf8proc/blob/2bbb1ba932f727aad1fab14fafdbc89ff9dc4604/utf8proc.h#L599-L617
pub fn graphemeBreak(
    cp1: u21,
    cp2: u21,
    state: *u3,
) bool {
    // GB11: Emoji Extend* ZWJ x Emoji
    if (!hasXpic(state) and emoji.isExtendedPictographic(cp1)) setXpic(state);

    // GB3: CR x LF
    if (cp1 == '\r' and cp2 == '\n') return false;

    // GB4: Control
    if (isBreaker(cp1)) return true;

    // GB6: Hangul L x (L|V|LV|VT)
    if (gbp.isL(cp1)) {
        if (gbp.isL(cp2) or
            gbp.isV(cp2) or
            gbp.isLv(cp2) or
            gbp.isLvt(cp2)) return false;
    }

    // GB7: Hangul (LV | V) x (V | T)
    if (gbp.isLv(cp1) or gbp.isV(cp1)) {
        if (gbp.isV(cp2) or
            gbp.isT(cp2)) return false;
    }

    // GB8: Hangul (LVT | T) x T
    if (gbp.isLvt(cp1) or gbp.isT(cp1)) {
        if (gbp.isT(cp2)) return false;
    }

    // GB9b: x (Extend | ZWJ)
    if (gbp.isExtend(cp2) or gbp.isZwj(cp2)) return false;

    // GB9a: x Spacing
    if (gbp.isSpacingmark(cp2)) return false;

    // GB9b: Prepend x
    if (gbp.isPrepend(cp1) and !isBreaker(cp2)) return false;

    // GB12, GB13: RI x RI
    if (gbp.isRegionalIndicator(cp1) and gbp.isRegionalIndicator(cp2)) {
        if (hasRegional(state)) {
            unsetRegional(state);
            return true;
        } else {
            setRegional(state);
            return false;
        }
    }

    // GB11: Emoji Extend* ZWJ x Emoji
    if (hasXpic(state) and
        gbp.isZwj(cp1) and
        emoji.isExtendedPictographic(cp2))
    {
        unsetXpic(state);
        return false;
    }

    return true;
}

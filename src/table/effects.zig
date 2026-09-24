//! Recognizable cell effects cannot be replayed safely in repeated sections.
//! This is deliberately not a TeX macro interpreter: opaque user macros remain
//! the caller's responsibility. The runtime also guards common primitives.
const std = @import("std");
const ast = @import("../parser/ast.zig");

fn textEffect(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') continue;
        const start = i + 1;
        i = start;
        while (i < text.len and (std.ascii.isAlphabetic(text[i]) or text[i] == '@')) : (i += 1) {}
        const command = text[start..i];
        inline for (.{ "global", "globaldefs", "gdef", "xdef", "stepcounter", "refstepcounter", "setcounter", "addtocounter", "insert", "vadjust", "write", "mark", "marks", "footnote", "footnotetext", "footnotemark", "marginpar", "label", "index", "hypertarget", "pdfdest", "shipout", "output", "eject", "supereject", "newpage", "clearpage", "pagebreak" }) |name| {
            if (std.mem.eql(u8, command, name)) return true;
        }
        if (i > start) i -= 1;
    }
    return false;
}

pub fn contains(stmts: []const ast.Stmt) bool {
    for (stmts) |s| switch (s) {
        .TextLit => |v| {
            if (textEffect(v.toStr())) return true;
        },
        .MathLit => |v| {
            if (textEffect(v)) return true;
        },
        .MathCtx => |v| {
            if (v.label != null or contains(v.inner.items)) return true;
        },
        .Braced => |v| {
            if (contains(v.inner.items)) return true;
        },
        .Fraction => |v| {
            if (contains(v.numerator.items) or contains(v.denominator.items)) return true;
        },
        .PlainTextInMath => |v| {
            if (contains(v.inner.items)) return true;
        },
        .DefineFunction => |v| {
            if (v.kind.global or contains(v.inner.items)) return true;
        },
        .Environment => |v| {
            if (v.label != null or contains(v.inner.items)) return true;
            inline for (.{ "figure", "figure*", "table", "table*" }) |name| if (v.name.eqlStr(name)) return true;
            for (v.args.items) |arg| if (contains(arg.ctx.items)) return true;
        },
        .PictureEnvironment => |v| {
            if (contains(v.inner.items)) return true;
        },
        .BeginPhantomEnviron => |v| {
            inline for (.{ "figure", "figure*", "table", "table*" }) |name| if (v.name.eqlStr(name)) return true;
            for (v.args.items) |arg| if (contains(arg.ctx.items)) return true;
        },
        .DocumentClass, .DocumentStart, .DocumentEnd, .ImportSinglePkg, .ImportMultiplePkgs, .DefineEnv => return true,
        // A nested table validates its own cell content during its emission.
        else => {},
    };
    return false;
}

test "cell effect recognition respects complete command names and escapes" {
    try std.testing.expect(textEffect("\\global\\advance\\count0 by1"));
    try std.testing.expect(textEffect("\\write16{bad}"));
    try std.testing.expect(textEffect("\\label{repeated}"));
    try std.testing.expect(!textEffect("\\globalization \\bf text \\& \\$"));
    try std.testing.expect(!textEffect("\\\\global"));
}

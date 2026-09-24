//! Structural table lowering. No font metrics are guessed here: dimensions,
//! border envelopes, and paragraph heights are resolved by the TeX backend.
const std = @import("std");
const model = @import("model.zig");
const Span = @import("../location.zig").Span;
const Allocator = std.mem.Allocator;

pub const Failure = struct {
    code: []const u8,
    message: []const u8,
    span: Span,
    related: ?Span = null,
    row: ?usize = null,
    column: ?usize = null,
};

/// The source AST must outlive the normalized plan. All coordinates are
/// zero-based; end coordinates are exclusive.
pub const Cell = struct {
    source: *const model.Cell,
    row: usize,
    col: usize,
    rowspan: usize,
    colspan: usize,
};

pub const Edge = struct {
    style: model.BorderStyle,
    span: Span,
    explicit: bool,
};

/// A style comparison depending on TeX units or phase normalization is deferred
/// instead of rejecting potentially identical explicit edges at compile time.
pub const DeferredConflict = struct {
    first: Edge,
    second: Edge,
};

pub const BreakBoundary = struct {
    forced: bool = false,
    forbidden: bool = false,
    source: ?Span = null,
    cause: ?enum { rowspan, keep, nobreak } = null,
};

pub const Group = struct {
    first: usize,
    end: usize,
};

pub const Section = struct {
    source: *const model.Section,
    row_count: usize,
    column_count: usize,
    cells: []Cell,
    /// Row-major cell indexes; every entry names exactly one normalized cell.
    occupancy: []usize,
    /// (row_count + 1) * column_count; one edge per column per row boundary.
    horizontal: []?Edge,
    /// row_count * (column_count + 1); one edge per row per column boundary.
    vertical: []?Edge,
    boundaries: []BreakBoundary,
    groups: []Group,
    deferred_conflicts: []DeferredConflict,

    pub fn hEdge(self: *const Section, boundary: usize, column: usize) ?Edge {
        return self.horizontal[boundary * self.column_count + column];
    }

    pub fn vEdge(self: *const Section, row: usize, boundary: usize) ?Edge {
        return self.vertical[row * (self.column_count + 1) + boundary];
    }

    pub fn deinit(self: *Section, allocator: Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.occupancy);
        allocator.free(self.horizontal);
        allocator.free(self.vertical);
        allocator.free(self.boundaries);
        allocator.free(self.groups);
        allocator.free(self.deferred_conflicts);
        self.* = undefined;
    }
};

pub const Normalized = struct {
    source: *const model.Table,
    sections: []Section,

    pub fn section(self: *const Normalized, kind: model.SectionKind) ?*const Section {
        for (self.sections) |*s| if (s.source.kind == kind) return s;
        return null;
    }

    pub fn effectiveSection(self: *const Normalized, kind: model.SectionKind) ?*const Section {
        if (self.section(kind)) |s| return s;
        return switch (kind) {
            .firsthead => self.section(.head),
            .lastfoot => self.section(.foot),
            else => null,
        };
    }

    pub fn deinit(self: *Normalized, allocator: Allocator) void {
        for (self.sections) |*s| s.deinit(allocator);
        allocator.free(self.sections);
        self.* = undefined;
    }
};

fn fail(failure: *?Failure, value: Failure) error{InvalidTable} {
    failure.* = value;
    return error.InvalidTable;
}

pub fn normalize(allocator: Allocator, table: *const model.Table, failure: *?Failure) !Normalized {
    failure.* = null;
    if (table.columns.items.len == 0) return fail(failure, .{
        .code = "T001",
        .message = "a table needs at least one column",
        .span = table.span,
    });
    var sections: std.ArrayList(Section) = .empty;
    errdefer {
        for (sections.items) |*s| s.deinit(allocator);
        sections.deinit(allocator);
    }
    for (table.sections.items) |*source| {
        var s = try normalizeSection(allocator, table, source, failure);
        errdefer s.deinit(allocator);
        try sections.append(allocator, s);
    }
    return .{ .source = table, .sections = try sections.toOwnedSlice(allocator) };
}

fn normalizeSection(allocator: Allocator, table: *const model.Table, source: *const model.Section, failure: *?Failure) !Section {
    const cols = table.columns.items.len;
    const rows = source.rows.items.len;
    const count = std.math.mul(usize, rows, cols) catch return fail(failure, .{
        .code = "T004",
        .message = "the table grid is too large",
        .span = source.span,
    });
    const hcount = std.math.add(usize, count, cols) catch return error.OutOfMemory;
    const vcount = std.math.add(usize, count, rows) catch return error.OutOfMemory;
    const vacant = std.math.maxInt(usize);
    const occupancy = try allocator.alloc(usize, count);
    errdefer allocator.free(occupancy);
    @memset(occupancy, vacant);
    const horizontal = try allocator.alloc(?Edge, hcount);
    errdefer allocator.free(horizontal);
    @memset(horizontal, null);
    const vertical = try allocator.alloc(?Edge, vcount);
    errdefer allocator.free(vertical);
    @memset(vertical, null);
    const boundaries = try allocator.alloc(BreakBoundary, rows + 1);
    errdefer allocator.free(boundaries);
    @memset(boundaries, .{});
    var cells: std.ArrayList(Cell) = .empty;
    errdefer cells.deinit(allocator);
    var groups: std.ArrayList(Group) = .empty;
    errdefer groups.deinit(allocator);
    var conflicts: std.ArrayList(DeferredConflict) = .empty;
    errdefer conflicts.deinit(allocator);

    for (source.rows.items, 0..) |*row, r| {
        var col: usize = 0;
        for (row.cells.items) |*cell| {
            while (col < cols and occupancy[r * cols + col] != vacant) : (col += 1) {}
            if (col == cols) return fail(failure, .{
                .code = "T002",
                .message = "this row has more cells than available columns; omit cells covered by earlier rowspans",
                .span = cell.span,
                .row = r + 1,
                .column = col + 1,
            });
            const cs = cell.options.colspan;
            const rs = cell.options.rowspan;
            if (cs == 0 or rs == 0 or cs > cols - col or rs > rows - r) return fail(failure, .{
                .code = "T004",
                .message = "this cell span extends outside its section; reduce the span or add rows/columns",
                .span = cell.span,
                .row = r + 1,
                .column = col + 1,
            });
            for (r..r + rs) |rr| for (col..col + cs) |cc| {
                const previous = occupancy[rr * cols + cc];
                if (previous != vacant) return fail(failure, .{
                    .code = "T003",
                    .message = "this cell rectangle overlaps an earlier rowspan; reduce or reposition the span",
                    .span = cell.span,
                    .related = cells.items[previous].source.span,
                    .row = rr + 1,
                    .column = cc + 1,
                });
                occupancy[rr * cols + cc] = cells.items.len;
            };
            const column = table.columns.items[col];
            const wrap = cell.options.wrap orelse column.wrap orelse (column.width != .natural);
            if (wrap) {
                var finite = false;
                for (table.columns.items[col .. col + cs]) |track| {
                    if (track.width != .natural) finite = true;
                }
                if (!finite) return fail(failure, .{
                    .code = "T005",
                    .message = "wrapped cells need a fixed or flex width; add a finite-width column to this span or use wrap=no",
                    .span = cell.span,
                    .row = r + 1,
                    .column = col + 1,
                });
            }
            try cells.append(allocator, .{ .source = cell, .row = r, .col = col, .rowspan = rs, .colspan = cs });
            for (r + 1..r + rs) |boundary| {
                boundaries[boundary] = .{ .forbidden = true, .source = cell.span, .cause = .rowspan };
            }
            col += cs;
        }
        for (0..cols) |c| if (occupancy[r * cols + c] == vacant) return fail(failure, .{
            .code = "T002",
            .message = "this row leaves an unfilled column; insert cell {} for an intentional empty cell",
            .span = row.span,
            .row = r + 1,
            .column = c + 1,
        });
    }

    for (source.keeps.items) |keep| {
        if (source.kind != .body or keep.first >= keep.end or keep.end > rows) return fail(failure, .{
            .code = "T007",
            .message = "keep must contain one or more complete body rows",
            .span = keep.span,
        });
        for (keep.first + 1..keep.end) |boundary| {
            if (!boundaries[boundary].forbidden)
                boundaries[boundary] = .{ .forbidden = true, .source = keep.span, .cause = .keep };
        }
    }
    // Collect all no-break connections before checking forced breaks so that
    // directive source order cannot change whether a boundary is legal.
    for (source.boundaries.items) |boundary| {
        if (table.kind != .long or source.kind != .body or boundary.after == 0 or boundary.after >= rows) return fail(failure, .{
            .code = "T007",
            .message = "break and nobreak are allowed only between long-table body rows",
            .span = boundary.span,
        });
        if (boundary.kind == .forbid and !boundaries[boundary.after].forbidden)
            boundaries[boundary.after] = .{ .forbidden = true, .source = boundary.span, .cause = .nobreak };
    }
    for (source.boundaries.items) |boundary| if (boundary.kind == .force) {
        const edge = &boundaries[boundary.after];
        if (edge.forbidden) return fail(failure, .{
            .code = "T007",
            .message = "forced page break falls inside a rowspan, keep, or nobreak group; move it outside the connected rows",
            .span = boundary.span,
            .related = edge.source,
            .row = boundary.after + 1,
        });
        edge.forced = true;
        edge.source = boundary.span;
    };
    var first: usize = 0;
    for (1..rows + 1) |boundary| {
        if (boundary == rows or !boundaries[boundary].forbidden) {
            try groups.append(allocator, .{ .first = first, .end = boundary });
            first = boundary;
        }
    }

    const base = Edge{ .style = table.options.border, .span = table.span, .explicit = false };
    for (0..rows + 1) |r| for (0..cols) |c| {
        const outside = r == 0 or r == rows;
        const enabled = switch (table.options.grid) {
            .all => true,
            .frame => outside,
            .rows => !outside,
            .none, .columns => false,
        };
        const merged = !outside and occupancy[(r - 1) * cols + c] == occupancy[r * cols + c];
        // An explicitly empty repeated section disables inheritance and has no
        // automatic frame of its own. Otherwise its phantom top frame would
        // reserve an extra band before the actual body's top border.
        if (rows > 0 and enabled and !merged) horizontal[r * cols + c] = base;
    };
    for (0..rows) |r| for (0..cols + 1) |c| {
        const outside = c == 0 or c == cols;
        const enabled = switch (table.options.grid) {
            .all => true,
            .frame => outside,
            .columns => !outside,
            .none, .rows => false,
        };
        const merged = !outside and occupancy[r * cols + c - 1] == occupancy[r * cols + c];
        if (enabled and !merged) vertical[r * (cols + 1) + c] = base;
    };
    for (source.hlines.items) |line| {
        const end = line.to orelse cols;
        if (line.boundary > rows or line.from == 0 or line.from > end or end > cols) return fail(failure, .{
            .code = "T001",
            .message = "hline needs a valid row boundary and an inclusive column range from 1 to the column count",
            .span = line.span,
        });
        const style = try validateRule(line.style, table.options.border, line.span, failure);
        const edge = Edge{ .style = style, .span = line.span, .explicit = true };
        for (line.from - 1..end) |c| {
            const r = line.boundary;
            if (r > 0 and r < rows and occupancy[(r - 1) * cols + c] == occupancy[r * cols + c]) return fail(failure, .{
                .code = "T006",
                .message = "hline cuts a merged cell; restrict from/to to exposed columns",
                .span = line.span,
                .related = cells.items[occupancy[r * cols + c]].source.span,
                .row = r + 1,
                .column = c + 1,
            });
            try applyEdge(allocator, &horizontal[r * cols + c], edge, &conflicts, failure);
        }
    }
    for (source.vlines.items) |line| {
        const end = line.to orelse rows;
        if (line.after > cols or line.from == 0 or line.from > end or end > rows) return fail(failure, .{
            .code = "T001",
            .message = "vline needs after=0..column-count and an inclusive row range from 1 to the section row count",
            .span = line.span,
        });
        const style = try validateRule(line.style, table.options.border, line.span, failure);
        const edge = Edge{ .style = style, .span = line.span, .explicit = true };
        for (line.from - 1..end) |r| {
            const c = line.after;
            if (c > 0 and c < cols and occupancy[r * cols + c - 1] == occupancy[r * cols + c]) return fail(failure, .{
                .code = "T006",
                .message = "vline cuts a merged cell; restrict from/to to exposed rows",
                .span = line.span,
                .related = cells.items[occupancy[r * cols + c]].source.span,
                .row = r + 1,
                .column = c + 1,
            });
            try applyEdge(allocator, &vertical[r * (cols + 1) + c], edge, &conflicts, failure);
        }
    }
    const owned_cells = try cells.toOwnedSlice(allocator);
    errdefer allocator.free(owned_cells);
    const owned_groups = try groups.toOwnedSlice(allocator);
    errdefer allocator.free(owned_groups);
    return .{
        .source = source,
        .row_count = rows,
        .column_count = cols,
        .cells = owned_cells,
        .occupancy = occupancy,
        .horizontal = horizontal,
        .vertical = vertical,
        .boundaries = boundaries,
        .groups = owned_groups,
        .deferred_conflicts = try conflicts.toOwnedSlice(allocator),
    };
}

fn validateRule(options: model.BorderOptions, base: model.BorderStyle, span: Span, failure: *?Failure) !model.BorderStyle {
    const style = options.resolve(base);
    const solid = style.style == .solid;
    const repeating = style.style != .solid and style.style != .double;
    const dashed = style.style == .dashed or style.style == .dashdot or style.style == .dashdotdot;
    if ((solid and options.gap != null) or (!dashed and options.dashlength != null) or (!repeating and options.phase != null)) return fail(failure, .{
        .code = "T011",
        .message = "border option does not apply to this style: gap needs a nonsolid style, dashlength needs dashes, and phase needs a repeating pattern",
        .span = span,
    });
    return style;
}

fn applyEdge(allocator: Allocator, target: *?Edge, edge: Edge, conflicts: *std.ArrayList(DeferredConflict), failure: *?Failure) !void {
    if (target.*) |old| if (old.explicit) {
        switch (compareStyles(old.style, edge.style)) {
            .equal => return,
            .different => return fail(failure, .{
                .code = "T012",
                .message = "overlapping explicit borders have different styles; use identical signatures or nonoverlapping ranges",
                .span = edge.span,
                .related = old.span,
            }),
            .runtime => {
                // One check per declaration pair, not one per overlapped track.
                for (conflicts.items) |check| {
                    if (std.meta.eql(check.first.span, old.span) and std.meta.eql(check.second.span, edge.span) and
                        std.meta.eql(check.first.style, old.style) and std.meta.eql(check.second.style, edge.style)) return;
                }
                try conflicts.append(allocator, .{ .first = old, .second = edge });
                return;
            },
        }
    };
    target.* = edge;
}

pub const StyleComparison = enum { equal, different, runtime };

/// Exact symbolic comparison intentionally defers unit conversion and phase
/// modulo arithmetic to TeX, which rounds dimensions to scaled points.
pub fn compareStyles(a: model.BorderStyle, b: model.BorderStyle) StyleComparison {
    if (a.style != b.style or !std.meta.eql(a.color, b.color)) return .different;
    var result = compareDim(a.thickness, b.thickness);
    if (a.style != .solid) result = combine(result, compareAuto(a.gap, b.gap, a.thickness, b.thickness, if (a.style == .double) 1 else 2));
    if (a.style == .dashed or a.style == .dashdot or a.style == .dashdotdot)
        result = combine(result, compareAuto(a.dashlength, b.dashlength, a.thickness, b.thickness, 4));
    if (a.style != .solid and a.style != .double and !std.meta.eql(a.phase, b.phase)) {
        // Even apparently different phases can be equal modulo their cycle.
        result = combine(result, .runtime);
    }
    return result;
}

fn combine(a: StyleComparison, b: StyleComparison) StyleComparison {
    if (a == .different or b == .different) return .different;
    if (a == .runtime or b == .runtime) return .runtime;
    return .equal;
}

fn compareDim(a: model.Dim, b: model.Dim) StyleComparison {
    if (std.meta.eql(a, b)) return .equal;
    // Decimal dimensions can differ by less than a scaled point; only TeX can
    // make the authoritative comparison after its own scanning/conversion.
    return .runtime;
}

fn compareAuto(a: model.AutoDim, b: model.AutoDim, at: model.Dim, bt: model.Dim, factor: f64) StyleComparison {
    const ad: model.Dim = switch (a) {
        .auto => .{ .value = at.value * factor, .unit = at.unit },
        .dimension => |d| d,
    };
    const bd: model.Dim = switch (b) {
        .auto => .{ .value = bt.value * factor, .unit = bt.unit },
        .dimension => |d| d,
    };
    return compareDim(ad, bd);
}

fn testTable(allocator: Allocator, cols: usize, rows: []const []const model.CellOptions) !model.Table {
    var table = model.Table{ .kind = .long };
    errdefer table.deinit(allocator);
    for (0..cols) |_| try table.columns.append(allocator, .{ .width = .{ .dimension = model.Dim.pt(30) } });
    var section_: model.Section = .{ .kind = .body };
    errdefer section_.deinit(allocator);
    for (rows, 0..) |source, r| {
        var row: model.Row = .{ .span = .{ .start = .{ .row = r + 10 } } };
        errdefer row.deinit(allocator);
        for (source, 0..) |options, c| try row.cells.append(allocator, .{
            .options = options,
            .span = .{ .start = .{ .row = r + 10, .col = c + 1 } },
        });
        try section_.rows.append(allocator, row);
    }
    try table.sections.append(allocator, section_);
    return table;
}

test "occupancy skips rowspans and removes only internal merged grid edges" {
    const a = std.testing.allocator;
    var table = try testTable(a, 3, &.{
        &.{ .{ .rowspan = 2 }, .{ .colspan = 2 } },
        &.{ .{}, .{} },
    });
    defer table.deinit(a);
    table.options.grid = .all;
    var failure: ?Failure = null;
    var plan = try normalize(a, &table, &failure);
    defer plan.deinit(a);
    const s = plan.section(.body).?;
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 1, 0, 2, 3 }, s.occupancy);
    try std.testing.expectEqual(@as(usize, 1), s.cells[2].col);
    try std.testing.expect(s.hEdge(1, 0) == null);
    try std.testing.expect(s.hEdge(1, 1) != null);
    try std.testing.expect(s.vEdge(0, 2) == null);
    try std.testing.expect(s.vEdge(1, 2) != null);
    try std.testing.expectEqual(@as(usize, 1), s.groups.len);
    try std.testing.expectEqual(@as(usize, 2), s.groups[0].end);
}

test "incomplete row identifies first unfilled coordinate" {
    const a = std.testing.allocator;
    var table = try testTable(a, 2, &.{&.{.{}}});
    defer table.deinit(a);
    var failure: ?Failure = null;
    try std.testing.expectError(error.InvalidTable, normalize(a, &table, &failure));
    try std.testing.expectEqualStrings("T002", failure.?.code);
    try std.testing.expectEqual(@as(?usize, 2), failure.?.column);
}

test "overlapping rectangular span gives both source locations" {
    const a = std.testing.allocator;
    var table = try testTable(a, 3, &.{
        &.{ .{}, .{ .rowspan = 2 }, .{} },
        &.{.{ .colspan = 2 }},
    });
    defer table.deinit(a);
    var failure: ?Failure = null;
    try std.testing.expectError(error.InvalidTable, normalize(a, &table, &failure));
    try std.testing.expectEqualStrings("T003", failure.?.code);
    try std.testing.expectEqual(@as(usize, 10), failure.?.related.?.start.row);
    try std.testing.expectEqual(@as(usize, 11), failure.?.span.start.row);
}

test "spans cannot extend past section and empty covered rows are legal" {
    const a = std.testing.allocator;
    var table = try testTable(a, 1, &.{ &.{.{ .rowspan = 2 }}, &.{} });
    defer table.deinit(a);
    var failure: ?Failure = null;
    var plan = try normalize(a, &table, &failure);
    plan.deinit(a);
    table.sections.items[0].rows.items[0].cells.items[0].options.rowspan = 3;
    try std.testing.expectError(error.InvalidTable, normalize(a, &table, &failure));
    try std.testing.expectEqualStrings("T004", failure.?.code);
}

test "partial explicit rules preserve merges and full rules reject cuts" {
    const a = std.testing.allocator;
    var table = try testTable(a, 2, &.{ &.{ .{ .rowspan = 2 }, .{} }, &.{.{}} });
    defer table.deinit(a);
    try table.sections.items[0].hlines.append(a, .{ .boundary = 1, .from = 2 });
    var failure: ?Failure = null;
    var plan = try normalize(a, &table, &failure);
    try std.testing.expect(plan.sections[0].hEdge(1, 0) == null);
    try std.testing.expect(plan.sections[0].hEdge(1, 1).?.explicit);
    plan.deinit(a);
    table.sections.items[0].hlines.items[0].from = 1;
    try std.testing.expectError(error.InvalidTable, normalize(a, &table, &failure));
    try std.testing.expectEqualStrings("T006", failure.?.code);
    try std.testing.expect(failure.?.related != null);
}

test "vertical explicit rules reject merged colspan interiors" {
    const a = std.testing.allocator;
    var table = try testTable(a, 2, &.{&.{.{ .colspan = 2 }}});
    defer table.deinit(a);
    try table.sections.items[0].vlines.append(a, .{ .after = 1 });
    var failure: ?Failure = null;
    try std.testing.expectError(error.InvalidTable, normalize(a, &table, &failure));
    try std.testing.expectEqualStrings("T006", failure.?.code);
}

test "grid rows and columns exclude frame" {
    const a = std.testing.allocator;
    var table = try testTable(a, 2, &.{ &.{ .{}, .{} }, &.{ .{}, .{} } });
    defer table.deinit(a);
    var failure: ?Failure = null;
    table.options.grid = .rows;
    var rows = try normalize(a, &table, &failure);
    defer rows.deinit(a);
    try std.testing.expect(rows.sections[0].hEdge(0, 0) == null);
    try std.testing.expect(rows.sections[0].hEdge(1, 0) != null);
    try std.testing.expect(rows.sections[0].hEdge(2, 0) == null);
    for (rows.sections[0].vertical) |edge| try std.testing.expect(edge == null);
    table.options.grid = .columns;
    var cols = try normalize(a, &table, &failure);
    defer cols.deinit(a);
    try std.testing.expect(cols.sections[0].vEdge(0, 0) == null);
    try std.testing.expect(cols.sections[0].vEdge(0, 1) != null);
    try std.testing.expect(cols.sections[0].vEdge(0, 2) == null);
    for (cols.sections[0].horizontal) |edge| try std.testing.expect(edge == null);
}

test "overlapping explicit styles coalesce while conflicting colors fail" {
    const a = std.testing.allocator;
    var table = try testTable(a, 2, &.{&.{ .{}, .{} }});
    defer table.deinit(a);
    const s = &table.sections.items[0];
    try s.hlines.append(a, .{ .boundary = 0 });
    try s.hlines.append(a, .{ .boundary = 0, .from = 2 });
    var failure: ?Failure = null;
    var plan = try normalize(a, &table, &failure);
    try std.testing.expectEqual(@as(usize, 0), plan.sections[0].deferred_conflicts.len);
    plan.deinit(a);
    s.hlines.items[1].style.color = .{ .rgb = .{ 0, 0, 0 } };
    try std.testing.expectError(error.InvalidTable, normalize(a, &table, &failure));
    try std.testing.expectEqualStrings("T012", failure.?.code);
}

test "dimension equivalence and normalized phases defer to runtime" {
    const a = std.testing.allocator;
    var table = try testTable(a, 2, &.{&.{ .{}, .{} }});
    defer table.deinit(a);
    const s = &table.sections.items[0];
    try s.hlines.append(a, .{ .boundary = 0, .style = .{ .thickness = .{ .value = 1, .unit = .pc } } });
    try s.hlines.append(a, .{ .boundary = 0, .style = .{ .thickness = model.Dim.pt(12) } });
    var failure: ?Failure = null;
    var plan = try normalize(a, &table, &failure);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), plan.sections[0].deferred_conflicts.len);
    try std.testing.expectEqual(StyleComparison.runtime, compareStyles(
        .{ .style = .dotted, .phase = model.Dim.pt(0) },
        .{ .style = .dotted, .phase = model.Dim.pt(1.2) },
    ));
}

test "style signatures ignore dormant controls and use final local thickness for auto" {
    try std.testing.expectEqual(StyleComparison.equal, compareStyles(
        .{ .style = .solid, .gap = .{ .dimension = model.Dim.pt(8) } },
        .{ .style = .solid, .phase = model.Dim.pt(9) },
    ));
    try std.testing.expectEqual(StyleComparison.equal, compareStyles(
        .{ .style = .dashdotdot, .thickness = model.Dim.pt(2) },
        .{ .style = .dashdotdot, .thickness = model.Dim.pt(2), .gap = .{ .dimension = model.Dim.pt(4) }, .dashlength = .{ .dimension = model.Dim.pt(8) } },
    ));
}

test "all six border patterns inherit automatic edges and accept explicit overrides" {
    const a = std.testing.allocator;
    inline for (std.meta.tags(model.Pattern)) |pattern| {
        var table = try testTable(a, 1, &.{&.{.{}}});
        defer table.deinit(a);
        table.options.grid = .all;
        table.options.border.style = pattern;
        table.options.border.color = .{ .cmyk = .{ 0.2, 0.3, 0.4, 0.5 } };
        try table.sections.items[0].hlines.append(a, .{ .boundary = 0, .style = .{ .thickness = model.Dim.pt(2) } });
        try table.sections.items[0].vlines.append(a, .{ .after = 0, .style = .{ .thickness = model.Dim.pt(3) } });
        var failure: ?Failure = null;
        var plan = try normalize(a, &table, &failure);
        defer plan.deinit(a);
        try std.testing.expectEqual(pattern, plan.sections[0].hEdge(0, 0).?.style.style);
        try std.testing.expectEqual(@as(f64, 2), plan.sections[0].hEdge(0, 0).?.style.thickness.value);
        try std.testing.expectEqual(@as(f64, 3), plan.sections[0].vEdge(0, 0).?.style.thickness.value);
        try std.testing.expectEqual(pattern, plan.sections[0].vEdge(0, 1).?.style.style);
    }
}

test "inapplicable explicit pattern controls diagnose T011" {
    const a = std.testing.allocator;
    var table = try testTable(a, 1, &.{&.{.{}}});
    defer table.deinit(a);
    try table.sections.items[0].hlines.append(a, .{ .boundary = 0, .style = .{ .phase = model.Dim.pt(0) } });
    var failure: ?Failure = null;
    try std.testing.expectError(error.InvalidTable, normalize(a, &table, &failure));
    try std.testing.expectEqualStrings("T011", failure.?.code);
}

test "rowspans keeps and nobreaks form transitive groups and reject internal force" {
    const a = std.testing.allocator;
    var table = try testTable(a, 2, &.{
        &.{ .{ .rowspan = 2 }, .{} }, &.{.{}}, &.{ .{}, .{} }, &.{ .{}, .{} }, &.{ .{}, .{} },
    });
    defer table.deinit(a);
    const s = &table.sections.items[0];
    try s.keeps.append(a, .{ .first = 1, .end = 3 });
    try s.boundaries.append(a, .{ .after = 3, .kind = .forbid });
    try s.boundaries.append(a, .{ .after = 4, .kind = .force });
    var failure: ?Failure = null;
    var plan = try normalize(a, &table, &failure);
    try std.testing.expectEqual(@as(usize, 2), plan.sections[0].groups.len);
    try std.testing.expectEqual(@as(usize, 4), plan.sections[0].groups[0].end);
    try std.testing.expect(plan.sections[0].boundaries[4].forced);
    plan.deinit(a);
    s.boundaries.items[1].after = 2;
    try std.testing.expectError(error.InvalidTable, normalize(a, &table, &failure));
    try std.testing.expectEqualStrings("T007", failure.?.code);
}

test "explicit empty repeated sections override fallback inheritance" {
    const a = std.testing.allocator;
    var table = try testTable(a, 1, &.{&.{.{}}});
    defer table.deinit(a);
    table.options.grid = .all;
    try table.sections.append(a, .{ .kind = .head });
    var failure: ?Failure = null;
    var plan = try normalize(a, &table, &failure);
    try std.testing.expectEqual(model.SectionKind.head, plan.effectiveSection(.firsthead).?.source.kind);
    plan.deinit(a);
    try table.sections.append(a, .{ .kind = .firsthead });
    plan = try normalize(a, &table, &failure);
    defer plan.deinit(a);
    try std.testing.expectEqual(model.SectionKind.firsthead, plan.effectiveSection(.firsthead).?.source.kind);
    for (plan.effectiveSection(.firsthead).?.horizontal) |edge| try std.testing.expect(edge == null);
}

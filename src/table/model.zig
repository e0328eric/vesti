//! Typed native-table syntax. Dimensions remain unresolved until table entry.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const Allocator = std.mem.Allocator;
const List = std.ArrayList;
pub const Span = @import("../location.zig").Span;
pub const Kind = enum { short, long };
pub const Align = enum { left, center, right };
pub const VAlign = enum { top, middle, bottom };
pub const Grid = enum { none, frame, rows, columns, all };
pub const Unit = enum { pt, pc, in, bp, cm, mm, dd, cc, sp, em, ex };
pub const Register = enum { hsize, vsize };
pub const Dim = struct {
    value: f64,
    unit: Unit = .pt,
    pub fn pt(value: f64) Dim {
        return .{ .value = value };
    }
};
pub const Width = union(enum) { natural, dimension: Dim, register: Register, flex: f64 };
pub const AutoDim = union(enum) { auto, dimension: Dim };
pub const Color = union(enum) { gray: f64, rgb: [3]f64, cmyk: [4]f64 };
pub const Pattern = enum { solid, double, dotted, dashed, dashdot, dashdotdot };
pub const BorderStyle = struct {
    style: Pattern = .solid,
    thickness: Dim = Dim.pt(0.4),
    color: Color = .{ .gray = 0 },
    gap: AutoDim = .auto,
    dashlength: AutoDim = .auto,
    phase: Dim = Dim.pt(0),
};
pub const BorderOptions = struct {
    style: ?Pattern = null,
    thickness: ?Dim = null,
    color: ?Color = null,
    gap: ?AutoDim = null,
    dashlength: ?AutoDim = null,
    phase: ?Dim = null,
    pub fn resolve(self: BorderOptions, base: BorderStyle) BorderStyle {
        return .{ .style = self.style orelse base.style, .thickness = self.thickness orelse base.thickness, .color = self.color orelse base.color, .gap = self.gap orelse base.gap, .dashlength = self.dashlength orelse base.dashlength, .phase = self.phase orelse base.phase };
    }
};
pub const TableOptions = struct {
    width: Width = .natural,
    pageheight: ?Width = null,
    @"align": Align = .center,
    grid: Grid = .none,
    border: BorderStyle = .{},
    padx: Dim = Dim.pt(4),
    pady: Dim = Dim.pt(3),
    minheight: Dim = Dim.pt(0),
    valign: VAlign = .middle,
};
fn freeContent(allocator: Allocator, body: *List(ast.Stmt)) void {
    for (body.items) |*stmt| stmt.deinit(allocator);
    body.deinit(allocator);
}
pub const Column = struct {
    width: Width = .natural,
    @"align": Align = .left,
    valign: ?VAlign = null,
    wrap: ?bool = null,
    before: List(ast.Stmt) = .empty,
    span: Span = .{},
    pub fn deinit(self: *Column, allocator: Allocator) void {
        freeContent(allocator, &self.before);
    }
};
pub const RowOptions = struct {
    minheight: ?Dim = null,
    background: ?Color = null,
    before: List(ast.Stmt) = .empty,
};
pub const CellOptions = struct {
    colspan: usize = 1,
    rowspan: usize = 1,
    @"align": ?Align = null,
    valign: ?VAlign = null,
    wrap: ?bool = null,
    background: ?Color = null,
    before: List(ast.Stmt) = .empty,
};
pub const Cell = struct {
    options: CellOptions = .{},
    body: List(ast.Stmt) = .empty,
    span: Span = .{},
    pub fn deinit(self: *Cell, allocator: Allocator) void {
        freeContent(allocator, &self.options.before);
        freeContent(allocator, &self.body);
    }
};
pub const Row = struct {
    options: RowOptions = .{},
    cells: List(Cell) = .empty,
    span: Span = .{},
    pub fn deinit(self: *Row, allocator: Allocator) void {
        freeContent(allocator, &self.options.before);
        for (self.cells.items) |*cell| cell.deinit(allocator);
        self.cells.deinit(allocator);
    }
};
pub const HRule = struct { boundary: usize, from: usize = 1, to: ?usize = null, style: BorderOptions = .{}, span: Span = .{} };
pub const VRule = struct { after: usize = 0, from: usize = 1, to: ?usize = null, style: BorderOptions = .{}, span: Span = .{} };
pub const Boundary = struct { after: usize, kind: enum { force, forbid }, span: Span = .{} };
pub const Keep = struct { first: usize, end: usize, span: Span = .{} };
pub const SectionKind = enum { body, firsthead, head, foot, lastfoot };
pub const Section = struct {
    kind: SectionKind,
    rows: List(Row) = .empty,
    hlines: List(HRule) = .empty,
    vlines: List(VRule) = .empty,
    boundaries: List(Boundary) = .empty,
    keeps: List(Keep) = .empty,
    span: Span = .{},
    pub fn deinit(self: *Section, allocator: Allocator) void {
        for (self.rows.items) |*row| row.deinit(allocator);
        self.rows.deinit(allocator);
        self.hlines.deinit(allocator);
        self.vlines.deinit(allocator);
        self.boundaries.deinit(allocator);
        self.keeps.deinit(allocator);
    }
};
pub const Table = struct {
    kind: Kind,
    options: TableOptions = .{},
    columns: List(Column) = .empty,
    sections: List(Section) = .empty,
    span: Span = .{},
    pub fn section(self: *const Table, kind: SectionKind) ?*const Section {
        for (self.sections.items) |*s| if (s.kind == kind) {
            return s;
        };
        return null;
    }
    pub fn deinit(self: *Table, allocator: Allocator) void {
        for (self.columns.items) |*col| col.deinit(allocator);
        for (self.sections.items) |*s| s.deinit(allocator);
        self.columns.deinit(allocator);
        self.sections.deinit(allocator);
    }
};

# Native tables

`#tabular` builds one indivisible table. `#longtabular` continues a table across
dedicated pages, repeating its header and footer. Both use TeX boxes, dimensions,
glue, and rules; the feature imports no LaTeX table, graphics, or color package.
It does not emit a LaTeX `tabular` or `longtable` environment.

See [native_tables.ves](../examples/native_tables.ves) for the stock layout and
six border patterns, and [native_longtable.ves](../examples/native_longtable.ves)
for repeated sections, wrapping, rowspans, and page breaks.

## Structure

```vesti
#tabular(width=240pt, grid=all) {
  columns {
    col(width=flex(1), align=center);
    col(width=flex(2));
  }
  body {
    row { cell(colspan=2) { A spanning title } }
    row { cell(rowspan=2) { A } cell { First detail } }
    row { cell { Second detail } }
  }
}
```

Write `columns` first, then sections. Every column requires a `width` key. Exactly
one nonempty `body` section is required. `row` contains explicit `cell` blocks;
write `cell {}` for an empty cell. A rowspan occupies its later rows automatically,
so omit cells for those occupied positions. Every remaining position must be
filled. Spans are rectangular and cannot cross a section boundary.

Cell contents and `before={...}` use the ordinary Vesti parser. They can contain
math, nested braces, Unicode, raw TeX, and other Vesti statements. Ampersands and
newlines are not cell or row separators. Escape text such as `\&` and `\$` in the
usual way. Structural names such as `row` and `body` remain ordinary words outside
these builtins. Existing `useenv tabular` documents retain their existing meaning.
Native tables are text boxes and cannot appear inside math mode.
A short native table nested inside a cell must specify an explicit finite width.

Cells and `before` hooks must form reusable local boxes. Recognized global
assignments, writes, labels, indexes, footnotes, floats, insertions, marks, and
page/output changes are rejected with `T010`; runtime guards also catch common
commands hidden inside macros. Arbitrary user macros are opaque to static
analysis, so the document author must keep their expansion local and free of
these effects. Ordinary local font changes and prebuilt image boxes are valid.

Vesti's existing comment syntax still applies inside cells: `--` starts a comment.
Use `41--!54` or a literal Unicode en dash for a range, rather than raw TeX's
`41--54`.

## Options

An option list is `(key=value, key=value)`, with an optional trailing comma.
Unknown or repeated keys, empty option lists, and values of the wrong type are
errors. Indentation and newlines between structural items are insignificant.

| Construct | Options |
| --- | --- |
| Both tables | `width=natural`, `align=center`, `grid=none`, `padx=4pt`, `pady=3pt`, `minheight=0pt`, `valign=middle`, and border defaults below |
| Long table | Required finite `width` and `pageheight`; no natural columns |
| `col` | Required `width`; `align=left`; optional `valign`, `wrap`, `before` |
| `row` | Optional `minheight`, `background`, `before` |
| `cell` | `colspan=1`, `rowspan=1`; optional `align`, `valign`, `wrap`, `background`, `before` |

Horizontal alignment is `left`, `center`, or `right`; vertical alignment is `top`,
`middle`, or `bottom`. The table's `align` positions the entire table. A cell
inherits alignment and wrapping from its starting column. Columns inherit the
table's vertical alignment. Fixed and flex columns wrap by default; natural
columns do not. Set `wrap=yes` or `wrap=no` explicitly to override that choice.

Run local `before` content in starting-column, row, then cell order. Use it for
font or paragraph settings. A cell's `background` overrides its originating row's
background; otherwise it is transparent. A rowspan retains one background over
its complete rectangle.

Widths may be `natural`, a positive dimension, or `flex(positive_weight)`. Only
column widths accept `flex`; flex columns require a finite table width. Only the
table's `width` and `pageheight` also accept `\hsize` or `\vsize`. `pageheight`
does not accept `natural`. Resolve registers and relative units at table entry.

Dimensions consist of an unsigned decimal followed immediately by `pt`, `pc`,
`in`, `bp`, `cm`, `mm`, `dd`, `cc`, `sp`, `em`, or `ex`, for example `.6pt` and
`3em`. Signs, exponent notation, arithmetic expressions, and arbitrary TeX
expansion are not structural values. Widths, pageheight, and border thickness
must be positive; padding, minimum heights, and phase may be zero. Spans are
positive integers. Colors are `gray(g)`, `rgb(r,g,b)`, or `cmyk(c,m,y,k)` with
every component between zero and one.

Tracks include horizontal cell padding; border lanes occupy additional space.
Natural columns use measured content, and flex columns share the remaining
width in proportion to their weights. A table without flex columns must match
its specified finite width, including border lanes. Unwrapped content that does
not fit is an error. Wrapped content needs a resolved finite width.

## Borders

`grid` accepts `none`, `frame`, `rows`, `columns`, or `all`. `rows` and `columns`
draw interior boundaries; `all` also includes the frame. Merged cells suppress
automatic interior edges.

| Table default | Per-rule override | Meaning |
| --- | --- | --- |
| `rulestyle=solid` | `style` | `solid`, `double`, `dotted`, `dashed`, `dashdot`, `dashdotdot` |
| `rulewidth=.4pt` | `thickness` | Thickness of one stroke |
| `rulecolor=gray(0)` | `color` | Stroke color |
| `rulegap=auto` | `gap` | Clear distance between marks or double strokes |
| `ruledashlength=auto` | `dashlength` | Length of dash marks |
| `rulephase=0pt` | `phase` | Distance into the repeating pattern at the run's start |

Add a horizontal rule at the current row boundary using `hline;` or
`hline(from=2, to=3, style=dotted, color=rgb(.2,.4,.7));`. Its inclusive column
range defaults to the full width. Add a vertical rule with
`vline(after=0, from=1, to=3, style=double);`. `after` is required and numbers
column boundaries from zero through the number of columns. Its inclusive row
range defaults to all rows in its own section; its source position is irrelevant.

Rules replace automatic grid edges in their ranges. An explicit rule cannot cut
through a merged cell. Identical overlapping rules coalesce, while incompatible
overlapping styles are errors. Row and column ranges are one-based and inclusive.

`auto` uses the rule's final thickness: a double gap is one thickness, other
pattern gaps are two thicknesses, and a dash is four thicknesses. Explicit
`gap=auto` and `dashlength=auto` reset inherited numeric defaults. A double border
reserves `2 * thickness + gap`; other styles reserve one thickness. This space
affects table widths, row heights, and page fitting.

Dots are squares made from TeX rules. `dashdot` repeats dash, gap, dot, gap;
`dashdotdot` repeats dash, gap, dot, gap, dot, gap. Patterns start at the left or
top, normalize phase modulo their period, and clip to endpoints. Clear gaps are
transparent. Adjacent collinear edges with the same style form a continuous
pattern run. A merge interruption, style change, or page cut restarts the phase.
Horizontal ink paints over vertical ink at crossings. There are no rounded dots,
rounded corners, or mitered joins.

On an individual rule, `gap` requires a nonsolid style, `dashlength` requires a
style containing dashes, and `phase` requires a repeating pattern. Inapplicable
explicit rule controls are errors. Table-level defaults can remain dormant until
a corresponding style uses them.

## Long tables

```vesti
#longtabular(width=\hsize, pageheight=6in, grid=all) {
  columns { col(width=flex(1)); col(width=flex(3)); }
  firsthead { row { cell(colspan=2) { Report } } }
  head { row { cell { Item } cell { Detail } } }
  foot { row { cell(colspan=2) { Continued... } } }
  lastfoot { row { cell(colspan=2) { End } } }
  body {
    keep {
      row { cell { A } cell { Part one } }
      row { cell { B } cell { Part two } }
    }
    break;
    row { cell { C } cell { New page } }
    nobreak;
    row { cell { D } cell { Kept with C } }
  }
}
```

Sections may appear once each in any source order. The first page uses
`firsthead`; later pages use `head`. Nonfinal pages use `foot`; the final page
uses `lastfoot`. Omitted `firsthead` inherits `head`, and omitted `lastfoot`
inherits `foot`. An explicitly empty section overrides inheritance. Omitted
`head` and `foot` are empty. Repeated content is boxed once and copied.

`keep { ... }` joins complete body rows; it accepts intervening horizontal rules
and cannot nest. In a long-table body, `break;` forces a page break and `nobreak;`
forbids one. Both must occur between rows. Rowspans, keep blocks, and nobreak
boundaries form indivisible row groups. Forcing a break inside such a group is an
error. A group too tall to fit with the applicable header/footer is also an error.

Long tables occupy dedicated single-column pages. Supply `pageheight` as the
usable table frame, excluding the document's running header and footer. They do
not share their first or last page with surrounding prose and cannot be placed
inside a cell, float, minipage, or other boxed context. A cell's paragraph cannot
split across pages. Captions and page-dependent expansion inside repeated cells
are not special table features. Horizontal rules at a body page cut appear at
both exposed ends; vertical pattern runs restart on each page fragment.

Use a standard plain TeX or single-column LaTeX host. Changed/custom output
routines, pending floats or insertions, and reduced page frames are unsupported.
In LaTeX, flush pending floats with `\clearpage` before the table. `pageheight`
must be at least `\topskip` and no larger than the host's usable page/column
height. The renderer preserves the host output routine and page numbering.

## Engine capabilities

Geometry and monochrome borders use the portable TeX box-and-rule core. Color
requires an engine or driver adapter: PDF color-stack primitives for pdfTeX and
LuaTeX, or balanced xdvipdfmx color specials for XeTeX/Tectonic. Plain classic
TeX output does not support nondefault colors. The table feature does not load a
package to supply a missing capability. Images remain ordinary cell content
prepared by the document's existing engine; there is no table-specific image
loader or font dependency.

## Development checks

Run `zig build test --global-cache-dir zig-pkg` for parser, structure, and
generation tests. On Windows, `src/table/tests/run-e2e.ps1` builds Vesti, exports
the two examples through its actual parser/code generator, and compiles them
with available LaTeX and plain TeX engines. It also exercises the bundled
Tectonic library when the Tectonic command is absent and Python is available.
Use `-SkipBuild` only after rebuilding the executable following runtime changes.
The script checks package imports, PDF text ordering, repeated headers/footers,
page counts, and overfull boxes. Outputs and logs are under
`.zig-cache/native-table-e2e`; unavailable engines are reported explicitly.

# Native table regression tests

The primitive runtime suite needs Python 3 and a plain-format TeX executable on
`PATH`. It uses only Python's standard library. It does not load any TeX package.

```console
python src/table/tests/run-runtime.py
python src/table/tests/run-runtime.py --engines pdftex luatex xetex tex
```

`--output PATH` changes the output directory. The default is the ignored
`.zig-cache/native-table-runtime` directory. Generated TeX, PDFs/DVI, logs, and
captured process output stay there; the test does not modify source fixtures.
An explicitly requested unavailable engine is an error rather than a skipped
adapter test.

The runner prepends the current production runtimes to `runtime-proof.tex` and
checks:

- 240 deterministic border cases against an independent rectangle oracle,
  including six patterns, both axes, phase normalization, and clipped endpoints.
- 203 weighted-width cases against exact integer arithmetic, including the
  dimension limit and a regression for premature recursive macro expansion.
- Maximal horizontal and vertical runs across section joins, double envelopes,
  empty-section edge coalescing, and measured/rendered height equality.
- Page-cost saturation when the full document exceeds TeX's dimension range.
- Nested stacks and 2,000 retained cells using bounded register allocation.
- Source-located cell-effect errors, rounded-zero dimensions, automatic/double
  border overflow, and incompatible explicit borders at actual fragment joins.

The PDF engines exercise their color adapters. Classic `tex` runs the same
geometry with monochrome output. The suite checks emitted rectangle geometry;
it does not substitute for visual inspection of generated examples.

`pager-proof.tex` supplies separate pagination regressions. Compiler-level
generation and PDF checks are in `run-e2e.ps1` and `codegen.zig`.

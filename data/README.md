# Unicode data

These files are the Unicode Character Database 17.0.0 inputs used to generate
`src/uucode/generated_tables.odin`:

- `UnicodeData.txt` is the primary source for general categories.
- `DerivedCoreProperties.txt` supplies `Alphabetic` and
  `Default_Ignorable_Code_Point`.
- `DerivedEastAsianWidth.txt` supplies wide and full-width code points,
  including its `@missing` ranges.
- `GraphemeBreakProperty.txt` supplies regional indicators for standalone
  display width.

They are copied verbatim from the uucode 0.2.0 dependency pinned by the Zig
Vesti implementation. Each input contains its Unicode copyright and terms URL
in the header. Regenerate the Odin tables with:

```text
odin run build.odin -file -- unicode/regen
```


# vesti

A transpiler from the Vesti document language to LaTeX. It keeps the Vesti 0.16.1 command-line
surface and includes the Lua project API and bundled Tectonic bridge.

## Build and test

Odin is discovered through `ODIN`, `PATH`, or (on Windows)
`%USERPROFILE%\.local\Odin\odin.exe`.

```console
odin run build.odin -file -- build
odin run build.odin -file -- test
```

The build first regenerates `src/uucode/generated_tables.odin` when any Unicode
17 input changes. On Windows it also stages Odin's `lua54.dll` and the bundled
Tectonic DLL beside `build/vesti.exe`.

Install Vesti into a directory with the executable and Tectonic bridge beside
it, plus the Lua runtime on Windows. Quote paths that contain spaces.

```console
# Windows
odin run build.odin -file -- install "%USERPROFILE%\bin"
odin run build.odin -file -- install "%APPDATA%\Vesti\bin"

# Linux and macOS
odin run build.odin -file -- install "~/bin"
```

On Windows, a leading `%USERPROFILE%` or `%APPDATA%` is expanded by the build
driver. On POSIX systems, `~` and `~/...` are expanded from `HOME`. Relative and
absolute paths are also accepted directly.

The bundled Tectonic bridge currently supports Windows x86-64, Linux x86-64
with a GNU-compatible userspace, and macOS arm64. The installer rejects other
OS/CPU combinations and verifies that the bridge can be loaded before copying
it.

Other build-driver commands are `run`, `unicode`, `unicode/regen`, and `clean`.

## Use

```console
build/vesti init my-document
build/vesti compile
build/vesti compile -S -e my-document.ves
build/vesti latex .vesti-dummy/my-document.tex
```

`-S` selects standalone mode. `-e` emits TeX without invoking a LaTeX backend.
Run `build/vesti --help` for all engine, script, watch, and pass-count options.

## Configuration formats

This port uses portable data formats rather than Zig Object Notation. The user
configuration is named `config` with exactly one of these extensions:

- `.json`
- `.yaml` or `.yml`
- `.toml`
- `.msgpack`

It lives below `%APPDATA%\vesti` on Windows or `~/.config/vesti` on Linux and
macOS. Having more than one supported `config.*` file is an error, which avoids
silently loading a stale configuration.

```json
{
  "engine": "tectonic",
  "lua": {
    "make_log": false,
    "line_limit": 45
  }
}
```

All fields are optional and use those defaults when absent.

The equivalent YAML and TOML forms are:

```yaml
engine: tectonic
lua:
  make_log: false
  line_limit: 45
```

```toml
engine = "tectonic"

[lua]
make_log = false
line_limit = 45
```

MessagePack uses the same map structure and value types as the JSON example.
Its maps must have string keys; binary and extension values are rejected because
they are not part of the Vesti configuration schema.

Installed Vesti modules live below the same configuration directory. A module
named `template` uses exactly one `template/vesti.{json,yaml,yml,toml,msgpack}`
manifest. For example, `template/vesti.json` can contain:

```json
{
  "name": "template",
  "version": "1.0.0",
  "exports": [
    {"name": "font.ves"},
    {"name": "settings.tex", "location": "Settings"}
  ]
}
```

An omitted export `location` defaults to `.vesti-dummy`.

The YAML reader intentionally targets configuration documents: mappings,
sequences, flow collections, comments, quoted/plain scalars, and document
markers are supported, while anchors, aliases, tags, and block scalars are
rejected. TOML has no null value, so omit optional `version` and `location`
fields instead.

A typical TOML manifest writes the export list as arrays of tables:

```toml
name = "template"
version = "1.0.0"

[[exports]]
name = "font.ves"

[[exports]]
name = "settings.tex"
location = "Settings"
```

## Unicode tables

`tools/unicode_gen` parses the committed Unicode Character Database inputs in
`data/` and generates compact ranges for alphabetic, alphanumeric, numeric,
ASCII, grapheme-width, and standalone-width queries. The generated functions
match the Zig `uucode` tables for every Unicode scalar/code-point value.

# vesti

A transpiler that compiles into LaTeX.

## Why do we need a LaTeX transpiler?

I used to create several documents using LaTeX (or plain TeX but TeX is quite
cumbersome to write—especially when working with very complex tables or
inserting images). Its markdown-like syntax is also not comfortable to use. For
example, here is a simple LaTeX document:

```tex
% coprime is my custom class. See https://github.com/e0328eric/coprime.
\documentclass[tikz, geometry]{coprime}

\settitle{My First Document}{Sungbae Jeong}{}
\setgeometry{a4paper, margin = 2.5cm}

\begin{document}
\section{Foo}
Hello, World!
\begin{figure}[ht]
    \centering
    \begin{tikzpicture}
        \draw (0,0) -- (1,1);
    \end{tikzpicture}
\end{figure}

The code above is a figure using TikZ.

\end{document}
```

What annoys me most when using it is the `\begin` and `\end` blocks. Is there a way to write something much simpler? This question led me to start this project. Currently, the following code is generated into the LaTeX code above (except comments) using vesti:

```
% coprime is my custom class. See https://github.com/e0328eric/coprime.
docclass coprime (tikz, geometry)

\settitle{My First Document}{Sungbae Jeong}{}
\setgeometry{a4paper, margin = 2.5cm}

startdoc

\section{Foo}
Hello, World!
useenv figure [ht] {
    \centering
    useenv tikzpicture {
        \draw (0,0) -- (1,1);
    }
}

The code above is a figure using TikZ.
```

# Installation

## Prerequisites

Rust is required to build or install vesti. The optional `tectonic-backend`
feature embeds Tectonic and uses the following native libraries:

- `fontconfig`
- `freetype2`
- `graphite2`
- `harfbuzz` with Graphite2 support
- `ICU4C`
- `libpng`

### Windows

Use a Windows MSVC Rust toolchain and install Visual Studio or Visual Studio
Build Tools with the **Desktop development with C++** workload and a Windows
SDK. Prepare a standalone vcpkg installation separately using
[Microsoft's vcpkg getting started guide](https://learn.microsoft.com/en-us/vcpkg/get_started/get-started-msbuild).
Use its path in the PowerShell commands below; the vcpkg bundled with Visual
Studio is not a standalone installation.

Set the dependency settings in the shell where you run Cargo:

```powershell
$env:VCPKG_ROOT = (Resolve-Path 'C:\path\to\vcpkg').Path
$env:TECTONIC_DEP_BACKEND = 'vcpkg'
${env:CXXFLAGS_x86_64-pc-windows-msvc} = '/std:c++17'
```

For an x64 build from this repository, use the static CRT triplet matching
`.cargo/config.toml`:

```powershell
$env:VCPKGRS_TRIPLET = 'x64-windows-static'
& "$env:VCPKG_ROOT\vcpkg.exe" install fontconfig freetype 'harfbuzz[graphite2]' icu libpng --triplet $env:VCPKGRS_TRIPLET
cargo b -F tectonic-backend
```

For an x64 crates.io installation using Rust's default dynamic CRT, use:

```powershell
$env:VCPKGRS_TRIPLET = 'x64-windows-static-md'
& "$env:VCPKG_ROOT\vcpkg.exe" install fontconfig freetype 'harfbuzz[graphite2]' icu libpng --triplet $env:VCPKGRS_TRIPLET
cargo install vesti -F tectonic-backend
```

These environment settings must remain available to `cargo install`, either in
its shell or your global Cargo configuration. Installing from crates.io does
not read this repository's `.cargo/config.toml`. For other targets or custom
CRT settings, choose a matching vcpkg triplet.

### Linux and macOS

Install the native libraries listed above using your package manager when
enabling `tectonic-backend`. On Linux, install `zenity` also.

## Compilation

### For normal users

To install from crates.io without the Tectonic backend:

```console
cargo install vesti
```

To install with the Tectonic backend:

```console
cargo install vesti -F tectonic-backend
```

To install from a local checkout, replace `vesti` with `--path .`.

### For developers

Build from a local checkout with Rust:

```console
cargo b
cargo b -F tectonic-backend
```

Zig and `cargo-zigbuild` are needed for the cross-compilation workflow provided
by `shell.nix`.

## Configuration
Vesti has a configuration file. The location of the config file is follows:
- Linux, MacOS: `~/.config/vesti/config.ron`
- Windows: `%APPDATA%\vesti\config.ron`

## Warning
This language is in beta, so breaking changes may occur in the future. Be cautious when using it for large projects.


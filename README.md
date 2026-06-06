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
This project uses the master zig version. For linux, I recommend to install
zenity.

## Compilation
### For normal users
If you want to compile with Tectonic backend, just run the following command:

```console
$ zig build --prefix-exe-dir <path to install> -Doptimize=ReleaseSafe
```

If you do not want tectonic backend, then run the following.

```console
$ zig build --prefix-exe-dir <path to install> -Dtectonic=false -Doptimize=ReleaseSafe
```

### For developers
One should have zig and rust compiler.

#### Prerequisites for building dynamic library
It uses `tectonic` when `tectonic-backend` feature enabled. Install following third-party dependencies.
- `fontconfig`
- `freetype2`
- `graphite2`
- `harfbuzz`
- `ICU4C`
- `libpng`
- `upx` (a binary)

#### Windows
There are two options to build dll. One is first install `vcpkg` manually (not
using Visual Studio one) and install all libraries.

```console
vcpkg install fontconfig libpng freetype "harfbuzz[graphite2] icu --triplet x64-windows-static-release
```

Upx can be installed via winget.

In addition, on windows, add the following inside of
`%USERPROFILE%\.cargo\config.toml`.
```toml
[env]
TECTONIC_DEP_BACKEND = "vcpkg"
VCPKG_ROOT = "C:/opt/vcpkg"
VCPKGRS_TRIPLET = "x64-windows-static-release"
```

Then run
```console
zig build rust -Dno-cargo-vcpkg=true
```

If you do not want to install `vcpkg` manually, install `cargo-vcpkg`.
Then run
```console
zig build rust
```

To build macos dylib, install `cargo-zigbuild` and follow the above steps.

#### Linux
On linux, install upper dependencies using their own package manager.
Especially on linux, install `zenity` also.

```console
zig build rust
zig build
```

To build macos dylib, install `cargo-zigbuild` and follow the above steps.

#### Macos
Macos, install upper dependencies using their own package manager.
Then just run
```console
zig build rust
zig build
```

## Configuration
Vesti has a configuration file. The location of the config file is follows:
- Linux, MacOS: `~/.config/vesti/config.zon`
- Windows: `%APPDATA%\vesti\config.zon`

zon file stands for _Zig Object Notation_. Here is the example of `config.zon`.
```zig
.{
    .engine = .tectonic,
    .lua = .{
        .make_log = false,
        .line_limit = 45,
    },
}
```
If some fields are missing, then vesti takes the default values (above example
is the default one).

## Warning
This language is in beta, so breaking changes may occur in the future. Be cautious when using it for large projects.


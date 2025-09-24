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
This project uses the latest zig (developer version).
On Windows, TeX Live (or related software) and Julia are required. If one uses vesti with the Tectonic backend, TeX Live is not needed.
On Linux and macOS, `freetype2` and `fontconfig` are additionally required.

### For Linux Users
After including julia language in vesti, one cannot compile with `glibc` because
zig emits error `unknown type name 'sigjmp_buf'`, and I don't know yet.
So while compiling, use `musl` instead.

## Compilation
If you do not want to compile the Tectonic backend, just run the following command:

```console
$ zig build --prefix-exe-dir <path to install> -Doptimize=ReleaseSafe
```

Otherwise, two additional tools are needed:
- Rust compiler (with Cargo)
- cargo-vcpkg

Then run the following command:

```console
$ zig build --prefix-exe-dir <path to install> -Dtectonic=true -Doptimize=ReleaseSafe
```

## Warning
This language is in beta, so breaking changes may occur in the future. Be cautious when using it for large projects.


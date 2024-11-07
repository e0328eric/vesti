# vesti

A transpiler that compiles into LaTeX.

## Why need a LaTeX transpiler?

I used to make several documentations using LaTeX (or plainTeX, but TeX is quite cumbersome to write
a document, especially very complex tables or put an image, for example).
However, its markdown like syntax is not confortable to use it.
For example, there is a simple LaTeX document.

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

Upper code is a figure using tikz.

\end{document}
```

What I am anoying about to use it is `\begin` and `\end` block. Is there a way to write much simpler? This
question makes me to start this project. Currently, below code is generated into upper LaTeX code
using vesti except comments.

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

Upper code is a figure using tikz.
```

## Installation
Vesti can be installed using `cargo`.

```console
$ cargo install vesti
```

### tectonic backend compilation issue
For a higher version of the rust compiler, somewhat tectonic backend is not
compilable. See
[vesti-tectonic-git](https://github.com/e0328eric/vesti-tectonic-git) if one
want to use tectonic backend for vesti.

## config file
In default, it uses local `pdflatex` to compile vesti. If you want to change the default behavior, add `config.yaml` in `$CONFIG_PATH/vesti` and type like the following:
```yaml
engine:
  main:
    "tectonic"
```
This example defaults vesti to run `tectonic` backend. (You must download vesti using `tectonic-backend` to use `tectonic`). The full list for main engine is in `src/commands.rs`.

## Warning

This language is in beta version, so future break changes can be exist. Beware to use in the large
projects.

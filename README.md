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
```console
$ zig build --prefix-exe-dir <path to install> -Doptimize=ReleaseSafe
```

## Warning

This language is in beta version, so future break changes can be exist. Beware to use in the large
projects.

## Note
vesti repository contains entire [lua](https://www.lua.org/home.html) source
code. Below link is the license of lua language

- https://www.lua.org/license.html

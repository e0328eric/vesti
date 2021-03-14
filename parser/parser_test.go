package parser

import (
	"testing"
	"vesti/lexer"
	"vesti/vestiError"
)

type testInput struct {
	input    string
	expected string
}

func testParser(t *testing.T, tests []testInput) {
	t.Helper()

	for _, tt := range tests {
		l := lexer.New(tt.input)
		p := New(l)
		evaluated, err := p.parseLatex()

		if err != nil {
			t.Fatal(vestiError.PrintErr(tt.input, nil, err))
		}

		if evaluated.String() != tt.expected {
			t.Fatalf("Parsing Failed!!\nexpected: %s\ngot: %s", tt.expected, evaluated.String())
		}
	}
}

func TestParsingDocclass(t *testing.T) {
	tests := []testInput{
		{
			"docclass article",
			"\\documentclass{article}\n",
		},
		{
			"docclass standalone (tikz)",
			"\\documentclass[tikz]{standalone}\n",
		},
		{
			"docclass standalone ( tikz )",
			"\\documentclass[tikz]{standalone}\n",
		},
		{
			"docclass coprime (korean, tikz, tcolorbox)",
			"\\documentclass[korean,tikz,tcolorbox]{coprime}\n",
		},
		{
			`docclass coprime (
	korean,
	tikz,
	tcolorbox
)`,
			"\\documentclass[korean,tikz,tcolorbox]{coprime}\n",
		},
		{
			`docclass coprime (
	korean,
	tikz,
	tcolorbox,
)`,
			"\\documentclass[korean,tikz,tcolorbox]{coprime}\n",
		},
	}

	testParser(t, tests)
}

func TestParsingUsepackage(t *testing.T) {
	tests := []testInput{
		{
			"import kotex",
			"\\usepackage{kotex}\n",
		},
		{
			"import tcolorbox (many)",
			"\\usepackage[many]{tcolorbox}\n",
		},
		{
			"import tcolorbox ( many )",
			"\\usepackage[many]{tcolorbox}\n",
		},
		{
			"import foo (bar1, bar2)",
			"\\usepackage[bar1,bar2]{foo}\n",
		},
		{
			"import geometry (a4paper, margin = 0.4in)",
			"\\usepackage[a4paper,margin=0.4in]{geometry}\n",
		},
		{
			`import {
	kotex
	tcolorbox (many)
	foo (bar1, bar2, bar3)
	geometry (a4paper, margin = 0.4in)
}`,
			`\usepackage{kotex}
\usepackage[many]{tcolorbox}
\usepackage[bar1,bar2,bar3]{foo}
\usepackage[a4paper,margin=0.4in]{geometry}
`,
		},
		{
			`import {
	kotex
	tcolorbox (many)
	foo (
		bar1, bar2,
		bar3
	)
	geometry (a4paper, margin = 0.4in)
}`,
			`\usepackage{kotex}
\usepackage[many]{tcolorbox}
\usepackage[bar1,bar2,bar3]{foo}
\usepackage[a4paper,margin=0.4in]{geometry}
`,
		},
		{
			`import {
	kotex
	tcolorbox (many)
	foo (
		bar1,
		bar2,
		bar3,
	)
	geometry (a4paper, margin = 0.4in)
}`,
			`\usepackage{kotex}
\usepackage[many]{tcolorbox}
\usepackage[bar1,bar2,bar3]{foo}
\usepackage[a4paper,margin=0.4in]{geometry}
`,
		},
		{
			`import { kotex tcolorbox (many) foo (
		bar1,
		bar2,
		bar3,
	)
	geometry (a4paper, margin = 0.4in) }`,
			`\usepackage{kotex}
\usepackage[many]{tcolorbox}
\usepackage[bar1,bar2,bar3]{foo}
\usepackage[a4paper,margin=0.4in]{geometry}
`,
		},
	}

	testParser(t, tests)
}

func TestParseMainString(t *testing.T) {
	tests := []testInput{
		{
			"document This is vesti;",
			`\begin{document}
This is vesti;
\end{document}
`,
		},
		{
			"document docclass",
			`\begin{document}
docclass
\end{document}
`,
		},
	}

	testParser(t, tests)
}

func TestParseEnvironment(t *testing.T) {
	tests := []testInput{
		{
			`
document begenv center
	The Document
endenv`,
			`
\begin{document}
\begin{center}
	The Document
\end{center}

\end{document}
`,
		},
		{
			`
document begenv minipage (0.7\pagewidth)
	The Document
endenv`,
			`
\begin{document}
\begin{minipage}{0.7\pagewidth}
	The Document
\end{minipage}

\end{document}
`,
		},
		{
			`
document begenv minipage(0.7\pagewidth)
	The Document
endenv`,
			`
\begin{document}
\begin{minipage}{0.7\pagewidth}
	The Document
\end{minipage}

\end{document}
`,
		},
		{
			`
document begenv figure [ht]
	The Document
endenv`,
			`
\begin{document}
\begin{figure}[ht]
	The Document
\end{figure}

\end{document}
`,
		},
		{
			`
document begenv foo (bar1)[bar2](bar3)(bar4)[bar5]
	The Document
endenv`,
			`
\begin{document}
\begin{foo}{bar1}[bar2]{bar3}{bar4}[bar5]
	The Document
\end{foo}

\end{document}
`,
		},
		{
			`
document begenv foo* (bar1\; bar2)
	The Document
endenv`,
			`
\begin{document}
\begin{foo*}{bar1}{bar2}
	The Document
\end{foo*}

\end{document}
`,
		},
		{
			`
document begenv foo *(bar1\; bar2)
	The Document
endenv`,
			`
\begin{document}
\begin{foo}*{bar1}{bar2}
	The Document
\end{foo}

\end{document}
`,
		},
	}

	testParser(t, tests)
}

func TestParsingLatexFunctions(t *testing.T) {
	tests := []testInput{
		{
			"document \\foo",
			`\begin{document}
\foo
\end{document}
`,
		},
		{
			"document \\foo{bar1}",
			`\begin{document}
\foo{bar1}
\end{document}
`,
		},
		{
			"document \\foo[bar1]",
			`\begin{document}
\foo[bar1]
\end{document}
`,
		},
		{
			"document \\foo{bar1}#[bar2]#",
			`\begin{document}
\foo{bar1}[bar2]
\end{document}
`,
		},
		{
			"document \\foo{bar3\\; bar2\\; bar1}*#[bar5\\; bar4]#",
			`\begin{document}
\foo{bar3}{bar2}{bar1}*[bar5][bar4]
\end{document}
`,
		},
		{
			"\\foo{bar3\\; bar2\\; bar1}*#[bar5\\; bar4]#",
			`\foo{bar3}{bar2}{bar1}*[bar5][bar4]`,
		},
		{
			`document \textbf{
	Hallo!\TeX and \foo{bar1\; bar2{a}{}}; today
}`,
			`\begin{document}
\textbf{
	Hallo!\TeX and \foo{bar1}{bar2{a}{}}; today
}
\end{document}
`,
		},
		{
			`\def\I{\setbox0=\hbox{$!1$!}
\tikz[line width=0.6pt]{
    \draw (0,0) -- (0.87\wd0,0);
    \draw (0.29\wd0,0) -- ++(0,0.55\ht0);
    \draw (0.58\wd0,0) -- ++(0,\ht0) -- ++(-0.1,-0.1);
}}
`,
			`\def\I{\setbox0=\hbox{$1$}
\tikz[line width=0.6pt]{
    \draw (0,0) -- (0.87\wd0,0);
    \draw (0.29\wd0,0) -- ++(0,0.55\ht0);
    \draw (0.58\wd0,0) -- ++(0,\ht0) -- ++(-0.1,-0.1);
}}
`,
		},
	}

	testParser(t, tests)
}

func TestParseMathStmt(t *testing.T) {
	tests := []testInput{
		{
			"document $\\sum_1^\\infty f(x)$",
			`\begin{document}
$\sum_1^\infty f(x)$
\end{document}
`,
		},
		{
			"document \\(\\sum_1^\\infty f(x)\\)",
			`\begin{document}
$\sum_1^\infty f(x)$
\end{document}
`,
		},
		{
			"document $$\\sum_1^\\infty f(x)$$",
			`\begin{document}
\[\sum_1^\infty f(x)\]
\end{document}
`,
		},
		{
			"document \\[\\sum_1^\\infty f(x)\\]",
			`\begin{document}
\[\sum_1^\infty f(x)\]
\end{document}
`,
		},
	}

	testParser(t, tests)
}

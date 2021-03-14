package lexer

import (
	"testing"
	"vesti/src/token"
)

func testLexing(t *testing.T, input string, expectedLst []token.Token) {
	t.Helper()

	l := New(input)

	for _, expected := range expectedLst {
		got := l.TakeTok()

		if got.Token.Type != expected.Type {
			t.Fatalf("token types are different in `%v`.\ngot=%X, want=%X",
				got.Span, got.Token.Type, expected.Type)
		}

		if got.Token.Literal != expected.Literal {
			t.Fatalf("token literals are different in `%v`.\ngot=%q, want=%q",
				got.Span, got.Token.Literal, expected.Literal)
		}
	}
}

func TestLexingSymbols(t *testing.T) {
	input := "+-/*!?@&^;_:\".,`|'~"
	expected := []token.Token{
		token.New(token.Plus, "+"),
		token.New(token.Minus, "-"),
		token.New(token.Slash, "/"),
		token.New(token.Star, "*"),
		token.New(token.Bang, "!"),
		token.New(token.Question, "?"),
		token.New(token.At, "@"),
		token.New(token.Ampersand, "&"),
		token.New(token.Superscript, "^"),
		token.New(token.Semicolon, ";"),
		token.New(token.Subscript, "_"),
		token.New(token.Colon, ":"),
		token.New(token.Doublequote, "\""),
		token.New(token.Period, "."),
		token.New(token.Comma, ","),
		token.New(token.Quote2, "`"),
		token.New(token.Vert, "|"),
		token.New(token.Quote, "'"),
		token.New(token.Tilde, "~"),
	}

	testLexing(t, input, expected)
}

func TestLexingWhitespaces(t *testing.T) {
	input := "\t  \t\n\r\n \t\r"
	expected := []token.Token{
		token.New(token.Tab, "\t"),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.Tab, "\t"),
		token.New(token.Newline, "\n"),
		token.New(token.Newline, "\n"),
		token.New(token.Space, " "),
		token.New(token.Tab, "\t"),
		token.New(token.Newline, "\n"),
	}

	testLexing(t, input, expected)
}

func TestLexingComment(t *testing.T) {
	input := `
# This is a comment!
----
#* This is also a comment.
The difference is that multiple commenting is possible.
*#+`
	expected := []token.Token{
		token.New(token.Newline, "\n"),
		token.New(token.Minus, "-"),
		token.New(token.Minus, "-"),
		token.New(token.Minus, "-"),
		token.New(token.Minus, "-"),
		token.New(token.Newline, "\n"),
		token.New(token.Plus, "+"),
	}

	testLexing(t, input, expected)
}

func TestLexingTextRawLatex(t *testing.T) {
	input := "#-\\TeX and \\LaTeX-##-foo 3.14-#"
	expected := []token.Token{
		token.New(token.RawLatex, "\\TeX and \\LaTeX"),
		token.New(token.RawLatex, "foo 3.14"),
	}

	testLexing(t, input, expected)
}

func TestLexingInlineRawLatex(t *testing.T) {
	input := `##-
\begin{center}
  the \TeX
\end{center}
-##`
	expected := []token.Token{
		token.New(token.RawLatex, `
\begin{center}
  the \TeX
\end{center}
`),
	}

	testLexing(t, input, expected)
}

func TestLexingAsciiString(t *testing.T) {
	input := "This is a string!"
	expected := []token.Token{
		token.New(token.MainString, "This"),
		token.New(token.Space, " "),
		token.New(token.MainString, "is"),
		token.New(token.Space, " "),
		token.New(token.MainString, "a"),
		token.New(token.Space, " "),
		token.New(token.MainString, "string"),
		token.New(token.Bang, "!"),
	}

	testLexing(t, input, expected)
}

func TestLexingUnicodeString(t *testing.T) {
	input := "이것은 무엇인가?"
	expected := []token.Token{
		token.New(token.MainString, "이것은"),
		token.New(token.Space, " "),
		token.New(token.MainString, "무엇인가"),
		token.New(token.Question, "?"),
	}

	testLexing(t, input, expected)
}

func TestLexingNumber(t *testing.T) {
	input := "1 32 -8432 3.2 0.3 32.00"
	expected := []token.Token{
		token.New(token.Integer, "1"),
		token.New(token.Space, " "),
		token.New(token.Integer, "32"),
		token.New(token.Space, " "),
		token.New(token.Integer, "-8432"),
		token.New(token.Space, " "),
		token.New(token.Float, "3.2"),
		token.New(token.Space, " "),
		token.New(token.Float, "0.3"),
		token.New(token.Space, " "),
		token.New(token.Float, "32.00"),
	}

	testLexing(t, input, expected)
}

func TestLexingKeywords(t *testing.T) {
	input := "docclass begenv document mtxt import etxt endenv"
	expected := []token.Token{
		token.New(token.Docclass, "docclass"),
		token.New(token.Space, " "),
		token.New(token.Begenv, "begenv"),
		token.New(token.Space, " "),
		token.New(token.Document, "document"),
		token.New(token.Space, " "),
		token.New(token.Mtxt, "mtxt"),
		token.New(token.Space, " "),
		token.New(token.Import, "import"),
		token.New(token.Space, " "),
		token.New(token.Etxt, "etxt"),
		token.New(token.Space, " "),
		token.New(token.Endenv, "endenv"),
	}

	testLexing(t, input, expected)
}

func TestLexingMathDelimiter(t *testing.T) {
	input := "$ $ $$ $$ $ $$ $ \\) \\[ \\] \\( $"
	expected := []token.Token{
		token.New(token.TextMathStart, "$"),
		token.New(token.Space, " "),
		token.New(token.TextMathEnd, "$"),
		token.New(token.Space, " "),
		token.New(token.InlineMathStart, "\\["),
		token.New(token.Space, " "),
		token.New(token.InlineMathEnd, "\\]"),
		token.New(token.Space, " "),
		token.New(token.TextMathStart, "$"),
		token.New(token.Space, " "),
		token.New(token.InlineMathEnd, "\\]"),
		token.New(token.Space, " "),
		token.New(token.TextMathStart, "$"),
		token.New(token.Space, " "),
		token.New(token.TextMathEnd, "$"),
		token.New(token.Space, " "),
		token.New(token.InlineMathStart, "\\["),
		token.New(token.Space, " "),
		token.New(token.InlineMathEnd, "\\]"),
		token.New(token.Space, " "),
		token.New(token.TextMathStart, "$"),
		token.New(token.Space, " "),
		token.New(token.TextMathEnd, "$"),
	}

	testLexing(t, input, expected)
}

func TestLexingLatexFunctions(t *testing.T) {
	input := "\\foo \\bar@hand"
	expected := []token.Token{
		token.New(token.LatexFunction, "foo"),
		token.New(token.Space, " "),
		token.New(token.LatexFunction, "bar@hand"),
	}

	testLexing(t, input, expected)
}

func TestLexingBasicVesti(t *testing.T) {
	input := `docclass coprime (tikz, korean)
import {
    geometry (a4paper, margin = 0.4in),
    amsmath,
}

document

This is a \LaTeX!
$$
    1 + 1 = \sum_{j=1}^\infty f(x),\qquad mtxt foobar etxt
$$
begenv center
    The TeX
endenv`
	expected := []token.Token{
		token.New(token.Docclass, "docclass"),
		token.New(token.Space, " "),
		token.New(token.MainString, "coprime"),
		token.New(token.Space, " "),
		token.New(token.Lparen, "("),
		token.New(token.MainString, "tikz"),
		token.New(token.Comma, ","),
		token.New(token.Space, " "),
		token.New(token.MainString, "korean"),
		token.New(token.Rparen, ")"),
		token.New(token.Newline, "\n"),
		token.New(token.Import, "import"),
		token.New(token.Space, " "),
		token.New(token.Lbrace, "{"),
		token.New(token.Newline, "\n"),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.MainString, "geometry"),
		token.New(token.Space, " "),
		token.New(token.Lparen, "("),
		token.New(token.MainString, "a4paper"),
		token.New(token.Comma, ","),
		token.New(token.Space, " "),
		token.New(token.MainString, "margin"),
		token.New(token.Space, " "),
		token.New(token.Equal, "="),
		token.New(token.Space, " "),
		token.New(token.Float, "0.4"),
		token.New(token.MainString, "in"),
		token.New(token.Rparen, ")"),
		token.New(token.Comma, ","),
		token.New(token.Newline, "\n"),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.MainString, "amsmath"),
		token.New(token.Comma, ","),
		token.New(token.Newline, "\n"),
		token.New(token.Rbrace, "}"),
		token.New(token.Newline, "\n"),
		token.New(token.Newline, "\n"),
		token.New(token.Document, "document"),
		token.New(token.Newline, "\n"),
		token.New(token.Newline, "\n"),
		token.New(token.MainString, "This"),
		token.New(token.Space, " "),
		token.New(token.MainString, "is"),
		token.New(token.Space, " "),
		token.New(token.MainString, "a"),
		token.New(token.Space, " "),
		token.New(token.LatexFunction, "LaTeX"),
		token.New(token.Bang, "!"),
		token.New(token.Newline, "\n"),
		token.New(token.InlineMathStart, "\\["),
		token.New(token.Newline, "\n"),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.Integer, "1"),
		token.New(token.Space, " "),
		token.New(token.Plus, "+"),
		token.New(token.Space, " "),
		token.New(token.Integer, "1"),
		token.New(token.Space, " "),
		token.New(token.Equal, "="),
		token.New(token.Space, " "),
		token.New(token.LatexFunction, "sum"),
		token.New(token.Subscript, "_"),
		token.New(token.Lbrace, "{"),
		token.New(token.MainString, "j"),
		token.New(token.Equal, "="),
		token.New(token.Integer, "1"),
		token.New(token.Rbrace, "}"),
		token.New(token.Superscript, "^"),
		token.New(token.LatexFunction, "infty"),
		token.New(token.Space, " "),
		token.New(token.MainString, "f"),
		token.New(token.Lparen, "("),
		token.New(token.MainString, "x"),
		token.New(token.Rparen, ")"),
		token.New(token.Comma, ","),
		token.New(token.LatexFunction, "qquad"),
		token.New(token.Space, " "),
		token.New(token.Mtxt, "mtxt"),
		token.New(token.Space, " "),
		token.New(token.MainString, "foobar"),
		token.New(token.Space, " "),
		token.New(token.Etxt, "etxt"),
		token.New(token.Newline, "\n"),
		token.New(token.InlineMathEnd, "\\]"),
		token.New(token.Newline, "\n"),
		token.New(token.Begenv, "begenv"),
		token.New(token.Space, " "),
		token.New(token.MainString, "center"),
		token.New(token.Newline, "\n"),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.Space, " "),
		token.New(token.MainString, "The"),
		token.New(token.Space, " "),
		token.New(token.MainString, "TeX"),
		token.New(token.Newline, "\n"),
		token.New(token.Endenv, "endenv"),
	}

	testLexing(t, input, expected)
}

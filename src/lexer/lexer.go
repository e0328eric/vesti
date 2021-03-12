package lexer

import (
	"bytes"
	"unicode"
	"vesti/src/location"
	"vesti/src/newlineHandler"
	"vesti/src/token"
)

type LexToken struct {
	Token token.Token
	Span  location.Span
}

type Lexer struct {
	source          *newlineHandler.NewlineHandler
	chr0            rune
	chr1            rune
	chr2            rune
	currentLocation *location.Location
	mathStarted     bool
}

func New(input string) *Lexer {
	lex := &Lexer{
		source: newlineHandler.New(input),
		chr0:   0, chr1: 0, chr2: 0,
		currentLocation: location.New(),
		mathStarted:     false,
	}

	lex.nextChar()
	lex.nextChar()
	lex.nextChar()
	lex.currentLocation.ResetLocation()

	return lex
}

func (l *Lexer) nextChar() {
	if l.chr0 == '\n' {
		l.currentLocation.MoveNextLine()
	} else {
		l.currentLocation.MoveRight()
	}

	l.chr0 = l.chr1
	l.chr1 = l.chr2
	l.chr2 = l.source.Next()
}

func (l *Lexer) tokenize(lexTok *LexToken, tok token.TokenType, lit string) {
	l.nextChar()
	lexTok.Token = token.New(tok, lit)
	lexTok.Span.End = *l.currentLocation
}

func (l *Lexer) TakeTok() *LexToken {
	var output = LexToken{Span: location.Span{Start: *l.currentLocation}}

	switch l.chr0 {
	case 0:
		l.tokenize(&output, token.EOF, "")
	case ' ':
		l.tokenize(&output, token.Space, " ")
	case '\t':
		l.tokenize(&output, token.Tab, "\t")
	case '\n':
		l.tokenize(&output, token.Newline, "\n")
	case '+':
		if l.chr1 == '#' && l.chr2 == '#' {
			l.nextChar()
			l.nextChar()
			l.tokenize(&output, token.ObeyNewlineBeforeDocEnd, "")
		} else {
			l.tokenize(&output, token.Plus, "+")
		}
	case '-':
		if unicode.IsDigit(l.chr1) || l.chr1 == '.' {
			l.lexNumber(&output)
		} else {
			l.tokenize(&output, token.Minus, "-")
		}
	case '*':
		l.tokenize(&output, token.Star, "*")
	case '/':
		l.tokenize(&output, token.Slash, "/")
	case '=':
		l.tokenize(&output, token.Equal, "=")
	case '<':
		if l.chr1 == '=' {
			l.nextChar()
			l.tokenize(&output, token.LessEq, "<=")
		} else {
			l.tokenize(&output, token.Less, "<")
		}
	case '>':
		if l.chr1 == '=' {
			l.nextChar()
			l.tokenize(&output, token.GreatEq, ">=")
		} else {
			l.tokenize(&output, token.Great, ">")
		}
	case '!':
		l.tokenize(&output, token.Bang, "!")
	case '?':
		l.tokenize(&output, token.Question, "?")
	case '@':
		l.tokenize(&output, token.At, "@")
	case '%':
		l.tokenize(&output, token.Percent, "%")
	case '^':
		l.tokenize(&output, token.Superscript, "^")
	case '_':
		l.tokenize(&output, token.Subscript, "_")
	case '&':
		l.tokenize(&output, token.Ampersand, "&")
	case ';':
		l.tokenize(&output, token.Semicolon, ";")
	case ':':
		l.tokenize(&output, token.Colon, ":")
	case '\'':
		l.tokenize(&output, token.Quote, "'")
	case '`':
		l.tokenize(&output, token.Quote2, "`")
	case '"':
		l.tokenize(&output, token.Doublequote, "\"")
	case '|':
		l.tokenize(&output, token.Vert, "|")
	case '.':
		if unicode.IsDigit(l.chr1) {
			l.lexNumber(&output)
		} else {
			l.tokenize(&output, token.Period, ".")
		}
	case ',':
		l.tokenize(&output, token.Comma, ",")
	case '~':
		l.tokenize(&output, token.Tilde, "~")
	case '(':
		l.tokenize(&output, token.Lparen, "(")
	case ')':
		l.tokenize(&output, token.Rparen, ")")
	case '{':
		l.tokenize(&output, token.Lbrace, "{")
	case '}':
		l.tokenize(&output, token.Rbrace, "}")
	case '[':
		l.tokenize(&output, token.Lsqbrace, "[")
	case ']':
		l.tokenize(&output, token.Rsqbrace, "]")
	case '$':
		l.lexMathToken(&output)
	case '#':
		l.lexSharp(&output)
	case '\\':
		l.lexBackslash(&output)
	default:
		switch {
		case unicode.IsLetter(l.chr0):
			l.lexMainString(&output)
		case unicode.IsDigit(l.chr0):
			l.lexNumber(&output)
		default:
			l.tokenize(&output, token.ILLEGAL, "")
		}
	}

	return &output
}

func (l *Lexer) lexMainString(tok *LexToken) {
	var literal bytes.Buffer

	for l.chr0 != 0 {
		if !unicode.IsLetter(l.chr0) && !unicode.IsDigit(l.chr0) {
			break
		}
		literal.WriteRune(l.chr0)
		l.nextChar()
	}

	tok.Token.Literal = literal.String()
	tok.Token.Type = token.Lookup(tok.Token.Literal)
	tok.Span.End = *l.currentLocation
}

func (l *Lexer) lexNumber(tok *LexToken) {
	var literal bytes.Buffer
	var tokType token.TokenType

	if l.chr0 == '-' {
		literal.WriteRune('-')
		l.nextChar()
	}

	if l.chr0 != '.' {
		for unicode.IsDigit(l.chr0) {
			literal.WriteRune(l.chr0)
			l.nextChar()
		}
	}

	if l.chr0 == '.' {
		literal.WriteRune('.')
		l.nextChar()
		tokType = token.Float
	} else {
		tokType = token.Integer
	}

	for unicode.IsDigit(l.chr0) {
		literal.WriteRune(l.chr0)
		l.nextChar()
	}

	tok.Token = token.New(tokType, literal.String())
	tok.Span.End = *l.currentLocation
}

func (l *Lexer) lexMathToken(tok *LexToken) {
	if l.mathStarted {
		l.mathStarted = false
		if l.chr1 == '$' {
			l.nextChar()
			l.tokenize(tok, token.InlineMathEnd, "\\]")
		} else {
			l.tokenize(tok, token.TextMathEnd, "$")
		}
	} else {
		l.mathStarted = true
		if l.chr1 == '$' {
			l.nextChar()
			l.tokenize(tok, token.InlineMathStart, "\\[")
		} else {
			l.tokenize(tok, token.TextMathStart, "$")
		}
	}
}

func (l *Lexer) lexSharp(tok *LexToken) {
	switch l.chr1 {
	case '*':
		l.nextChar()
		l.nextChar()
		for l.chr0 != '*' || l.chr1 != '#' {
			if l.chr0 == 0 {
				break
			}
			l.nextChar()
		}
		l.nextChar()
		l.nextChar()
		start := tok.Span.Start
		*tok = *l.TakeTok()
		tok.Span.Start = start
	case '!':
		var literal bytes.Buffer

		l.nextChar()
		l.nextChar()
		for l.chr0 != '!' || l.chr1 != '#' {
			if l.chr0 == 0 {
				break
			}
			literal.WriteRune(l.chr0)
			l.nextChar()
		}
		l.nextChar()
		l.nextChar()
		tok.Token = token.New(token.RawLatex, literal.String())
		tok.Span.End = *l.currentLocation
	case '@':
		l.nextChar()
		l.tokenize(tok, token.Newline2, "\n")
	default:
		switch {
		case l.chr1 == '#' && l.chr2 == '-':
			var literal bytes.Buffer

			l.nextChar()
			l.nextChar()
			l.nextChar()
			for l.chr0 != '-' || l.chr1 != '#' || l.chr2 != '#' {
				if l.chr0 == 0 {
					break
				}
				literal.WriteRune(l.chr0)
				l.nextChar()
			}
			l.nextChar()
			l.nextChar()
			l.nextChar()
			tok.Token = token.New(token.RawLatex, literal.String())
			tok.Span.End = *l.currentLocation
		case l.chr1 == '#' && l.chr2 == '+':
			l.nextChar()
			l.nextChar()
			l.tokenize(tok, token.ObeyNewlineBeforeDocStart, "")
		default:
			for l.chr0 != '\n' {
				if l.chr0 == 0 {
					break
				}
				l.nextChar()
			}
			start := tok.Span.Start
			*tok = *l.TakeTok()
			tok.Span.Start = start
		}
	}
}

func (l *Lexer) lexBackslash(tok *LexToken) {
	switch l.chr1 {
	// TODO: I can't find much more elegant token to represent latex define function parameter
	case '?':
		l.nextChar()
		l.tokenize(tok, token.FntParam, "#")
	case '#':
		l.nextChar()
		l.tokenize(tok, token.Sharp, "\\#")
	case '$':
		l.nextChar()
		l.tokenize(tok, token.Dollar, "\\$")
	case ',':
		l.nextChar()
		if l.mathStarted {
			l.tokenize(tok, token.MathSmallSpace, "\\,")
		} else {
			l.tokenize(tok, token.Comma, ",")
		}
	case ';':
		l.nextChar()
		l.tokenize(tok, token.ArgSpliter, "")
	case '(':
		l.nextChar()
		l.tokenize(tok, token.TextMathStart, "$")
	case ')':
		l.nextChar()
		l.tokenize(tok, token.TextMathEnd, "$")
	case '{':
		l.nextChar()
		l.tokenize(tok, token.MathLbrace, "\\{")
	case '}':
		l.nextChar()
		l.tokenize(tok, token.MathRbrace, "\\}")
	case '[':
		l.nextChar()
		l.tokenize(tok, token.InlineMathStart, "\\[")
	case ']':
		l.nextChar()
		l.tokenize(tok, token.InlineMathEnd, "\\]")
	case ' ':
		l.nextChar()
		if l.mathStarted {
			l.tokenize(tok, token.MathLargeSpace, "\\;")
		} else {
			l.tokenize(tok, token.Space2, "\\ ")
		}
	case '\\':
		l.nextChar()
		l.tokenize(tok, token.BackSlash, "\\\\")
	default:
		if unicode.IsLetter(l.chr1) || l.chr1 == '@' {
			var literal bytes.Buffer

			l.nextChar()
			for unicode.IsLetter(l.chr0) || l.chr0 == '@' {
				tmpTok := l.TakeTok()
				// There are only two tokens, EOF and ILLEGAL, that are larger than 0xE000
				if tmpTok.Token.Type > 0xE000 {
					break
				}
				literal.WriteString(tmpTok.Token.Literal)
			}
			tok.Token = token.New(token.LatexFunction, literal.String())
			tok.Span.End = *l.currentLocation
		} else {
			l.tokenize(tok, token.ILLEGAL, "")
		}
	}
}

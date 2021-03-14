package parser

import (
	"bytes"
	"strconv"
	"vesti/ast"
	"vesti/lexer"
	"vesti/location"
	"vesti/token"
	verror "vesti/vestiError"
)

type VError verror.VestiErr

// documentState is a bitflag.
// 0000 0 0 0
// |/// | | \- check whether document is started
// |//  | \--- check whether document is ended
// |/   \----- if this is 1, then document mode is on, but \end{document} is not made
// \------- Dummy Flags
type Parser struct {
	source        *lexer.Lexer
	peekToken     *lexer.LexToken
	documentState uint8
}

func New(source *lexer.Lexer) *Parser {
	output := &Parser{
		source:        source,
		peekToken:     nil,
		documentState: 0,
	}
	output.nextTok()

	return output
}

func (p *Parser) nextTok() *lexer.LexToken {
	currTok := p.peekToken
	p.peekToken = p.source.TakeTok()

	return currTok
}

func (p *Parser) peekTok() token.TokenType {
	return p.peekToken.Token.Type
}

func (p *Parser) peekTokLoaction() *location.Span {
	return &p.peekToken.Span
}

func (p *Parser) expectPeek(
	span *location.Span,
	tokType ...token.TokenType,
) VError {
	expectMatched := false
	gotTok := p.nextTok()
	for _, tok := range tokType {
		if gotTok.Token.Type == tok {
			expectMatched = true
		}
	}

	if expectMatched {
		return nil
	}

	return &verror.TypeMismatch{
		Expected: tokType,
		Got:      gotTok.Token.Type,
		Loc:      span,
	}
}

func (p *Parser) takeName() (string, VError) {
	var tmp bytes.Buffer

	for {
		nameToken := p.nextTok()
		switch nameToken.Token.Type {
		case token.MainString:
			tmp.WriteString(nameToken.Token.Literal)
		case token.Minus:
			tmp.WriteString(nameToken.Token.Literal)
		case token.RawLatex:
			tmp.WriteString(nameToken.Token.Literal)
		default:
			return "", &verror.TypeMismatch{
				Expected: []token.TokenType{token.MainString},
				Got:      nameToken.Token.Type,
				Loc:      &nameToken.Span,
			}
		}
		if !token.CanPkgName(p.peekTok()) {
			break
		}
	}

	return tmp.String(), nil
}

func (p *Parser) eatWhitespaces(newlineHandle bool) {
	for p.peekTok() == token.Space ||
		p.peekTok() == token.Tab ||
		(p.peekTok() == token.Newline && newlineHandle) {
		p.nextTok()
	}
}

func (p *Parser) MakeLatexFormat() (string, VError) {
	latex, err := p.parseLatex()
	if err != nil {
		return "", err
	}

	return latex.String(), nil
}

func (p *Parser) parseLatex() (ast.Latex, VError) {
	latex := ast.Latex{Stmts: []ast.Statement{}}

	for p.peekTok() != token.EOF {
		stmt, err := p.parseStatement()
		if err != nil {
			return latex, err
		}
		latex.Stmts = append(latex.Stmts, stmt)
	}
	if p.documentState == 0b001 {
		latex.Stmts = append(latex.Stmts, &ast.DocumentEnd{})
	}

	return latex, nil
}

func (p *Parser) parseStatement() (ast.Statement, VError) {
	switch p.peekTok() {
	case token.Docclass:
		if p.documentState&0b001 == 0 {
			return p.parseDocClass()
		} else {
			return p.parseMainString()
		}
	case token.Import:
		if p.documentState&0b001 == 0 {
			return p.parseUsePackage()
		} else {
			return p.parseMainString()
		}
	case token.Document:
		if p.documentState&0b001 == 0 {
			p.documentState |= 0b001
			p.nextTok()
			p.eatWhitespaces(true)
			return &ast.DocumentStart{}, nil
		} else {
			return p.parseMainString()
		}
	case token.Begenv:
		return p.parseEnvironment()
	case token.Endenv:
		return nil, &verror.EndenvIsUsedWithoutBegenvPairErr{Loc: p.peekTokLoaction()}
	case token.Mtxt:
		return p.parseTextInMath()
	case token.Etxt:
		return nil, &verror.InvalidTokToParse{Got: token.Etxt, Loc: p.peekTokLoaction()}
	case token.DocumentStartMode:
		p.documentState |= 0b101
		loc := &p.nextTok().Span
		p.expectPeek(loc, token.Newline, token.Newline2)
		return p.parseStatement()
	case token.LatexFunction:
		return p.parseLatexFunction()
	case token.RawLatex:
		output := p.nextTok()
		if p.peekTok() == token.Newline {
			p.nextTok()
		}
		return &ast.RawLatex{Value: output.Token.Literal}, nil
	case token.Integer:
		return p.parseInteger()
	case token.Float:
		return p.parseFloat()
	case token.TextMathStart:
		return p.parseMathStmt()
	case token.InlineMathStart:
		return p.parseMathStmt()
	case token.TextMathEnd:
		return nil, &verror.InvalidTokToParse{Got: token.TextMathEnd, Loc: p.peekTokLoaction()}
	case token.InlineMathEnd:
		return nil, &verror.InvalidTokToParse{Got: token.InlineMathEnd, Loc: p.peekTokLoaction()}
	case token.EOF:
		p.documentState |= 0b010
		return &ast.DocumentEnd{}, nil
	default:
		if token.ShouldNotUseBeforeDoc(p.peekTok()) && p.documentState&0b001 == 0 {
			return nil, &verror.BeforeDocumentErr{Got: p.peekTok(), Loc: p.peekTokLoaction()}
		}
		return p.parseMainString()
	}
}

func (p *Parser) parseInteger() (*ast.Integer, VError) {
	currTok := p.nextTok()
	output, err := strconv.ParseInt(currTok.Token.Literal, 10, 64)
	if err != nil {
		return nil, &verror.ParseIntErr{Loc: &currTok.Span}
	}

	return &ast.Integer{Value: output}, nil
}

func (p *Parser) parseFloat() (*ast.Float, VError) {
	currTok := p.nextTok()
	output, err := strconv.ParseFloat(currTok.Token.Literal, 64)
	if err != nil {
		return nil, &verror.ParseIntErr{Loc: &currTok.Span}
	}

	return &ast.Float{Value: output}, nil
}

func (p *Parser) parseMainString() (*ast.MainText, VError) {
	if p.peekTok() == token.EOF {
		return nil, &verror.EOFErr{Loc: p.peekTokLoaction()}
	}

	return &ast.MainText{Value: p.nextTok().Token.Literal}, nil
}

func (p *Parser) parseMathStmt() (*ast.MathText, VError) {
	var text []ast.Statement
	var state ast.MathState

	tokType := p.peekTok()
	switch tokType {
	case token.TextMathStart:
		if err := p.expectPeek(p.peekTokLoaction(), token.TextMathStart); err != nil {
			return nil, err
		}
		for p.peekTok() != token.TextMathEnd {
			stmt, err := p.parseStatement()
			if err != nil {
				return nil, err
			}
			text = append(text, stmt)
		}
		if err := p.expectPeek(p.peekTokLoaction(), token.TextMathEnd); err != nil {
			return nil, err
		}
		state = ast.TextState
	case token.InlineMathStart:
		if err := p.expectPeek(p.peekTokLoaction(), token.InlineMathStart); err != nil {
			return nil, err
		}
		for p.peekTok() != token.InlineMathEnd {
			stmt, err := p.parseStatement()
			if err != nil {
				return nil, err
			}
			text = append(text, stmt)
		}
		if err := p.expectPeek(p.peekTokLoaction(), token.InlineMathEnd); err != nil {
			return nil, err
		}
		state = ast.InlineState
	default:
		return nil, &verror.TypeMismatch{
			Expected: []token.TokenType{token.TextMathStart, token.InlineMathStart},
			Got:      tokType,
			Loc:      p.peekTokLoaction(),
		}
	}

	return &ast.MathText{State: state, Text: text}, nil
}

func (p *Parser) parseDocClass() (*ast.DocumentClass, VError) {
	var options []ast.Latex

	if err := p.expectPeek(p.peekTokLoaction(), token.Docclass); err != nil {
		return nil, err
	}
	p.eatWhitespaces(false)

	name, err := p.takeName()
	if err != nil {
		return nil, err
	}

	err = p.parseCommaArg(&options)
	if err != nil {
		return nil, err
	}
	if p.peekTok() == token.Newline {
		p.nextTok()
	}

	return &ast.DocumentClass{Name: name, Options: options}, nil
}

func (p *Parser) parseUsePackage() (ast.Statement, VError) {
	var options []ast.Latex

	if err := p.expectPeek(p.peekTokLoaction(), token.Import); err != nil {
		return nil, err
	}
	p.eatWhitespaces(false)

	if p.peekTok() == token.Lbrace {
		return p.parseMultiUsePackages()
	}

	name, err := p.takeName()
	if err != nil {
		return nil, err
	}

	err = p.parseCommaArg(&options)
	if err != nil {
		return nil, err
	}
	if p.peekTok() == token.Newline {
		p.nextTok()
	}

	return &ast.UsePackage{Name: name, Options: options}, nil
}

func (p *Parser) parseMultiUsePackages() (*ast.MultiUsePackages, VError) {
	var pkgs []ast.Statement

	if err := p.expectPeek(p.peekTokLoaction(), token.Lbrace); err != nil {
		return nil, err
	}
	p.eatWhitespaces(true)

	for p.peekTok() != token.Rbrace {
		var options []ast.Latex
		name, err := p.takeName()
		if err != nil {
			return nil, err
		}

		err = p.parseCommaArg(&options)
		if err != nil {
			return nil, err
		}

		if p.peekTok() == token.Newline {
			p.eatWhitespaces(true)
		} else if p.peekTok() == token.Rbrace {
			pkgs = append(pkgs, &ast.UsePackage{Name: name, Options: options})
			break
		} else if p.peekTok() != token.MainString && p.peekTok() != token.RawLatex {
			return nil, &verror.TypeMismatch{
				Expected: []token.TokenType{
					token.Newline,
					token.Rbrace,
					token.MainString,
					token.RawLatex,
				},
				Got: p.peekTok(),
				Loc: p.peekTokLoaction(),
			}
		}

		pkgs = append(pkgs, &ast.UsePackage{Name: name, Options: options})
	}

	if err := p.expectPeek(p.peekTokLoaction(), token.Rbrace); err != nil {
		return nil, err
	}
	if p.peekTok() == token.Newline {
		p.nextTok()
	}

	return &ast.MultiUsePackages{Pkgs: pkgs}, nil
}

func (p *Parser) parseTextInMath() (*ast.PlainTextInMath, VError) {
	var output ast.Latex

	if err := p.expectPeek(p.peekTokLoaction(), token.Mtxt); err != nil {
		return nil, err
	}
	p.eatWhitespaces(false)

	for p.peekTok() != token.Etxt {
		if p.peekTok() == token.EOF {
			return nil, &verror.EOFErr{Loc: p.peekTokLoaction()}
		}

		stmt, err := p.parseStatement()
		if err != nil {
			return nil, err
		}
		output.Stmts = append(output.Stmts, stmt)
	}

	if err := p.expectPeek(p.peekTokLoaction(), token.Etxt); err != nil {
		return nil, err
	}

	return &ast.PlainTextInMath{Value: &output}, nil
}

func (p *Parser) parseEnvironment() (*ast.Environment, VError) {
	var name string
	beginLocation := p.peekTokLoaction()

	if err := p.expectPeek(p.peekTokLoaction(), token.Begenv); err != nil {
		return nil, err
	}
	p.eatWhitespaces(false)

	if p.peekTok() == token.EOF {
		return nil, &verror.EOFErr{Loc: beginLocation}
	}

	if p.peekTok() == token.MainString {
		name = p.nextTok().Token.Literal
	} else if p.peekTok() != token.EOF {
		return nil, &verror.BegenvNameMissErr{Loc: beginLocation}
	} else {
		return nil, &verror.EOFErr{Loc: beginLocation}
	}

	// If name is either equation or align, then math mode will be turned on
	if name == "equation" || name == "align" {
		p.source.MathStarted = true
	}

	if p.peekTok() == token.Star {
		if err := p.expectPeek(p.peekTokLoaction(), token.Star); err != nil {
			return nil, err
		}
		name += "*"
	}
	p.eatWhitespaces(false)

	args, err := p.parseFunctionArg(token.Lparen, token.Rparen, token.Lsqbrace, token.Rsqbrace)
	if err != nil {
		return nil, err
	}

	text := &ast.Latex{Stmts: []ast.Statement{}}
	for p.peekTok() != token.Endenv {
		if p.peekTok() == token.EOF {
			return nil, &verror.BegenvIsNotClosedErr{Loc: beginLocation}
		}
		stmt, err := p.parseStatement()
		if err != nil {
			return nil, err
		}
		text.Stmts = append(text.Stmts, stmt)
	}
	if err := p.expectPeek(p.peekTokLoaction(), token.Endenv); err != nil {
		return nil, err
	}
	if p.peekTok() == token.Newline {
		p.nextTok()
	}

	// If name is either equation or align, then math mode will be turned off
	if name == "equation" || name == "align" {
		p.source.MathStarted = false
	}

	return &ast.Environment{Name: name, Args: args, Text: text}, nil
}

func (p *Parser) parseLatexFunction() (*ast.LatexFunction, VError) {
	nextTok := p.nextTok()
	if nextTok.Token.Type == token.EOF {
		return nil, &verror.EOFErr{Loc: p.peekTokLoaction()}
	}
	name := nextTok.Token.Literal

	isNoArgButSpace := false
	if p.peekTok() == token.Space {
		isNoArgButSpace = true
		p.eatWhitespaces(false)
	}

	args, err := p.parseFunctionArg(token.Lbrace, token.Rbrace, token.OptionalLbrace, token.OptionalRbrace)
	if err != nil {
		return nil, err
	}
	if len(args) == 0 && isNoArgButSpace {
		name += " "
	}

	return &ast.LatexFunction{Name: name, Args: args}, nil
}

func (p *Parser) parseCommaArg(options *[]ast.Latex) VError {
	p.eatWhitespaces(false)
	if p.peekTok() == token.Lparen {
		var optionsVec []ast.Latex

		openBraceLocation := p.peekTokLoaction()
		p.nextTok()
		p.eatWhitespaces(true)

		for p.peekTok() != token.Rparen {
			if p.peekTok() == token.EOF {
				return &verror.BracketNumberMatchedErr{Loc: openBraceLocation}
			}

			p.eatWhitespaces(true)
			var tmp ast.Latex

			for p.peekTok() != token.Comma {
				p.eatWhitespaces(true)
				if p.peekTok() == token.EOF {
					return &verror.BracketNumberMatchedErr{Loc: openBraceLocation}
				}
				if p.peekTok() == token.Rparen {
					break
				}
				stmt, err := p.parseStatement()
				if err != nil {
					return err
				}
				tmp.Stmts = append(tmp.Stmts, stmt)
			}

			optionsVec = append(optionsVec, tmp)
			p.eatWhitespaces(true)

			if p.peekTok() == token.Rparen {
				break
			}

			if err := p.expectPeek(p.peekTokLoaction(), token.Comma); err != nil {
				return err
			}
			p.eatWhitespaces(true)
		}

		if err := p.expectPeek(p.peekTokLoaction(), token.Rparen); err != nil {
			return err
		}
		p.eatWhitespaces(false)
		*options = optionsVec
	}

	return nil
}

func (p *Parser) parseFunctionArg(open, closed, optOpen, optClose token.TokenType) ([]ast.Argument, VError) {
	var args []ast.Argument

	for p.peekTok() == open || p.peekTok() == optOpen || p.peekTok() == token.Star {
		switch {
		case p.peekTok() == open:
			err := p.parseFunctionArgCore(&args, open, closed, ast.MainArg)
			if err != nil {
				return nil, err
			}
		case p.peekTok() == optOpen:
			err := p.parseFunctionArgCore(&args, optOpen, optClose, ast.Optional)
			if err != nil {
				return nil, err
			}
		case p.peekTok() == token.Star:
			if err := p.expectPeek(p.peekTokLoaction(), token.Star); err != nil {
				return nil, err
			}
			args = append(args, ast.Argument{ArgType: ast.StarArg, Text: nil})
		default:
			break
		}

		if p.peekTok() == token.Newline || p.peekTok() == token.EOF {
			break
		}
	}

	return args, nil
}

func (p *Parser) parseFunctionArgCore(
	args *[]ast.Argument,
	open, closed token.TokenType,
	argNeed ast.ArgNeed,
) VError {
	openBraceLocation := p.peekTokLoaction()
	nested := 0
	if err := p.expectPeek(openBraceLocation, open); err != nil {
		return err
	}

	for {
		var tmpVec []ast.Statement
		for (p.peekTok() != closed || nested > 0) && p.peekTok() != token.ArgSpliter {
			if p.peekTok() == token.EOF {
				return &verror.BracketNumberMatchedErr{Loc: openBraceLocation}
			}
			if p.peekTok() == open {
				nested += 1
			}
			if p.peekTok() == closed {
				nested -= 1
			}
			stmt, err := p.parseStatement()
			if err != nil {
				return err
			}
			tmpVec = append(tmpVec, stmt)
		}
		*args = append(*args, ast.Argument{ArgType: argNeed, Text: &ast.Latex{Stmts: tmpVec}})

		if p.peekTok() != token.ArgSpliter {
			break
		}
		if err := p.expectPeek(p.peekTokLoaction(), token.ArgSpliter); err != nil {
			return err
		}
		// Multiline splitting arguments support
		p.eatWhitespaces(true)

	}
	if err := p.expectPeek(p.peekTokLoaction(), closed); err != nil {
		return err
	}

	return nil
}

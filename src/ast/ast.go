package ast

import (
	"bytes"
	"strconv"
	"strings"
)

// Two Distinct enum like types
type MathState uint8
type ArgNeed uint8

const (
	TextState MathState = iota
	InlineState
)

const (
	MainArg ArgNeed = iota
	Optional
	StarArg
)

// Node and Statement interface signatures
type Node interface {
	Type() string
	String() string
}

type Statement interface {
	Node
	statementNode()
}

////////////////////////////////////////

// Latex Statement
type Latex struct {
	Stmts []Statement
}

func (latex *Latex) String() string {
	var out bytes.Buffer

	for _, stmt := range latex.Stmts {
		out.WriteString(stmt.String())
	}

	return out.String()
}

// DocumentClass Statement
type DocumentClass struct {
	Name    string
	Options []Latex
}

func (doc *DocumentClass) String() string {
	var out bytes.Buffer

	out.WriteString("\\documentclass")
	if len(doc.Options) != 0 {
		var opts []string
		out.WriteByte('[')
		for _, opt := range doc.Options {
			opts = append(opts, opt.String())
		}
		out.WriteString(strings.Join(opts, ","))
		out.WriteByte(']')
	}

	out.WriteByte('{')
	out.WriteString(doc.Name)
	out.WriteString("}\n")

	return out.String()
}

// Usepackage Statement
type UsePackage struct {
	Name    string
	Options []Latex
}

func (up *UsePackage) String() string {
	var out bytes.Buffer

	out.WriteString("\\usepackage")
	if len(up.Options) != 0 {
		var opts []string
		out.WriteByte('[')
		for _, opt := range up.Options {
			opts = append(opts, opt.String())
		}
		out.WriteString(strings.Join(opts, ","))
		out.WriteByte(']')
	}

	out.WriteByte('{')
	out.WriteString(up.Name)
	out.WriteString("}\n")

	return out.String()
}

// MultiUsePackages Statement
type MultiUsePackages struct {
	Pkgs []Statement
}

func (mup *MultiUsePackages) String() string {
	var out bytes.Buffer

	for _, pkg := range mup.Pkgs {
		out.WriteString(pkg.String())
	}

	return out.String()
}

// DocumentStart Statement
type DocumentStart struct{}

func (ds *DocumentStart) String() string { return "\n\\begin{document}\n" }

// DocumentEnd Statement
type DocumentEnd struct{}

func (de *DocumentEnd) String() string { return "\n\\end{document}\n" }

// MainText Statement
type MainText struct {
	Value string
}

func (mt *MainText) String() string { return mt.Value }

// Integer Statement
type Integer struct {
	Value int64
}

func (i *Integer) String() string { return strconv.FormatInt(i.Value, 10) }

// Float Statement
type Float struct {
	Value float64
}

func (f *Float) String() string { return strconv.FormatFloat(f.Value, 'g', -1, 64) }

type RawLatex struct {
	Value string
}

func (rl *RawLatex) String() string { return rl.Value }

type MathText struct {
	State MathState
	Text  []Statement
}

func (mt *MathText) String() string {
	var out bytes.Buffer

	switch mt.State {
	case TextState:
		out.WriteByte('$')
		for _, text := range mt.Text {
			out.WriteString(text.String())
		}
		out.WriteByte('$')
	case InlineState:
		out.WriteString("\\[")
		for _, text := range mt.Text {
			out.WriteString(text.String())
		}
		out.WriteString("\\]")
	}

	return out.String()
}

type PlainTextInMath struct {
	Value *Latex
}

func (ptlm *PlainTextInMath) String() string {
	var out bytes.Buffer

	out.WriteString("\\text{")
	out.WriteString(ptlm.Value.String())
	out.WriteByte('\b')
	out.WriteByte('}')

	return out.String()
}

// LatexFunction Statement
type Argument struct {
	ArgType ArgNeed
	Text    *Latex
}
type LatexFunction struct {
	Name string
	Args []Argument
}

func (lf *LatexFunction) String() string {
	var out bytes.Buffer

	out.WriteByte('\\')
	out.WriteString(lf.Name)

	for _, arg := range lf.Args {
		switch arg.ArgType {
		case MainArg:
			out.WriteByte('{')
			out.WriteString(arg.Text.String())
			out.WriteByte('}')
		case Optional:
			out.WriteByte('[')
			out.WriteString(arg.Text.String())
			out.WriteByte(']')
		case StarArg:
			out.WriteByte('*')
		}
	}

	return out.String()
}

// Environment Statement
type Environment struct {
	Name string
	Args []Argument
	Text *Latex
}

func (env *Environment) String() string {
	var out bytes.Buffer

	out.WriteString("\\begin{")
	out.WriteString(env.Name)
	out.WriteByte('}')

	for _, arg := range env.Args {
		switch arg.ArgType {
		case MainArg:
			out.WriteByte('{')
			out.WriteString(arg.Text.String())
			out.WriteByte('}')
		case Optional:
			out.WriteByte('[')
			out.WriteString(arg.Text.String())
			out.WriteByte(']')
		case StarArg:
			out.WriteByte('*')
		}
	}

	out.WriteString(env.Text.String())

	out.WriteString("\\end{")
	out.WriteString(env.Name)
	out.WriteString("}\n")

	return out.String()
}

//////////////////////////////////////////////////
// Implementation Dummy
//////////////////////////////////////////////////

func (latex *Latex) Type() string          { return "LaTeX" }
func (doc *DocumentClass) Type() string    { return "DocumentClass" }
func (up *UsePackage) Type() string        { return "UsePackage" }
func (mup *MultiUsePackages) Type() string { return "MultiUsePackages" }
func (ds *DocumentStart) Type() string     { return "DocumentStart" }
func (de *DocumentEnd) Type() string       { return "DocumentEnd" }
func (mt *MainText) Type() string          { return "MainText" }
func (i *Integer) Type() string            { return "Integer" }
func (f *Float) Type() string              { return "Float" }
func (rl *RawLatex) Type() string          { return "RawLatex" }
func (mt *MathText) Type() string          { return "MathText" }
func (ptlm *PlainTextInMath) Type() string { return "PlainTextInMath" }
func (lf *LatexFunction) Type() string     { return "LatexFunction" }
func (env *Environment) Type() string      { return "Environment" }

func (doc *DocumentClass) statementNode()    {}
func (up *UsePackage) statementNode()        {}
func (mup *MultiUsePackages) statementNode() {}
func (ds *DocumentStart) statementNode()     {}
func (de *DocumentEnd) statementNode()       {}
func (mt *MainText) statementNode()          {}
func (i *Integer) statementNode()            {}
func (f *Float) statementNode()              {}
func (rl *RawLatex) statementNode()          {}
func (mt *MathText) statementNode()          {}
func (ptlm *PlainTextInMath) statementNode() {}
func (lf *LatexFunction) statementNode()     {}
func (env *Environment) statementNode()      {}

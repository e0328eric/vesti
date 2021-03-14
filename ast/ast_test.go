package ast

import "testing"

func TestAstToString(t *testing.T) {
	tests := []struct {
		input    Statement
		expected string
	}{
		{
			&DocumentClass{Name: "article", Options: nil},
			"\\documentclass{article}\n",
		},
		{
			&DocumentClass{Name: "coprime", Options: []Latex{
				{Stmts: []Statement{&MainText{Value: "tikz"}}},
				{Stmts: []Statement{&MainText{Value: "korean"}}},
				{Stmts: []Statement{&MainText{Value: "geometry"}}},
			}},
			"\\documentclass[tikz,korean,geometry]{coprime}\n",
		},
		{
			&UsePackage{Name: "amsmath", Options: nil},
			"\\usepackage{amsmath}\n",
		},
		{
			&UsePackage{Name: "geometry", Options: []Latex{
				{Stmts: []Statement{&MainText{Value: "a4paper"}}},
				{Stmts: []Statement{
					&MainText{Value: "margin"},
					&MainText{Value: "="},
					&Float{Value: 0.4},
					&LatexFunction{Name: "textwidth", Args: nil},
				}},
			}},
			"\\usepackage[a4paper,margin=0.4\\textwidth]{geometry}\n",
		},
		{
			&LatexFunction{Name: "foo", Args: []Argument{
				{ArgType: StarArg, Text: nil},
				{ArgType: MainArg, Text: &Latex{[]Statement{
					&MainText{Value: "bar1"},
					&MainText{Value: " "},
					&MainText{Value: "and"},
					&MainText{Value: " "},
					&Integer{Value: 3},
					&MainText{Value: "!"},
				}}},
				{ArgType: Optional, Text: &Latex{[]Statement{
					&MainText{Value: "bar2"},
				}}},
				{ArgType: StarArg, Text: nil},
				{ArgType: StarArg, Text: nil},
				{ArgType: Optional, Text: &Latex{[]Statement{
					&MainText{Value: "bar3"},
				}}},
				{ArgType: MainArg, Text: &Latex{[]Statement{
					&MainText{Value: "bar4"},
				}}},
			}},
			"\\foo*{bar1 and 3!}[bar2]**[bar3]{bar4}",
		},
		{
			&Environment{
				Name: "foo",
				Args: []Argument{
					{ArgType: MainArg, Text: &Latex{[]Statement{
						&MainText{Value: "bar1"},
					}}},
					{ArgType: Optional, Text: &Latex{[]Statement{
						&MainText{Value: "bar2"},
					}}},
					{ArgType: StarArg, Text: nil},
					{ArgType: Optional, Text: &Latex{[]Statement{
						&MainText{Value: "bar3"},
						&MainText{Value: " "},
						&MainText{Value: "and"},
						&MainText{Value: " "},
						&MainText{Value: "bar4"},
					}}},
					{ArgType: StarArg, Text: nil},
				},
				Text: &Latex{[]Statement{
					&MainText{Value: "\n"},
					&MainText{Value: "The"},
					&MainText{Value: " "},
					&MainText{Value: "Document"},
					&MainText{Value: "\n"},
				}},
			},
			"\\begin{foo}{bar1}[bar2]*[bar3 and bar4]*\nThe Document\n\\end{foo}\n",
		},
	}

	for _, test := range tests {
		if test.input.String() != test.expected {
			t.Errorf("expected=%s\ngot=%s", test.expected, test.input.String())
			continue
		}
	}
}

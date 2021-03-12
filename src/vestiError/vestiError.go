package vestiError

import (
	"fmt"
	"strings"
	"vesti/src/location"
	"vesti/src/token"
)

// TODO: implement "func Error() string"
type VestiErr interface {
	ErrKind() uint16
	ErrString() string
	ErrDetailStr() []string
	Location() *location.Span
}

type VestiParseErr interface {
	VestiErr
	parseErr()
}

//////////////////////////////////////////////////
// Implement Possible Parse Errors
//////////////////////////////////////////////////

type EOFErr struct {
	Loc *location.Span
}

func (e *EOFErr) ErrString() string {
	return "EOF found unexpectedly"
}
func (e *EOFErr) ErrDetailStr() []string { return nil }

type TypeMismatch struct {
	Expected []token.TokenType
	Got      token.TokenType
	Loc      *location.Span
}

func (tm *TypeMismatch) ErrString() string {
	return "Type mismatched"
}
func (tm *TypeMismatch) ErrDetailStr() []string {
	var expectedLst []string
	for _, t := range tm.Expected {
		expectedLst = append(expectedLst, token.ToString(t))
	}
	expected := strings.Join(expectedLst, ", ")

	return []string{fmt.Sprintf("expected %q, got %q", expected, token.ToString(tm.Got))}
}

type BeforeDocumentErr struct {
	Got token.TokenType
	Loc *location.Span
}

func (bd *BeforeDocumentErr) ErrString() string {
	return fmt.Sprintf("Type %q must be placed after `document`", token.ToString(bd.Got))
}
func (bd *BeforeDocumentErr) ErrDetailStr() []string {
	return []string{fmt.Sprintf("move %q after `document` keyword", token.ToString(bd.Got))}
}

type ParseIntErr struct {
	Loc *location.Span
}

func (pi *ParseIntErr) ErrString() string {
	return "Parsing integer error occurs"
}
func (pi *ParseIntErr) ErrDetailStr() []string {
	return []string{
		"if this error occurs, this preprocessor has an error",
		"so let me know when this error occurs",
	}
}

type ParseFloatErr struct {
	Loc *location.Span
}

func (pf *ParseFloatErr) ErrString() string {
	return "Parsing float error occurs"
}
func (pf *ParseFloatErr) ErrDetailStr() []string {
	return []string{
		"if this error occurs, this preprocessor has an error",
		"so let me know when this error occurs",
	}
}

type InvalidTokToParse struct {
	Got token.TokenType
	Loc *location.Span
}

func (it *InvalidTokToParse) ErrString() string {
	return fmt.Sprintf("Token %q is not parsable", token.ToString(it.Got))
}
func (it *InvalidTokToParse) ErrDetailStr() []string {
	if it.Got == token.Etxt {
		return []string{"must use `etxt` only at the math context"}
	}
	return nil
}

type BracketMismatchErr struct {
	Expected token.TokenType
	Loc      *location.Span
}

func (bm *BracketMismatchErr) ErrString() string {
	return fmt.Sprintf("Cannot find %q delimiter", token.ToString(bm.Expected))
}
func (bm *BracketMismatchErr) ErrDetailStr() []string {
	return []string{fmt.Sprintf("Cannot find %q delimiter", token.ToString(bm.Expected))}
}

type BracketNumberMatchedErr struct {
	Loc *location.Span
}

func (bn *BracketNumberMatchedErr) ErrString() string {
	return "Delimiter pair does not matched"
}
func (bn *BracketNumberMatchedErr) ErrDetailStr() []string {
	return []string{
		"cannot find a bracket that matches with that one",
		"help: close a bracket with an appropriate one",
	}
}

type BegenvIsNotClosedErr struct {
	Loc *location.Span
}

func (bi *BegenvIsNotClosedErr) ErrString() string {
	return "`begenv` is not closed"
}
func (bi *BegenvIsNotClosedErr) ErrDetailStr() []string {
	return []string{
		"cannot find `endenv` to close this environment",
		"check that `endenv` is properly closed",
	}
}

type EndenvIsUsedWithoutBegenvPairErr struct {
	Loc *location.Span
}

func (ei *EndenvIsUsedWithoutBegenvPairErr) ErrString() string {
	return "`endenv` is used without `begenv` pair"
}
func (ei *EndenvIsUsedWithoutBegenvPairErr) ErrDetailStr() []string {
	return []string{
		"`endenv` is used, but there is no `begenv`	to be pair with it",
		"help: add `begenv` before this `endenv` keyword",
	}
}

type BegenvNameMissErr struct {
	Loc *location.Span
}

func (bn *BegenvNameMissErr) ErrString() string {
	return "Missing environment name"
}
func (bn *BegenvNameMissErr) ErrDetailStr() []string {
	return []string{
		"`begenv` is used here, but vesti cannot",
		"find its name part. Type its name.",
		"example: begenv foo",
	}
}

//////////////////////////////////////////////////
// Implementation Dummy
//////////////////////////////////////////////////

func (e *EOFErr) ErrKind() uint16                            { return 0x01FF }
func (tm *TypeMismatch) ErrKind() uint16                     { return 0x0101 }
func (bd *BeforeDocumentErr) ErrKind() uint16                { return 0x0102 }
func (pi *ParseIntErr) ErrKind() uint16                      { return 0x0103 }
func (pf *ParseFloatErr) ErrKind() uint16                    { return 0x0104 }
func (it *InvalidTokToParse) ErrKind() uint16                { return 0x0105 }
func (bm *BracketMismatchErr) ErrKind() uint16               { return 0x0106 }
func (bn *BracketNumberMatchedErr) ErrKind() uint16          { return 0x0107 }
func (bi *BegenvIsNotClosedErr) ErrKind() uint16             { return 0x0108 }
func (ei *EndenvIsUsedWithoutBegenvPairErr) ErrKind() uint16 { return 0x0108 }
func (bn *BegenvNameMissErr) ErrKind() uint16                { return 0x0109 }

func (e *EOFErr) Location() *location.Span                            { return e.Loc }
func (tm *TypeMismatch) Location() *location.Span                     { return tm.Loc }
func (bd *BeforeDocumentErr) Location() *location.Span                { return bd.Loc }
func (pi *ParseIntErr) Location() *location.Span                      { return pi.Loc }
func (pf *ParseFloatErr) Location() *location.Span                    { return pf.Loc }
func (it *InvalidTokToParse) Location() *location.Span                { return it.Loc }
func (bm *BracketMismatchErr) Location() *location.Span               { return bm.Loc }
func (bn *BracketNumberMatchedErr) Location() *location.Span          { return bn.Loc }
func (bi *BegenvIsNotClosedErr) Location() *location.Span             { return bi.Loc }
func (ei *EndenvIsUsedWithoutBegenvPairErr) Location() *location.Span { return ei.Loc }
func (bn *BegenvNameMissErr) Location() *location.Span                { return bn.Loc }

func (e *EOFErr) parseErr()                            {}
func (tm *TypeMismatch) parseErr()                     {}
func (bd *BeforeDocumentErr) parseErr()                {}
func (pi *ParseIntErr) parseErr()                      {}
func (pf *ParseFloatErr) parseErr()                    {}
func (it *InvalidTokToParse) parseErr()                {}
func (bm *BracketMismatchErr) parseErr()               {}
func (bn *BracketNumberMatchedErr) parseErr()          {}
func (bi *BegenvIsNotClosedErr) parseErr()             {}
func (ei *EndenvIsUsedWithoutBegenvPairErr) parseErr() {}
func (bn *BegenvNameMissErr) parseErr()                {}

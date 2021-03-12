package token

type TokenType = uint16

///////////////////////
// Token Type List
///////////////////////
// Whitespace
// Bit flag : 0000 0001 .... ....
const (
	Space  TokenType = (1 << 8) + iota
	Space2           // \_ where _ is a space character
	Tab
	Newline
	Newline2       // #@
	MathSmallSpace // \,
	MathLargeSpace // \;
)

// Identifiers
// Bit flag : 0000 0010 .... ....
const (
	Integer TokenType = (1 << 9) + iota
	Float
	MainString
	LatexFunction
	RawLatex
)

// Keywords
// Bit flag : 0000 0100 .... ....
const (
	Docclass TokenType = (1 << 10) + iota
	Import
	Document
	Begenv
	Endenv
	Mtxt
	Etxt
)

// Symbols
// Bit flag : 0000 1000 .... ....
const (
	Plus        TokenType = (1 << 11) + iota // +
	Minus                                    // -
	Star                                     // *
	Slash                                    // /
	Equal                                    // =
	Less                                     // <
	Great                                    // >
	LessEq                                   // <=
	GreatEq                                  // >=
	Bang                                     // !
	Question                                 // ?
	Dollar                                   // $
	Sharp                                    // \#
	FntParam                                 // #
	At                                       // @
	Percent                                  // %
	Superscript                              // ^
	Subscript                                // _
	Ampersand                                // &
	BackSlash                                // \
	Vert                                     // |
	Period                                   // .
	Comma                                    //
	Colon                                    // :
	Semicolon                                // ;
	Tilde                                    // ~
	Quote                                    // '
	Quote2                                   // `
	Doublequote                              // "
)

// Delimiters
// Bit flag : 0001 0000 .... ....
const (
	Lparen                    TokenType = (1 << 12) + iota // (
	Rparen                                                 // )
	Lbrace                                                 // {
	Rbrace                                                 // }
	Lsqbrace                                               // [
	Rsqbrace                                               // ]
	MathLbrace                                             // \{
	MathRbrace                                             // \}
	TextMathStart                                          // $ or \(
	TextMathEnd                                            // $ or \)
	InlineMathStart                                        // $$ or \[
	InlineMathEnd                                          // $$ or \]
	ObeyNewlineBeforeDocStart                              // ##+
	ObeyNewlineBeforeDocEnd                                // +##
)

const (
	// etc
	// Bit flag : 0010 0000 0000 0000
	ArgSpliter TokenType = 0x2000

	// EOF
	EOF TokenType = 0xE0F0

	// error token
	ILLEGAL TokenType = 0xFFFF
)

type Token struct {
	Type    TokenType
	Literal string
}

func New(tok TokenType, literal string) Token {
	return Token{Type: tok, Literal: literal}
}

var keywords = map[string]TokenType{
	"docclass": Docclass,
	"import":   Import,
	"document": Document,
	"begenv":   Begenv,
	"endenv":   Endenv,
	"mtxt":     Mtxt,
	"etxt":     Etxt,
}

func Lookup(ident string) TokenType {
	tokType, ok := keywords[ident]
	if ok {
		return tokType
	}
	return MainString
}

func CanPkgName(tokType TokenType) bool {
	return tokType == MainString || tokType == Minus
}

func ShouldNotUseBeforeDoc(tokType TokenType) bool {
	return tokType == Space2 ||
		tokType == Begenv ||
		tokType == Endenv ||
		tokType == Mtxt ||
		tokType == Etxt ||
		tokType == MathSmallSpace ||
		tokType == MathLargeSpace ||
		tokType == MathLbrace ||
		tokType == MathRbrace ||
		tokType == TextMathStart ||
		tokType == TextMathEnd ||
		tokType == InlineMathStart ||
		tokType == InlineMathEnd
}

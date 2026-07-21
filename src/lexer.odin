package main

import "core:strconv"
import "core:unicode/utf8"

import uucode "./uucode"

Token_Kind :: enum u8 {
	Eof,

	Space,
	Tab,
	Newline,
	MathSmallSpace,
	MathLargeSpace,

	Integer,
	Float,
	Text,
	LatexFunction,
	MakeAtLetterFnt,
	Latex3Fnt,
	RawLatex,
	OtherChar,
	BuiltinFunction,
	LuaCodeStart,
	LuaCodeEnd,

	// Internal sentinels retain the Zig enum's ordering.  They are never
	// emitted, but make keyword-range checks cheap for the parser.
	Keyword_Begin,
	Docclass,
	ImportPkg,
	ImportVesti,
	ImportModule,
	StartDoc,
	Useenv,
	Begenv,
	Endenv,
	DefineFunction,
	DefineEnv,
	Keyword_End,

	Plus,
	Minus,
	SetMinus,
	EnDash,
	EmDash,
	Star,
	Slash,
	FracDefiner,
	Equal,
	EqEq,
	NotEqual,
	Less,
	Great,
	LessEq,
	GreatEq,
	LeftArrow,
	RightArrow,
	LeftRightArrow,
	LongLeftArrow,
	LongRightArrow,
	LongLeftRightArrow,
	DoubleRightArrow,
	DoubleLeftRightArrow,
	LongDoubleLeftArrow,
	LongDoubleRightArrow,
	LongDoubleLeftRightArrow,
	MapsTo,
	Bang,
	Question,
	LatexComment,
	TextPercent,
	RawPercent,
	TextSharp,
	RawSharp,
	TextDollar,
	RawDollar,
	At,
	Superscript,
	Subscript,
	Ampersand,
	BackSlash,
	ShortBackSlash,
	Vert,
	Norm,
	Period,
	Comma,
	Colon,
	Semicolon,
	Tilde,
	LeftQuote,
	RightQuote,
	DoubleQuote,
	CenterDots,
	InfinitySym,

	Lbrace,
	Rbrace,
	Lparen,
	Rparen,
	Lsqbrace,
	Rsqbrace,
	Langle,
	Rangle,
	MathLbrace,
	MathRbrace,
	InlineMathSwitch,
	DisplayMathSwitch,
	DisplayMathStart,
	DisplayMathEnd,

	Illegal,
	Deprecated,
}

Token_Literal :: struct {
	in_text: string,
	in_math: string,
}

Token_Deprecated :: struct {
	valid_in_text: bool,
	instead:       string,
}

// Payload fields are meaningful only for their corresponding Token_Kind.
// Keeping them in one struct avoids a second tagged-union dispatch in the
// parser while preserving the Zig token model exactly.
Token :: struct {
	kind:         Token_Kind,
	literal:      Token_Literal,
	span:         Span,
	builtin_name: string,
	deprecated:   Token_Deprecated,
}

token_invalid :: proc() -> Token {
	return Token{kind = .Illegal, span = span_init()}
}

token_make :: proc(
	kind: Token_Kind,
	in_text: string,
	in_math: string,
	start: Location,
	end: Location,
) -> Token {
	return Token{
		kind = kind,
		literal = {in_text = in_text, in_math = in_math},
		span = {start = start, end = end},
	}
}

token_make_same_literal :: proc(
	kind: Token_Kind,
	literal: string,
	start: Location,
	end: Location,
) -> Token {
	return token_make(kind, literal, literal, start, end)
}

token_eof :: proc(span: Span) -> Token {
	return Token{
		kind = .Eof,
		literal = {in_text = "", in_math = ""},
		span = span,
	}
}

token_is_function_param :: proc(value: string) -> (uint, bool) {
	if len(value) == 0 {
		return 0, false
	}
	return strconv.parse_uint(value, 10)
}

token_is_keyword_kind :: proc(kind: Token_Kind) -> bool {
	return int(kind) > int(Token_Kind.Keyword_Begin) &&
	       int(kind) < int(Token_Kind.Keyword_End)
}

token_is_builtin :: proc(name: string) -> bool {
	switch name {
	case "chardef", "copy_file", "engine_type", "enum", "enum_counter",
	     "eq", "get_filepath", "label", "mathchardef", "mathmode",
	     "picture", "raw_tex", "showfont", "textmode":
		return true
	}
	return false
}

token_is_preprocess_builtin :: proc(name: string) -> bool {
	switch name {
	case "at_on", "at_off", "def", "include", "ltx3_on", "ltx3_off",
	     "noltx3", "undef", "if", "ifdef", "ifndef", "elif", "elifdef",
	     "elifndef", "else", "endif":
		return true
	}
	return false
}

token_is_any_builtin :: proc(name: string) -> bool {
	return token_is_builtin(name) || token_is_preprocess_builtin(name)
}

token_keyword :: proc(word: string) -> (kind: Token_Kind, deprecated: Token_Deprecated, ok: bool) {
	switch word {
	case "docclass":
		return .Docclass, {}, true
	case "importpkg":
		return .ImportPkg, {}, true
	case "importves":
		return .ImportVesti, {}, true
	case "importmod":
		return .ImportModule, {}, true
	case "startdoc":
		return .StartDoc, {}, true
	case "useenv":
		return .Useenv, {}, true
	case "begenv":
		return .Begenv, {}, true
	case "endenv":
		return .Endenv, {}, true
	case "defun":
		return .DefineFunction, {}, true
	case "defenv":
		return .DefineEnv, {}, true
	case "compty":
		return .Deprecated, Token_Deprecated{valid_in_text = false, instead = "#engine_type"}, true
	case "cpfile":
		return .Deprecated, Token_Deprecated{valid_in_text = false, instead = "#copy_file"}, true
	}
	return .Text, {}, false
}

Get_Char_Type :: enum u8 {
	Current,
	Peek1,
	Peek2,
}

Tokenize_State :: enum u8 {
	Start,
	Comment,
	CommentStart,
	MultilineCommentStart,
	MultilineComment,
	MultilineCommentEnd,
	Verbatim,
	LineVerbatim,
	BuiltinFunction,
	LatexFunction,
	Text,
	Integer,
	Float,
	OChr,
	PercentChr,
	BackslashChr,
	SharpChr,
	LessChr,
}

Lexer :: struct {
	source:                  string,
	chr0_idx:                int,
	chr1_idx:                int,
	chr2_idx:                int,
	location:                Location,
	make_at_letter:           bool,
	is_latex3_on:             bool,
	lex_finished:             bool,
	comment_open_eq_count:    int,
	comment_closed_eq_count:  int,
}

lexer_init :: proc(source: string) -> Lexer {
	assert(utf8.valid_string(source), "given vesti file is not encoded as valid UTF-8")
	lexer := Lexer{
		source = source,
		location = location_init(),
	}
	lexer_next_char(&lexer, 2)
	lexer.location = location_init()
	return lexer
}

lexer_byte_len :: proc(lead: u8) -> int {
	switch {
	case lead < 0x80:
		return 1
	case lead & 0xe0 == 0xc0:
		return 2
	case lead & 0xf0 == 0xe0:
		return 3
	case lead & 0xf8 == 0xf0:
		return 4
	}
	panic("invalid UTF-8 leading byte")
}

lexer_get_char :: proc(lexer: Lexer, which: Get_Char_Type) -> rune {
	start := lexer.chr0_idx
	switch which {
	case .Current:
		start = lexer.chr0_idx
	case .Peek1:
		start = lexer.chr1_idx
	case .Peek2:
		start = lexer.chr2_idx
	}
	if start >= len(lexer.source) {
		return 0
	}
	cp, width := utf8.decode_rune_in_string(lexer.source[start:])
	// The source was validated in lexer_init.  Do not reject RUNE_ERROR here:
	// U+FFFD itself is a perfectly valid encoded scalar value.
	assert(width > 0, "invalid UTF-8 in lexer source")
	return cp
}

lexer_next_char :: proc(lexer: ^Lexer, amount: int) {
	assert(amount >= 1 && amount <= 3)
	for _ in 0..<amount {
		cp := lexer_get_char(lexer^, .Current)
		length := len(lexer.source)

		if lexer.chr2_idx < length {
			lexer.chr0_idx = lexer.chr1_idx
			lexer.chr1_idx = lexer.chr2_idx
			lexer.chr2_idx += lexer_byte_len(lexer.source[lexer.chr2_idx])
		} else if lexer.chr1_idx < length {
			lexer.chr0_idx = lexer.chr1_idx
			lexer.chr1_idx += lexer_byte_len(lexer.source[lexer.chr1_idx])
		} else if lexer.chr0_idx < length {
			lexer.chr0_idx += lexer_byte_len(lexer.source[lexer.chr0_idx])
		} else {
			lexer.lex_finished = true
			return
		}

		location_move(&lexer.location, cp)
	}
}

lexer_is_vesti_ident_char :: proc(cp: rune, at_is_letter, latex3: bool) -> bool {
	return uucode.is_alphabetic(cp) ||
	       (at_is_letter && cp == '@') ||
	       (latex3 && (cp == '_' || cp == ':'))
}

lexer_is_luacode_bracket_char :: proc(cp: rune) -> bool {
	return cp == ':' || uucode.is_ascii_alphanumeric(cp)
}

lexer_token_from_spelling :: proc(
	lexer: ^Lexer,
	spelling: string,
	start: Location,
) -> Token {
	in_text := spelling
	in_math := spelling
	kind: Token_Kind

	switch spelling {
	case "\x00": kind, in_text, in_math = .Eof, "", ""
	case "\n":   kind = .Newline
	case "\t":   kind = .Tab
	case " ":    kind = .Space
	case "+":    kind = .Plus
	case "-":    kind = .Minus
	case "--!":  kind, in_text, in_math = .EnDash, "--", "--"
	case "---":  kind = .EmDash
	case "*":    kind = .Star
	case "/":    kind = .Slash
	case "//":   kind = .FracDefiner
	case "=":    kind = .Equal
	case "==":   kind = .EqEq
	case "<":    kind = .Less
	case ">":    kind = .Great
	case "<=":   kind, in_math = .LessEq, "\\leq "
	case ">=":   kind, in_math = .GreatEq, "\\geq "
	case "/=":   kind, in_math = .NotEqual, "\\neq "
	case "!=":   kind, in_math = .NotEqual, "\\neq "
	case "<-":   kind, in_math = .LeftArrow, "\\leftarrow "
	case "->":   kind, in_math = .RightArrow, "\\rightarrow "
	case "=>":   kind, in_math = .DoubleRightArrow, "\\Rightarrow "
	case "<--":  kind, in_math = .LongLeftArrow, "\\longleftarrow "
	case "-->":  kind, in_math = .LongRightArrow, "\\longrightarrow "
	case "<==":  kind, in_math = .LongDoubleLeftArrow, "\\Longleftarrow "
	case "==>":  kind, in_math = .LongDoubleRightArrow, "\\Longrightarrow "
	case "<->":  kind, in_math = .LeftRightArrow, "\\leftrightarrow "
	case "<=>":  kind, in_math = .DoubleLeftRightArrow, "\\Leftrightarrow "
	case "<-->": kind, in_math = .LongLeftRightArrow, "\\longleftrightarrow "
	case "<==>": kind, in_math = .LongDoubleLeftRightArrow, "\\Longleftrightarrow "
	case "|->":  kind, in_math = .MapsTo, "\\mapsto "
	case "{":    kind = .Lbrace
	case "}":    kind = .Rbrace
	case "[":    kind = .Lsqbrace
	case "]":    kind = .Rsqbrace
	case "(":    kind = .Lparen
	case ")":    kind = .Rparen
	case "{<":   kind, in_math = .Langle, "\\langle "
	case ">}":   kind, in_math = .Rangle, "\\rangle "
	case "\\{":  kind = .MathLbrace
	case "\\}":  kind = .MathRbrace
	case "$":    kind = .InlineMathSwitch
	case "$$":   kind = .DisplayMathSwitch
	case "\\[":  kind = .DisplayMathStart
	case "\\]":  kind = .DisplayMathEnd
	case "\\,":  kind = .MathSmallSpace
	case "\\;":  kind = .MathLargeSpace
	case "\\ ":  kind, in_math = .MathLargeSpace, "\\;"
	case "\\":   kind = .ShortBackSlash
	case "\\\\": kind = .BackSlash
	case "@":    kind = .At
	case "^":    kind = .Superscript
	case "_":    kind = .Subscript
	case "!":    kind = .Bang
	case "?":    kind = .Question
	case "%":    kind = .LatexComment
	case "\\%":  kind = .TextPercent
	case "#":    kind = .RawSharp
	case "\\#":  kind = .TextSharp
	case "$#":   kind, in_text, in_math = .RawDollar, "$", "$"
	case "\\$":  kind = .TextDollar
	case ":":    kind = .Colon
	case ";":    kind = .Semicolon
	case ".":    kind = .Period
	case ",":    kind = .Comma
	case "-!":   kind, in_math = .SetMinus, "\\setminus "
	case "|":    kind = .Vert
	case "||":   kind, in_math = .Norm, "\\|"
	case "&":    kind = .Ampersand
	case "~":    kind = .Tilde
	case "`":    kind = .LeftQuote
	case "'":    kind = .RightQuote
	case "\"":   kind = .DoubleQuote
	case "...":  kind, in_math = .CenterDots, "\\cdots "
	case "oo":   kind, in_math = .InfinitySym, "\\infty "
	case:
		panic("unsupported fixed lexer spelling")
	}

	return token_make(kind, in_text, in_math, start, lexer.location)
}

lexer_next :: proc(lexer: ^Lexer) -> Token {
	start_location := lexer.location
	start_idx := lexer.chr0_idx

	if lexer.lex_finished {
		return lexer_token_from_spelling(lexer, "\x00", start_location)
	}

	state := Tokenize_State.Start
	for {
		switch state {
		case .Start:
			cp := lexer_get_char(lexer^, .Current)
			switch cp {
			case '\r':
				if lexer_get_char(lexer^, .Peek1) == '\n' {
					lexer_next_char(lexer, 2)
				} else {
					lexer_next_char(lexer, 1)
				}
				return lexer_token_from_spelling(lexer, "\n", start_location)

			case '%':
				lexer_next_char(lexer, 1)
				state = .PercentChr
				continue

			case 'o':
				start_idx = lexer.chr0_idx
				lexer_next_char(lexer, 1)
				state = .OChr
				continue

			case '-':
				switch lexer_get_char(lexer^, .Peek1) {
				case '-':
					switch lexer_get_char(lexer^, .Peek2) {
					case '>':
						lexer_next_char(lexer, 3)
						return lexer_token_from_spelling(lexer, "-->", start_location)
					case '-':
						lexer_next_char(lexer, 3)
						return lexer_token_from_spelling(lexer, "---", start_location)
					case '!':
						lexer_next_char(lexer, 3)
						return lexer_token_from_spelling(lexer, "--!", start_location)
					case:
						lexer_next_char(lexer, 2)
						state = .CommentStart
						continue
					}
				case '!':
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "-!", start_location)
				case '>':
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "->", start_location)
				case '.':
					start_idx = lexer.chr0_idx
					lexer_next_char(lexer, 1)
					state = .Float
					continue
				case:
					if uucode.is_ascii_digit(lexer_get_char(lexer^, .Peek1)) {
						start_idx = lexer.chr0_idx
						lexer_next_char(lexer, 1)
						state = .Integer
						continue
					}
					lexer_next_char(lexer, 1)
					return lexer_token_from_spelling(lexer, "-", start_location)
				}

			case '!':
				if lexer_get_char(lexer^, .Peek1) == '=' {
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "!=", start_location)
				}
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "!", start_location)

			case '/':
				switch lexer_get_char(lexer^, .Peek1) {
				case '=':
					lexer_next_char(lexer, 2)
					// Preserve the Zig lexer: `/=` is normalized to the `!=`
					// text literal, although both spellings map to NotEqual.
					return lexer_token_from_spelling(lexer, "!=", start_location)
				case '/':
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "//", start_location)
				case:
					lexer_next_char(lexer, 1)
					return lexer_token_from_spelling(lexer, "/", start_location)
				}

			case '$':
				switch lexer_get_char(lexer^, .Peek1) {
				case '#':
					peek2 := lexer_get_char(lexer^, .Peek2)
					if uucode.is_ascii_digit(peek2) || uucode.is_alphabetic(peek2) {
						lexer_next_char(lexer, 1)
						return lexer_token_from_spelling(lexer, "$", start_location)
					}
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "$#", start_location)
				case '$':
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "$$", start_location)
				case:
					lexer_next_char(lexer, 1)
					return lexer_token_from_spelling(lexer, "$", start_location)
				}

			case '.':
				if lexer_get_char(lexer^, .Peek1) == '.' && lexer_get_char(lexer^, .Peek2) == '.' {
					lexer_next_char(lexer, 3)
					return lexer_token_from_spelling(lexer, "...", start_location)
				}
				if uucode.is_ascii_digit(lexer_get_char(lexer^, .Peek1)) {
					start_idx = lexer.chr0_idx
					lexer_next_char(lexer, 1)
					state = .Float
					continue
				}
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, ".", start_location)

			case '|':
				if lexer_get_char(lexer^, .Peek1) == '|' {
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "||", start_location)
				}
				if lexer_get_char(lexer^, .Peek1) == '-' && lexer_get_char(lexer^, .Peek2) == '>' {
					lexer_next_char(lexer, 3)
					return lexer_token_from_spelling(lexer, "|->", start_location)
				}
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "|", start_location)

			case '=':
				switch lexer_get_char(lexer^, .Peek1) {
				case '=':
					if lexer_get_char(lexer^, .Peek2) == '>' {
						lexer_next_char(lexer, 3)
						return lexer_token_from_spelling(lexer, "==>", start_location)
					}
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "==", start_location)
				case '>':
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "=>", start_location)
				case:
					lexer_next_char(lexer, 1)
					return lexer_token_from_spelling(lexer, "=", start_location)
				}

			case '>':
				switch lexer_get_char(lexer^, .Peek1) {
				case '=':
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, ">=", start_location)
				case '}':
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, ">}", start_location)
				case:
					lexer_next_char(lexer, 1)
					return lexer_token_from_spelling(lexer, ">", start_location)
				}

			case '{':
				if lexer_get_char(lexer^, .Peek1) == '<' {
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "{<", start_location)
				}
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "{", start_location)

			case '\\':
				start_idx = lexer.chr0_idx
				lexer_next_char(lexer, 1)
				state = .BackslashChr
				continue

			case '#':
				start_idx = lexer.chr0_idx
				lexer_next_char(lexer, 1)
				state = .SharpChr
				continue

			case '<':
				lexer_next_char(lexer, 1)
				state = .LessChr
				continue

			case ':':
				if lexer_get_char(lexer^, .Peek1) == ':' && lexer_get_char(lexer^, .Peek2) == '#' {
					lexer_next_char(lexer, 3)
					return token_make_same_literal(
						.LuaCodeEnd,
						lexer.source[start_idx:lexer.chr0_idx],
						start_location,
						lexer.location,
					)
				}
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, ":", start_location)

			case '@':
				if lexer.make_at_letter {
					start_idx = lexer.chr0_idx
					lexer_next_char(lexer, 1)
					state = .Text
					continue
				}
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "@", start_location)

			case 0, '\n', '\t', ' ', '+', '*', '?', '_', '^', '&', ',', ';',
			     '~', '`', '\'', '"', '}', '[', ']', '(', ')':
				lexer_next_char(lexer, 1)
				if cp == 0 {
					return lexer_token_from_spelling(lexer, "\x00", start_location)
				}
				return lexer_token_from_spelling(
					lexer,
					lexer.source[start_idx:lexer.chr0_idx],
					start_location,
				)

			case:
				if uucode.is_ascii_digit(cp) {
					start_idx = lexer.chr0_idx
					lexer_next_char(lexer, 1)
					state = .Integer
					continue
				}
				if uucode.is_alphanumeric(cp) {
					start_idx = lexer.chr0_idx
					lexer_next_char(lexer, 1)
					state = .Text
					continue
				}

				start_idx = lexer.chr0_idx
				lexer_next_char(lexer, 1)
				return token_make_same_literal(
					.OtherChar,
					lexer.source[start_idx:lexer.chr0_idx],
					start_location,
					lexer.location,
				)
			}

		case .OChr:
			if lexer_get_char(lexer^, .Current) == 'o' &&
			   !uucode.is_alphabetic(lexer_get_char(lexer^, .Peek1)) {
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "oo", start_location)
			}
			state = .Text
			continue

		case .PercentChr:
			switch lexer_get_char(lexer^, .Current) {
			case '#':
				lexer_next_char(lexer, 1)
				start_idx = lexer.chr0_idx
				state = .LineVerbatim
				continue
			case '-':
				lexer_next_char(lexer, 1)
				start_idx = lexer.chr0_idx
				state = .Verbatim
				continue
			case '!':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "%", start_location)
			case:
				return lexer_token_from_spelling(lexer, "%", start_location)
			}

		case .SharpChr:
			if lexer_get_char(lexer^, .Current) == ':' && lexer_get_char(lexer^, .Peek1) == ':' {
				lexer_next_char(lexer, 2)
				return token_make_same_literal(
					.LuaCodeStart,
					lexer.source[start_idx:lexer.chr0_idx],
					start_location,
					lexer.location,
				)
			}

			cp := lexer_get_char(lexer^, .Current)
			if uucode.is_ascii_digit(cp) || uucode.is_alphabetic(cp) {
				lexer_next_char(lexer, 1)
				state = .BuiltinFunction
				continue
			}
			if cp == '!' {
				lexer_next_char(lexer, 1)
			}
			return lexer_token_from_spelling(lexer, "#", start_location)

		case .BackslashChr:
			switch lexer_get_char(lexer^, .Current) {
			case '\\':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\\\", start_location)
			case '#':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\#", start_location)
			case '$':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\$", start_location)
			case '%':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\%", start_location)
			case '[':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\[", start_location)
			case ']':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\]", start_location)
			case '{':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\{", start_location)
			case '}':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\}", start_location)
			case ',':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\,", start_location)
			case ';':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\;", start_location)
			case ' ':
				lexer_next_char(lexer, 1)
				return lexer_token_from_spelling(lexer, "\\ ", start_location)
			case:
				cp := lexer_get_char(lexer^, .Current)
				if lexer_is_vesti_ident_char(cp, lexer.make_at_letter, lexer.is_latex3_on) {
					lexer_next_char(lexer, 1)
					state = .LatexFunction
					continue
				}
				return lexer_token_from_spelling(lexer, "\\", start_location)
			}

		case .LessChr:
			switch lexer_get_char(lexer^, .Current) {
			case '=':
				switch lexer_get_char(lexer^, .Peek1) {
				case '=':
					if lexer_get_char(lexer^, .Peek2) == '>' {
						lexer_next_char(lexer, 3)
						return lexer_token_from_spelling(lexer, "<==>", start_location)
					}
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "<==", start_location)
				case '>':
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "<=>", start_location)
				case:
					lexer_next_char(lexer, 1)
					return lexer_token_from_spelling(lexer, "<=", start_location)
				}
			case '-':
				switch lexer_get_char(lexer^, .Peek1) {
				case '-':
					if lexer_get_char(lexer^, .Peek2) == '>' {
						lexer_next_char(lexer, 3)
						return lexer_token_from_spelling(lexer, "<-->", start_location)
					}
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "<--", start_location)
				case '>':
					lexer_next_char(lexer, 2)
					return lexer_token_from_spelling(lexer, "<->", start_location)
				case:
					lexer_next_char(lexer, 1)
					return lexer_token_from_spelling(lexer, "<-", start_location)
				}
			case:
				return lexer_token_from_spelling(lexer, "<", start_location)
			}

		case .Text:
			cp := lexer_get_char(lexer^, .Current)
			if uucode.is_ascii_digit(cp) ||
			   lexer_is_vesti_ident_char(cp, lexer.make_at_letter, lexer.is_latex3_on) {
				lexer_next_char(lexer, 1)
				continue
			}

			lexed := lexer.source[start_idx:lexer.chr0_idx]
			kind, deprecated, is_keyword := token_keyword(lexed)
			if is_keyword {
				token := token_make_same_literal(kind, lexed, start_location, lexer.location)
				token.deprecated = deprecated
				return token
			}
			return token_make_same_literal(.Text, lexed, start_location, lexer.location)

		case .BuiltinFunction:
			cp := lexer_get_char(lexer^, .Current)
			if uucode.is_ascii_alphanumeric(cp) || cp == '_' {
				lexer_next_char(lexer, 1)
				continue
			}

			name_with_sharp := lexer.source[start_idx:lexer.chr0_idx]
			end_location := lexer.location
			if cp == ' ' {
				peek := lexer_get_char(lexer^, .Peek1)
				if uucode.is_ascii_alphanumeric(peek) || peek == ' ' {
					lexer_next_char(lexer, 1)
				}
			}
			token := token_make_same_literal(
				.BuiltinFunction,
				lexer.source[start_idx:lexer.chr0_idx],
				start_location,
				end_location,
			)
			token.builtin_name = name_with_sharp[1:]
			return token

		case .LatexFunction:
			cp := lexer_get_char(lexer^, .Current)
			if lexer_is_vesti_ident_char(cp, lexer.make_at_letter, lexer.is_latex3_on) {
				lexer_next_char(lexer, 1)
				continue
			}
			kind := Token_Kind.LatexFunction
			if lexer.make_at_letter {
				kind = .MakeAtLetterFnt
			} else if lexer.is_latex3_on {
				kind = .Latex3Fnt
			}
			return token_make_same_literal(
				kind,
				lexer.source[start_idx:lexer.chr0_idx],
				start_location,
				lexer.location,
			)

		case .Integer:
			cp := lexer_get_char(lexer^, .Current)
			if uucode.is_ascii_digit(cp) {
				lexer_next_char(lexer, 1)
				continue
			}
			if uucode.is_ascii_alphanumeric(cp) {
				lexer_next_char(lexer, 1)
				state = .Text
				continue
			}
			if cp == '.' {
				lexer_next_char(lexer, 1)
				state = .Float
				continue
			}
			return token_make_same_literal(
				.Integer,
				lexer.source[start_idx:lexer.chr0_idx],
				start_location,
				lexer.location,
			)

		case .Float:
			if uucode.is_ascii_digit(lexer_get_char(lexer^, .Current)) {
				lexer_next_char(lexer, 1)
				continue
			}
			return token_make_same_literal(
				.Float,
				lexer.source[start_idx:lexer.chr0_idx],
				start_location,
				lexer.location,
			)

		case .CommentStart:
			switch lexer_get_char(lexer^, .Current) {
			case '\n', 0:
				lexer_next_char(lexer, 1)
				start_location = lexer.location
				start_idx = lexer.chr0_idx
				state = .Start
				continue
			case '[':
				lexer_next_char(lexer, 1)
				lexer.comment_open_eq_count = 0
				lexer.comment_closed_eq_count = 0
				state = .MultilineCommentStart
				continue
			case:
				lexer_next_char(lexer, 1)
				state = .Comment
				continue
			}

		case .Comment:
			switch lexer_get_char(lexer^, .Current) {
			case '\n', 0:
				lexer_next_char(lexer, 1)
				start_location = lexer.location
				start_idx = lexer.chr0_idx
				state = .Start
				continue
			case:
				lexer_next_char(lexer, 1)
				continue
			}

		case .MultilineCommentStart:
			switch lexer_get_char(lexer^, .Current) {
			case '=':
				lexer_next_char(lexer, 1)
				lexer.comment_open_eq_count += 1
				continue
			case '[':
				lexer_next_char(lexer, 1)
				state = .MultilineComment
				continue
			case:
				token := token_make_same_literal(
					.Illegal,
					lexer.source[start_idx:lexer.chr0_idx],
					start_location,
					lexer.location,
				)
				lexer_next_char(lexer, 1)
				return token
			}

		case .MultilineComment:
			switch lexer_get_char(lexer^, .Current) {
			case ']':
				lexer_next_char(lexer, 1)
				lexer.comment_closed_eq_count = 0
				state = .MultilineCommentEnd
				continue
			case 0:
				lexer_next_char(lexer, 1)
				state = .Start
				continue
			case:
				lexer_next_char(lexer, 1)
				continue
			}

		case .MultilineCommentEnd:
			switch lexer_get_char(lexer^, .Current) {
			case ']':
				if lexer.comment_open_eq_count == lexer.comment_closed_eq_count {
					lexer_next_char(lexer, 1)
					start_location = lexer.location
					start_idx = lexer.chr0_idx
					state = .Start
					continue
				}
				lexer_next_char(lexer, 1)
				lexer.comment_closed_eq_count = 0
				continue
			case 0:
				lexer_next_char(lexer, 1)
				state = .Start
				continue
			case '=':
				lexer_next_char(lexer, 1)
				lexer.comment_closed_eq_count += 1
				continue
			case:
				lexer_next_char(lexer, 1)
				state = .MultilineComment
				continue
			}

		case .Verbatim:
			if lexer_get_char(lexer^, .Current) == '-' && lexer_get_char(lexer^, .Peek1) == '%' {
				token := token_make_same_literal(
					.RawLatex,
					lexer.source[start_idx:lexer.chr0_idx],
					start_location,
					lexer.location,
				)
				lexer_next_char(lexer, 2)
				return token
			}
			if lexer_get_char(lexer^, .Current) == 0 {
				token := token_make_same_literal(
					.Illegal,
					lexer.source[start_idx:lexer.chr0_idx],
					start_location,
					lexer.location,
				)
				lexer_next_char(lexer, 1)
				return token
			}
			lexer_next_char(lexer, 1)
			continue

		case .LineVerbatim:
			switch lexer_get_char(lexer^, .Current) {
			case '\n':
				lexer_next_char(lexer, 1)
				return token_make_same_literal(
					.RawLatex,
					lexer.source[start_idx:lexer.chr0_idx],
					start_location,
					lexer.location,
				)
			case 0:
				token := token_make_same_literal(
					.Illegal,
					lexer.source[start_idx:lexer.chr0_idx],
					start_location,
					lexer.location,
				)
				lexer_next_char(lexer, 1)
				return token
			case:
				lexer_next_char(lexer, 1)
				continue
			}
		}
	}
}

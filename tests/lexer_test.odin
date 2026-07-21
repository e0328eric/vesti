package defkind_test

import "core:testing"

import vesti "../src"

Fixed_Token_Case :: struct {
	source:  string,
	kind:    vesti.Token_Kind,
	in_text: string,
	in_math: string,
}

expect_token :: proc(
	t: ^testing.T,
	lexer: ^vesti.Lexer,
	kind: vesti.Token_Kind,
	in_text: string,
	in_math: string,
) -> vesti.Token {
	token := vesti.lexer_next(lexer)
	testing.expect_value(t, token.kind, kind)
	testing.expect_value(t, token.literal.in_text, in_text)
	testing.expect_value(t, token.literal.in_math, in_math)
	return token
}

expect_same_token :: proc(
	t: ^testing.T,
	lexer: ^vesti.Lexer,
	kind: vesti.Token_Kind,
	literal: string,
) -> vesti.Token {
	return expect_token(t, lexer, kind, literal, literal)
}

expect_location :: proc(t: ^testing.T, location: vesti.Location, row, col: int) {
	testing.expect_value(t, location.row, row)
	testing.expect_value(t, location.col, col)
}

@(test)
lexer_fixed_spellings :: proc(t: ^testing.T) {
	cases := [?]Fixed_Token_Case{
		{"\n", .Newline, "\n", "\n"},
		{"\t", .Tab, "\t", "\t"},
		{" ", .Space, " ", " "},
		{"+", .Plus, "+", "+"},
		{"-", .Minus, "-", "-"},
		{"--!", .EnDash, "--", "--"},
		{"---", .EmDash, "---", "---"},
		{"*", .Star, "*", "*"},
		{"/", .Slash, "/", "/"},
		{"//", .FracDefiner, "//", "//"},
		{"=", .Equal, "=", "="},
		{"==", .EqEq, "==", "=="},
		{"<", .Less, "<", "<"},
		{">", .Great, ">", ">"},
		{"<=", .LessEq, "<=", "\\leq "},
		{">=", .GreatEq, ">=", "\\geq "},
		// The Zig implementation normalizes source `/=` to a text literal `!=`.
		{"/=", .NotEqual, "!=", "\\neq "},
		{"!=", .NotEqual, "!=", "\\neq "},
		{"<-", .LeftArrow, "<-", "\\leftarrow "},
		{"->", .RightArrow, "->", "\\rightarrow "},
		{"=>", .DoubleRightArrow, "=>", "\\Rightarrow "},
		{"<--", .LongLeftArrow, "<--", "\\longleftarrow "},
		{"-->", .LongRightArrow, "-->", "\\longrightarrow "},
		{"<==", .LongDoubleLeftArrow, "<==", "\\Longleftarrow "},
		{"==>", .LongDoubleRightArrow, "==>", "\\Longrightarrow "},
		{"<->", .LeftRightArrow, "<->", "\\leftrightarrow "},
		{"<=>", .DoubleLeftRightArrow, "<=>", "\\Leftrightarrow "},
		{"<-->", .LongLeftRightArrow, "<-->", "\\longleftrightarrow "},
		{"<==>", .LongDoubleLeftRightArrow, "<==>", "\\Longleftrightarrow "},
		{"|->", .MapsTo, "|->", "\\mapsto "},
		{"{", .Lbrace, "{", "{"},
		{"}", .Rbrace, "}", "}"},
		{"[", .Lsqbrace, "[", "["},
		{"]", .Rsqbrace, "]", "]"},
		{"(", .Lparen, "(", "("},
		{")", .Rparen, ")", ")"},
		{"{<", .Langle, "{<", "\\langle "},
		{">}", .Rangle, ">}", "\\rangle "},
		{"\\{", .MathLbrace, "\\{", "\\{"},
		{"\\}", .MathRbrace, "\\}", "\\}"},
		{"$", .InlineMathSwitch, "$", "$"},
		{"$$", .DisplayMathSwitch, "$$", "$$"},
		{"\\[", .DisplayMathStart, "\\[", "\\["},
		{"\\]", .DisplayMathEnd, "\\]", "\\]"},
		{"\\,", .MathSmallSpace, "\\,", "\\,"},
		{"\\;", .MathLargeSpace, "\\;", "\\;"},
		{"\\ ", .MathLargeSpace, "\\ ", "\\;"},
		{"\\", .ShortBackSlash, "\\", "\\"},
		{"\\\\", .BackSlash, "\\\\", "\\\\"},
		{"@", .At, "@", "@"},
		{"^", .Superscript, "^", "^"},
		{"_", .Subscript, "_", "_"},
		{"!", .Bang, "!", "!"},
		{"?", .Question, "?", "?"},
		{"%", .LatexComment, "%", "%"},
		{"\\%", .TextPercent, "\\%", "\\%"},
		{"#", .RawSharp, "#", "#"},
		{"\\#", .TextSharp, "\\#", "\\#"},
		{"$#", .RawDollar, "$", "$"},
		{"\\$", .TextDollar, "\\$", "\\$"},
		{":", .Colon, ":", ":"},
		{";", .Semicolon, ";", ";"},
		{".", .Period, ".", "."},
		{",", .Comma, ",", ","},
		{"-!", .SetMinus, "-!", "\\setminus "},
		{"|", .Vert, "|", "|"},
		{"||", .Norm, "||", "\\|"},
		{"&", .Ampersand, "&", "&"},
		{"~", .Tilde, "~", "~"},
		{"`", .LeftQuote, "`", "`"},
		{"'", .RightQuote, "'", "'"},
		{"\"", .DoubleQuote, "\"", "\""},
		{"...", .CenterDots, "...", "\\cdots "},
		{"oo", .InfinitySym, "oo", "\\infty "},
	}

	for test_case in cases {
		lexer := vesti.lexer_init(test_case.source)
		expect_token(
			t,
			&lexer,
			test_case.kind,
			test_case.in_text,
			test_case.in_math,
		)
		expect_same_token(t, &lexer, .Eof, "")
	}
}

@(test)
lexer_words_numbers_keywords_and_builtins :: proc(t: ^testing.T) {
	lexer := vesti.lexer_init(
		"docclass compty cpfile #eq value #12 -3 .5 -.7 12abc 12.3abc",
	)
	expect_same_token(t, &lexer, .Docclass, "docclass")
	expect_same_token(t, &lexer, .Space, " ")
	deprecated := expect_same_token(t, &lexer, .Deprecated, "compty")
	testing.expect(t, !deprecated.deprecated.valid_in_text)
	testing.expect_value(t, deprecated.deprecated.instead, "#engine_type")
	expect_same_token(t, &lexer, .Space, " ")
	deprecated = expect_same_token(t, &lexer, .Deprecated, "cpfile")
	testing.expect_value(t, deprecated.deprecated.instead, "#copy_file")
	expect_same_token(t, &lexer, .Space, " ")

	// A space before an alphanumeric argument is part of the source literal,
	// but not the builtin's span or name payload, matching Vesti's Zig lexer.
	builtin := expect_same_token(t, &lexer, .BuiltinFunction, "#eq ")
	testing.expect_value(t, builtin.builtin_name, "eq")
	expect_same_token(t, &lexer, .Text, "value")
	expect_same_token(t, &lexer, .Space, " ")
	builtin = expect_same_token(t, &lexer, .BuiltinFunction, "#12")
	testing.expect_value(t, builtin.builtin_name, "12")
	param, ok := vesti.token_is_function_param(builtin.builtin_name)
	testing.expect(t, ok)
	testing.expect_value(t, param, uint(12))
	expect_same_token(t, &lexer, .Space, " ")
	expect_same_token(t, &lexer, .Integer, "-3")
	expect_same_token(t, &lexer, .Space, " ")
	expect_same_token(t, &lexer, .Float, ".5")
	expect_same_token(t, &lexer, .Space, " ")
	// The Zig state machine splits this edge spelling into two float tokens.
	expect_same_token(t, &lexer, .Float, "-")
	expect_same_token(t, &lexer, .Float, ".7")
	expect_same_token(t, &lexer, .Space, " ")
	expect_same_token(t, &lexer, .Text, "12abc")
	expect_same_token(t, &lexer, .Space, " ")
	expect_same_token(t, &lexer, .Float, "12.3")
	expect_same_token(t, &lexer, .Text, "abc")
	expect_same_token(t, &lexer, .Eof, "")

	testing.expect(t, vesti.token_is_builtin("eq"))
	testing.expect(t, vesti.token_is_preprocess_builtin("ifdef"))
	testing.expect(t, vesti.token_is_any_builtin("at_on"))
	testing.expect(t, !vesti.token_is_any_builtin("definitely_not_a_builtin"))
	testing.expect(t, vesti.token_is_keyword_kind(.Docclass))
	testing.expect(t, !vesti.token_is_keyword_kind(.Text))
}

@(test)
lexer_comments_and_raw_latex :: proc(t: ^testing.T) {
	lexer := vesti.lexer_init("-- ignored\n--[=[hidden\ntext]=]abc")
	token := expect_same_token(t, &lexer, .Text, "abc")
	expect_location(t, token.span.start, 3, 8)
	expect_location(t, token.span.end, 3, 11)
	expect_same_token(t, &lexer, .Eof, "")

	lexer = vesti.lexer_init("%#line latex\nnext")
	token = expect_same_token(t, &lexer, .RawLatex, "line latex\n")
	expect_location(t, token.span.start, 1, 1)
	expect_location(t, token.span.end, 2, 1)
	expect_same_token(t, &lexer, .Text, "next")

	lexer = vesti.lexer_init("%-block-%tail")
	token = expect_same_token(t, &lexer, .RawLatex, "block")
	expect_location(t, token.span.start, 1, 1)
	expect_location(t, token.span.end, 1, 8)
	token = expect_same_token(t, &lexer, .Text, "tail")
	expect_location(t, token.span.start, 1, 10)

	lexer = vesti.lexer_init("%-unterminated")
	expect_same_token(t, &lexer, .Illegal, "unterminated")
}

@(test)
lexer_lua_markers_and_identifier_modes :: proc(t: ^testing.T) {
	lexer := vesti.lexer_init("#::code::#")
	expect_same_token(t, &lexer, .LuaCodeStart, "#::")
	expect_same_token(t, &lexer, .Text, "code")
	expect_same_token(t, &lexer, .LuaCodeEnd, "::#")

	lexer = vesti.lexer_init("\\foo@bar @name")
	expect_same_token(t, &lexer, .LatexFunction, "\\foo")
	expect_same_token(t, &lexer, .At, "@")
	expect_same_token(t, &lexer, .Text, "bar")
	expect_same_token(t, &lexer, .Space, " ")
	expect_same_token(t, &lexer, .At, "@")
	expect_same_token(t, &lexer, .Text, "name")

	lexer = vesti.lexer_init("\\foo@bar @name")
	lexer.make_at_letter = true
	expect_same_token(t, &lexer, .MakeAtLetterFnt, "\\foo@bar")
	expect_same_token(t, &lexer, .Space, " ")
	expect_same_token(t, &lexer, .Text, "@name")

	lexer = vesti.lexer_init("\\foo_bar: alpha_beta")
	lexer.is_latex3_on = true
	expect_same_token(t, &lexer, .Latex3Fnt, "\\foo_bar:")
	expect_same_token(t, &lexer, .Space, " ")
	expect_same_token(t, &lexer, .Text, "alpha_beta")
}

@(test)
lexer_utf8_lookahead_and_display_spans :: proc(t: ^testing.T) {
	lexer := vesti.lexer_init("A界+é\nq\u0301�")
	token := expect_same_token(t, &lexer, .Text, "A界")
	expect_location(t, token.span.start, 1, 1)
	expect_location(t, token.span.end, 1, 4)
	token = expect_same_token(t, &lexer, .Plus, "+")
	expect_location(t, token.span.start, 1, 4)
	expect_location(t, token.span.end, 1, 5)
	token = expect_same_token(t, &lexer, .Text, "é")
	expect_location(t, token.span.start, 1, 5)
	expect_location(t, token.span.end, 1, 6)
	expect_same_token(t, &lexer, .Newline, "\n")
	token = expect_same_token(t, &lexer, .Text, "q")
	expect_location(t, token.span.start, 2, 1)
	expect_location(t, token.span.end, 2, 2)
	token = expect_same_token(t, &lexer, .OtherChar, "\u0301")
	expect_location(t, token.span.start, 2, 2)
	expect_location(t, token.span.end, 2, 3)
	token = expect_same_token(t, &lexer, .OtherChar, "�")
	expect_location(t, token.span.start, 2, 3)
	expect_location(t, token.span.end, 2, 4)
}

@(test)
cow_str_ownership_transitions :: proc(t: ^testing.T) {
	borrowed_empty := vesti.cow_str_borrowed("")
	testing.expect_value(t, borrowed_empty.state, vesti.Cow_Str_State.Borrowed)

	value := vesti.cow_str_empty()
	err := vesti.cow_str_append(&value, "hello")
	testing.expect(t, err == nil)
	testing.expect_value(t, value.state, vesti.Cow_Str_State.Borrowed)
	err = vesti.cow_str_append(&value, " world")
	testing.expect(t, err == nil)
	testing.expect_value(t, value.state, vesti.Cow_Str_State.Owned)
	testing.expect_value(t, vesti.cow_str_string(value), "hello world")
	vesti.cow_str_deinit(&value)
	testing.expect_value(t, value.state, vesti.Cow_Str_State.Empty)

	owned, alloc_err := vesti.cow_str_owned_copy("copy")
	testing.expect(t, alloc_err == nil)
	defer vesti.cow_str_deinit(&owned)
	testing.expect_value(t, vesti.cow_str_string(owned), "copy")
}

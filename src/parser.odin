package main

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

PARSER_MAX_BEGENV :: 64

Parser_Options :: struct {
	allocator:               mem.Allocator,
	diagnostic:              ^Diagnostic,
	allow_lua_code:          bool,
	allow_global_definition: bool,
	is_main:                 bool,
	allow_engine_change:     bool,
	engine:                  ^Latex_Engine,
	current_engine:          Latex_Engine,
	file_directory:          string,
	config_directory:        string,
	dummy_directory:         string,
	perform_file_operations: bool,
}

parser_options_default :: proc(allocator := context.allocator) -> Parser_Options {
	return Parser_Options{
		allocator = allocator,
		allow_engine_change = true,
		current_engine = .pdflatex,
		file_directory = ".",
		dummy_directory = VESTI_DUMMY_DIR,
		perform_file_operations = true,
	}
}

Parser_Document_State :: struct {
	xparse_defun:   bool,
	doc_start:      bool,
	prevent_end_doc: bool,
	parsing_define: bool,
	math_mode:      bool,
}

Parser :: struct {
	tokens:         []Token,
	token_index:    int,
	parse_finished: bool,
	options:        Parser_Options,
	document:       Parser_Document_State,
	enum_depth:     int,
	endenv_stack:   [PARSER_MAX_BEGENV]string,
	endenv_count:   int,
	current_engine: Latex_Engine,
	engine_changed: bool,
}

parser_init :: proc(tokens: []Token, options: Parser_Options) -> Parser {
	resolved := options
	if resolved.allocator.procedure == nil {
		resolved.allocator = context.allocator
	}
	if len(resolved.file_directory) == 0 {
		resolved.file_directory = "."
	}
	if len(resolved.dummy_directory) == 0 {
		resolved.dummy_directory = VESTI_DUMMY_DIR
	}
	current_engine := resolved.current_engine
	if resolved.engine != nil {
		current_engine = resolved.engine^
	}
	return Parser{
		tokens = tokens,
		options = resolved,
		document = {xparse_defun = true},
		current_engine = current_engine,
	}
}

parser_current :: proc(parser: ^Parser) -> Token {
	if len(parser.tokens) == 0 {
		return token_eof(span_init())
	}
	index := parser.token_index
	if index < 0 {
		index = 0
	}
	if index >= len(parser.tokens) {
		last := parser.tokens[len(parser.tokens)-1]
		return token_eof(last.span)
	}
	return parser.tokens[index]
}

parser_peek :: proc(parser: ^Parser) -> Token {
	if len(parser.tokens) == 0 {
		return token_eof(span_init())
	}
	index := parser.token_index + 1
	if index >= len(parser.tokens) {
		last := parser.tokens[len(parser.tokens)-1]
		return token_eof(last.span)
	}
	return parser.tokens[index]
}

parser_current_kind :: proc(parser: ^Parser) -> Token_Kind { return parser_current(parser).kind }
parser_peek_kind    :: proc(parser: ^Parser) -> Token_Kind { return parser_peek(parser).kind }

parser_next :: proc(parser: ^Parser) {
	if parser.token_index + 1 < len(parser.tokens) {
		parser.token_index += 1
	} else {
		parser.parse_finished = true
	}
}

parser_expect :: proc(parser: ^Parser, kinds: ..Token_Kind) -> bool {
	current := parser_current_kind(parser)
	for kind in kinds {
		if current == kind {
			return true
		}
	}
	return false
}

parser_expect_peek :: proc(parser: ^Parser, kinds: ..Token_Kind) -> bool {
	peek := parser_peek_kind(parser)
	for kind in kinds {
		if peek == kind {
			return true
		}
	}
	return false
}

parser_error :: proc(parser: ^Parser, message: string, span: Span, note := "") -> bool {
	if parser.options.diagnostic != nil {
		_ = diagnostic_set(
			parser.options.diagnostic,
			.Parse,
			message,
			span,
			true,
			note,
		)
	}
	return false
}

parser_error_current :: proc(parser: ^Parser, message: string, note := "") -> bool {
	return parser_error(parser, message, parser_current(parser).span, note)
}

parser_expect_token :: proc(parser: ^Parser, kind: Token_Kind, eat: bool) -> (Token, bool) {
	current := parser_current(parser)
	if current.kind != kind {
		message := fmt.aprintf("expected token %v, obtained %v", kind, current.kind)
		defer delete(message)
		return {}, parser_error(parser, message, current.span)
	}
	if eat {
		parser_next(parser)
	}
	return current, true
}

parser_eat_whitespace :: proc(parser: ^Parser, include_newline: bool) {
	for parser_expect(parser, .Space, .Tab) ||
	    (include_newline && parser_expect(parser, .Newline)) {
		parser_next(parser)
	}
}

parser_is_premiere :: proc(parser: ^Parser) -> bool {
	return !parser.document.doc_start && !parser.document.parsing_define
}

parser_owned_cow :: proc(parser: ^Parser, value: string) -> (Cow_Str, bool) {
	result, err := cow_str_owned_copy(value, parser.options.allocator)
	if err != nil {
		return {}, parser_error_current(parser, "out of memory while parsing text")
	}
	return result, true
}

parser_append_cow :: proc(parser: ^Parser, value: ^Cow_Str, suffix: string) -> bool {
	if cow_str_append(value, suffix, parser.options.allocator) != nil {
		return parser_error_current(parser, "out of memory while parsing text")
	}
	return true
}

parser_byte_buffer :: proc(value: string) -> Byte_Buffer {
	buffer := make(Byte_Buffer, 0, len(value))
	append(&buffer, value)
	return buffer
}

parser_token_can_be_name :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Text, .Docclass, .ImportPkg, .ImportVesti, .ImportModule, .StartDoc,
	     .Useenv, .Begenv, .Endenv, .DefineFunction, .DefineEnv:
		return true
	}
	return false
}

parser_math_environment :: proc(name: string) -> bool {
	switch name {
	case "equation", "align", "array", "eqnarray", "gather", "multline":
		return true
	}
	return false
}

parser_parse :: proc(tokens: []Token, options: Parser_Options) -> (output: Stmt_List, ok: bool) {
	parser := parser_init(tokens, options)
	context.allocator = parser.options.allocator
	output = make(Stmt_List, 0, 100)
	defer if !ok {
		stmt_list_deinit(&output, parser.options.allocator)
	}

	if len(tokens) == 0 {
		return output, true
	}

	for !parser.parse_finished {
		statement, statement_ok := parser_parse_statement(&parser)
		if !statement_ok {
			return output, false
		}
		append(&output, statement)
		parser_next(&parser)
	}
	if parser.document.doc_start && !parser.document.prevent_end_doc {
		append(&output, Document_End_Stmt{})
	}
	return output, true
}

parser_parse_statement :: proc(parser: ^Parser) -> (Stmt, bool) {
	token := parser_current(parser)
	#partial switch token.kind {
	case .BuiltinFunction:
		return parser_parse_builtin(parser, token.builtin_name)
	case .Docclass:
		if parser_is_premiere(parser) {
			return parser_parse_docclass(parser)
		}
	case .ImportPkg:
		if parser_is_premiere(parser) {
			return parser_parse_single_package(parser)
		}
	case .StartDoc:
		if parser_is_premiere(parser) {
			parser.document.doc_start = true
			return Document_Start_Stmt{}, true
		}
	case .InlineMathSwitch, .DisplayMathSwitch:
		if !parser.document.math_mode {
			parser.document.math_mode = true
			return parser_parse_math(parser)
		}
		return {}, parser_error(parser, "math block is not properly closed", token.span)
	case .DisplayMathStart:
		parser.document.math_mode = true
		return parser_parse_math(parser)
	case .DisplayMathEnd:
		return {}, parser_error(parser, "math block is not properly closed", token.span)
	case .Question:
		if parser.document.math_mode {
			return parser_parse_open_delimiter(parser)
		}
	case .Period, .Lparen, .Lsqbrace, .Langle, .MathLbrace, .Vert, .Norm,
	     .Rparen, .Rsqbrace, .Rangle, .MathRbrace:
		if parser.document.math_mode {
			return parser_parse_closed_delimiter(parser)
		}
	case .Lbrace:
		return parser_parse_brace(parser, true)
	case .Useenv:
		return parser_parse_environment(parser, true)
	case .Begenv:
		return parser_parse_environment(parser, false)
	case .Endenv:
		return parser_parse_end_environment(parser)
	case .DefineFunction:
		return parser_parse_definition(parser, false, parser.document.xparse_defun)
	case .DefineEnv:
		return parser_parse_definition(parser, true, true)
	case .DoubleQuote:
		if parser.document.math_mode {
			return parser_parse_text_in_math(parser, false)
		}
	case .RawSharp:
		if parser.document.math_mode {
			return parser_parse_text_in_math(parser, true)
		}
	case .ImportVesti:
		return parser_parse_import_vesti(parser)
	case .ImportModule:
		return parser_parse_import_module(parser)
	case .LuaCodeStart:
		if parser.options.allow_lua_code {
			return parser_parse_lua_code(parser)
		}
		return {}, parser_error(parser, "Lua code is not allowed in this parser context", token.span)
	case .LuaCodeEnd:
		return {}, parser_error(parser, "unexpected Lua code terminator", token.span)
	case .Illegal:
		return {}, parser_error(parser, "invalid token found", token.span)
	case .Deprecated:
		if !token.deprecated.valid_in_text {
			return {}, parser_error(parser, "deprecated syntax", token.span, token.deprecated.instead)
		}
	}
	return parser_parse_literal(parser), true
}

parser_parse_literal :: proc(parser: ^Parser) -> Stmt {
	token := parser_current(parser)
	if parser.document.math_mode {
		return Math_Lit_Stmt{text = token.literal.in_math}
	}
	return Text_Lit_Stmt{text = cow_str_borrowed(token.literal.in_text)}
}

parser_take_name :: proc(parser: ^Parser, opening_span: Span) -> (output: Cow_Str, ok: bool) {
	if parser_expect(parser, .Eof) {
		return {}, parser_error(parser, "unexpected end of input while parsing a name", opening_span)
	}

	if !parser_expect(parser, .Text, .Minus, .Integer) {
		return cow_str_borrowed(parser_current(parser).literal.in_text), true
	}
	output, ok = parser_owned_cow(parser, parser_current(parser).literal.in_text)
	if !ok {
		return
	}
	defer if !ok {
		cow_str_deinit(&output, parser.options.allocator)
	}
	parser_next(parser)
	for parser_expect(parser, .Text, .Minus, .Integer) {
		if !parser_append_cow(parser, &output, parser_current(parser).literal.in_text) {
			return output, false
		}
		parser_next(parser)
	}
	return output, true
}

parser_parse_options :: proc(parser: ^Parser) -> (output: Cow_Str_List, ok: bool) {
	open_span := parser_current(parser).span
	_, ok = parser_expect_token(parser, .Lparen, true)
	if !ok {
		return
	}
	output = make(Cow_Str_List, 0, 10)
	defer if !ok {
		cow_str_list_deinit(&output, parser.options.allocator)
	}
	temporary := cow_str_empty()
	defer if !ok {
		cow_str_deinit(&temporary, parser.options.allocator)
	}

	for parser_current_kind(parser) != .Rparen {
		if parser_current_kind(parser) == .Eof {
			return output, parser_error(parser, "unexpected end of input in option list", open_span)
		}
		#partial switch parser_current_kind(parser) {
		case .Comma:
			if temporary.state != .Empty {
				append(&output, temporary)
				temporary = cow_str_empty()
			}
		case .Space, .Tab, .Newline:
		case:
			if !parser_append_cow(parser, &temporary, parser_current(parser).literal.in_text) {
				return output, false
			}
		}
		parser_next(parser)
	}
	if temporary.state != .Empty {
		append(&output, temporary)
		temporary = cow_str_empty()
	}
	return output, true
}

parser_parse_docclass :: proc(parser: ^Parser) -> (result: Stmt, ok: bool) {
	span := parser_current(parser).span
	_, ok = parser_expect_token(parser, .Docclass, true)
	if !ok { return }
	parser_eat_whitespace(parser, false)
	name, name_ok := parser_take_name(parser, span)
	if !name_ok { return {}, false }
	defer if !ok { cow_str_deinit(&name, parser.options.allocator) }
	parser_eat_whitespace(parser, false)

	options: Maybe(Cow_Str_List)
	if !parser_expect(parser, .Eof, .Newline) {
		parsed, options_ok := parser_parse_options(parser)
		if !options_ok { return {}, false }
		options = parsed
	}
	return Document_Class_Stmt{name = name, options = options}, true
}

parser_parse_single_package :: proc(parser: ^Parser) -> (result: Stmt, ok: bool) {
	span := parser_current(parser).span
	_, ok = parser_expect_token(parser, .ImportPkg, true)
	if !ok { return }
	parser_eat_whitespace(parser, false)
	if parser_expect(parser, .Lbrace) {
		return parser_parse_multiple_packages(parser)
	}

	name, name_ok := parser_take_name(parser, span)
	if !name_ok { return {}, false }
	defer if !ok { cow_str_deinit(&name, parser.options.allocator) }
	parser_eat_whitespace(parser, false)
	options: Maybe(Cow_Str_List)
	if parser_expect(parser, .Lparen) {
		parsed, options_ok := parser_parse_options(parser)
		if !options_ok { return {}, false }
		options = parsed
	}
	return Import_Single_Pkg_Stmt{pkg = {name = name, options = options}}, true
}

parser_parse_multiple_packages :: proc(parser: ^Parser) -> (result: Stmt, ok: bool) {
	open_span := parser_current(parser).span
	_, ok = parser_expect_token(parser, .Lbrace, true)
	if !ok { return }
	packages := make(Use_Package_List, 0, 10)
	defer if !ok { use_package_list_deinit(&packages, parser.options.allocator) }

	for {
		parser_eat_whitespace(parser, true)
		if parser_expect(parser, .Rbrace) {
			break
		}
		if parser_expect(parser, .Eof) {
			return {}, parser_error(parser, "unexpected end of input in package list", open_span)
		}
		name, name_ok := parser_take_name(parser, open_span)
		if !name_ok { return {}, false }
		parser_eat_whitespace(parser, false)
		options: Maybe(Cow_Str_List)
		if parser_expect(parser, .Lparen) {
			parsed, options_ok := parser_parse_options(parser)
			if !options_ok {
				cow_str_deinit(&name, parser.options.allocator)
				return {}, false
			}
			options = parsed
			parser_next(parser)
		}
		parser_eat_whitespace(parser, true)
		if !parser_expect(parser, .Comma, .Rbrace) {
			pkg := Use_Package{name = name, options = options}
			use_package_deinit(&pkg, parser.options.allocator)
			return {}, parser_error_current(parser, "expected comma or closing brace in package list")
		}
		append(&packages, Use_Package{name = name, options = options})
		if parser_expect(parser, .Rbrace) {
			break
		}
		parser_next(parser)
	}
	return Import_Multiple_Pkgs_Stmt{packages = packages}, true
}

parser_math_close :: proc(open: Token_Kind) -> Token_Kind {
	#partial switch open {
	case .InlineMathSwitch:  return .InlineMathSwitch
	case .DisplayMathSwitch: return .DisplayMathSwitch
	case .DisplayMathStart:  return .DisplayMathEnd
	}
	return .Eof
}

parser_math_state :: proc(open: Token_Kind) -> Math_State {
	return .Inline if open == .InlineMathSwitch else .Display
}

parser_parse_math :: proc(parser: ^Parser) -> (result: Stmt, ok: bool) {
	open := parser_current_kind(parser)
	close := parser_math_close(open)
	open_span := parser_current(parser).span
	parser_next(parser)
	inner := make(Stmt_List, 0, 20)
	defer if !ok { stmt_list_deinit(&inner, parser.options.allocator) }
	for parser_current_kind(parser) != close {
		if parser_current_kind(parser) == .Eof {
			return {}, parser_error(parser, "unexpected end of input in math block", open_span)
		}
		statement, statement_ok := parser_parse_statement(parser)
		if !statement_ok { return {}, false }
		append(&inner, statement)
		parser_next(parser)
	}
	parser.document.math_mode = false
	return Math_Ctx_Stmt{state = parser_math_state(open), inner = inner}, true
}

parser_parse_text_in_math :: proc(parser: ^Parser, front_space: bool) -> (result: Stmt, ok: bool) {
	open_span := parser_current(parser).span
	if front_space {
		_, ok = parser_expect_token(parser, .RawSharp, true)
		if !ok { return }
	}
	_, ok = parser_expect_token(parser, .DoubleQuote, true)
	if !ok { return }
	inner := make(Stmt_List, 0, 20)
	defer if !ok { stmt_list_deinit(&inner, parser.options.allocator) }
	parser.document.math_mode = false
	for !parser_expect(parser, .DoubleQuote) {
		if parser_expect(parser, .Eof) {
			return {}, parser_error(parser, "unexpected end of input in math text", open_span)
		}
		statement, statement_ok := parser_parse_statement(parser)
		if !statement_ok { return {}, false }
		append(&inner, statement)
		parser_next(parser)
	}
	parser.document.math_mode = true
	back_space := false
	if parser_expect_peek(parser, .RawSharp) {
		parser_next(parser)
		back_space = true
	}
	return Plain_Text_In_Math_Stmt{
		add_front_space = front_space,
		add_back_space = back_space,
		inner = inner,
	}, true
}

parser_parse_open_delimiter :: proc(parser: ^Parser) -> (Stmt, bool) {
	_, ok := parser_expect_token(parser, .Question, true)
	if !ok { return {}, false }
	if parser_expect(
		parser,
		.Lparen, .Lsqbrace, .Langle, .MathLbrace, .Vert, .Norm,
		.Rparen, .Rsqbrace, .Rangle, .MathRbrace, .Period,
	) {
		return Math_Delimiter_Stmt{
			delimiter = parser_current(parser).literal.in_math,
			kind = .Left_Big,
		}, true
	}
	return Math_Lit_Stmt{text = "?"}, true
}

parser_parse_closed_delimiter :: proc(parser: ^Parser) -> (Stmt, bool) {
	delimiter := parser_current(parser).literal.in_math
	kind := Delimiter_Kind.None
	if parser_expect_peek(parser, .Question) {
		parser_next(parser)
		kind = .Right_Big
	}
	return Math_Delimiter_Stmt{delimiter = delimiter, kind = kind}, true
}

parser_parse_brace :: proc(parser: ^Parser, fraction_enabled: bool) -> (result: Stmt, ok: bool) {
	open_span := parser_current(parser).span
	_, ok = parser_expect_token(parser, .Lbrace, true)
	if !ok { return }
	numerator := make(Stmt_List, 0, 10)
	denominator := make(Stmt_List, 0, 10)
	defer if !ok {
		stmt_list_deinit(&numerator, parser.options.allocator)
		stmt_list_deinit(&denominator, parser.options.allocator)
	}
	is_fraction := false
	for !parser_expect(parser, .Rbrace) {
		if parser_expect(parser, .Eof) {
			return {}, parser_error(parser, "unexpected end of input in brace", open_span)
		}
		if fraction_enabled && parser.document.math_mode && parser_expect(parser, .FracDefiner) {
			is_fraction = true
			parser_next(parser)
			continue
		}
		statement, statement_ok := parser_parse_statement(parser)
		if !statement_ok { return {}, false }
		if fraction_enabled && is_fraction {
			append(&denominator, statement)
		} else {
			append(&numerator, statement)
		}
		parser_next(parser)
	}
	if fraction_enabled && is_fraction {
		return Fraction_Stmt{numerator = numerator, denominator = denominator}, true
	}
	delete(denominator)
	return Braced_Stmt{inner = numerator}, true
}

parser_take_braced_inner :: proc(statement: ^Stmt) -> (Stmt_List, bool) {
	#partial switch &value in statement^ {
	case Braced_Stmt:
		inner := value.inner
		value.inner = nil
		stmt_deinit(statement)
		return inner, true
	case:
		return nil, false
	}
}

parser_parse_parenthesized_text :: proc(parser: ^Parser, span: Span) -> (Byte_Buffer, bool) {
	_, ok := parser_expect_token(parser, .Lparen, true)
	if !ok { return nil, false }
	buffer := make(Byte_Buffer, 0, 30)
	nested := 1
	for {
		#partial switch parser_current_kind(parser) {
		case .Lparen:
			nested += 1
		case .Rparen:
			nested -= 1
			if nested == 0 {
				return buffer, true
			}
		case .Eof:
			delete(buffer)
			return nil, parser_error(parser, "unexpected end of input in parentheses", span)
		case:
		}
		append(&buffer, parser_current(parser).literal.in_text)
		parser_next(parser)
	}
}

parser_parse_import_module :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	_, ok := parser_expect_token(parser, .ImportModule, true)
	if !ok { return {}, false }
	parser_eat_whitespace(parser, false)
	module_bytes, path_ok := parser_parse_parenthesized_text(parser, span)
	if !path_ok { return {}, false }
	defer delete(module_bytes)
	module_name := strings.trim_left(strings.trim(string(module_bytes[:]), " \t"), "/\\")
	if len(module_name) == 0 {
		return {}, parser_error(parser, "module name may not be empty", span)
	}
	if parser.options.perform_file_operations &&
	   !download_module(module_name, span, true, parser.options.diagnostic, parser.options.allocator) {
		return {}, false
	}
	return Nop_Stmt{}, true
}

parser_mangle_vesti_name :: proc(parser: ^Parser, filename: string) -> Byte_Buffer {
	value := hash.fnv64a(transmute([]byte)filename)
	formatted := fmt.aprintf("@vesti__%x.tex", value)
	defer delete(formatted)
	return parser_byte_buffer(formatted)
}

parser_parse_import_vesti :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	_, ok := parser_expect_token(parser, .ImportVesti, true)
	if !ok { return {}, false }
	parser_eat_whitespace(parser, false)
	path_bytes, path_ok := parser_parse_parenthesized_text(parser, span)
	if !path_ok { return {}, false }
	defer delete(path_bytes)
	raw_path := strings.trim(string(path_bytes[:]), " \t")
	joined, join_err := filepath.join({parser.options.file_directory, raw_path}, parser.options.allocator)
	if join_err != nil {
		return {}, parser_error(parser, "cannot construct imported Vesti path", span)
	}
	defer delete(joined, parser.options.allocator)
	absolute, absolute_err := filepath.abs(joined, parser.options.allocator)
	if absolute_err != nil {
		return {}, parser_error(parser, "cannot obtain absolute path for imported Vesti file", span)
	}
	defer delete(absolute, parser.options.allocator)
	if parser.options.perform_file_operations && !os.is_file(absolute) {
		return {}, parser_error(parser, "imported Vesti file does not exist", span, raw_path)
	}
	return Import_Vesti_Stmt{name = parser_mangle_vesti_name(parser, absolute)}, true
}

parser_push_end_environment :: proc(parser: ^Parser, name: string, span: Span) -> bool {
	if parser.endenv_count >= PARSER_MAX_BEGENV {
		return parser_error(parser, "too many nested begenv statements", span)
	}
	parser.endenv_stack[parser.endenv_count] = name
	parser.endenv_count += 1
	return true
}

parser_pop_end_environment :: proc(parser: ^Parser, span: Span) -> (string, bool) {
	if parser.endenv_count == 0 {
		return "", parser_error(parser, "endenv has no matching begenv", span)
	}
	parser.endenv_count -= 1
	return parser.endenv_stack[parser.endenv_count], true
}

parser_parse_argument_core :: proc(
	parser: ^Parser,
	open, close: Token_Kind,
	need: Arg_Need,
) -> (Arg, bool) {
	span := parser_current(parser).span
	_, ok := parser_expect_token(parser, open, true)
	if !ok { return {}, false }
	context_list := make(Stmt_List, 0, 20)
	defer if !ok { stmt_list_deinit(&context_list, parser.options.allocator) }
	nested := 1
	for {
		kind := parser_current_kind(parser)
		if kind == open {
			nested += 1
		} else if kind == close {
			nested -= 1
			if nested == 0 {
				return Arg{needed = need, ctx = context_list}, true
			}
		} else if kind == .Eof {
			return {}, parser_error(parser, "unexpected end of input in argument", span)
		}
		statement, statement_ok := parser_parse_statement(parser)
		if !statement_ok { return {}, false }
		append(&context_list, statement)
		parser_next(parser)
	}
}

parser_parse_function_arguments :: proc(parser: ^Parser, phantom: bool) -> (args: Arg_List, ok: bool) {
	args = make(Arg_List, 0, 10)
	defer if !ok { arg_list_deinit(&args, parser.options.allocator) }
	first_token := phantom
	if !parser_expect(parser, .Lparen, .Lsqbrace, .Star) {
		return args, true
	}
	for {
		#partial switch parser_current_kind(parser) {
		case .Lparen:
			argument, argument_ok := parser_parse_argument_core(parser, .Lparen, .Rparen, .Main_Arg)
			if !argument_ok { return args, false }
			append(&args, argument)
		case .Lsqbrace:
			argument, argument_ok := parser_parse_argument_core(parser, .Lsqbrace, .Rsqbrace, .Optional)
			if !argument_ok { return args, false }
			append(&args, argument)
		case .Star:
			if !first_token {
				append(&args, Arg{needed = .Star_Arg, ctx = make(Stmt_List)})
			}
		case:
			return args, true
		}
		first_token = false
		if !parser_expect_peek(parser, .Lparen, .Lsqbrace, .Star) {
			break
		}
		parser_next(parser)
	}
	return args, true
}

parser_parse_environment :: proc(parser: ^Parser, real: bool) -> (result: Stmt, ok: bool) {
	span := parser_current(parser).span
	expected := Token_Kind.Begenv
	if real { expected = .Useenv }
	_, ok = parser_expect_token(parser, expected, true)
	if !ok { return }
	push_name := true
	add_newline := false
	if !real && parser_expect(parser, .Bang) {
		parser_next(parser)
		push_name = false
	}
	if !real && parser_expect(parser, .Star) {
		parser_next(parser)
		add_newline = true
	}
	parser_eat_whitespace(parser, false)
	if !parser_token_can_be_name(parser_current_kind(parser)) {
		return {}, parser_error(parser, "environment name expected", span)
	}
	name, name_ok := parser_owned_cow(parser, parser_current(parser).literal.in_text)
	if !name_ok { return {}, false }
	defer if !ok { cow_str_deinit(&name, parser.options.allocator) }
	if cow_str_string(name) == "picture" {
		return {}, parser_error(parser, "picture environment is disabled; use #picture", span)
	}

	math_environment := parser_math_environment(cow_str_string(name))
	if math_environment {
		parser.document.math_mode = true
	}

	if real {
		parser_next(parser)
		for parser_expect(parser, .Star) {
			if !parser_append_cow(parser, &name, "*") { return {}, false }
			parser_next(parser)
		}
		parser_eat_whitespace(parser, false)
	} else {
		if parser_expect_peek(parser, .Star) {
			for parser_expect_peek(parser, .Star) {
				parser_next(parser)
				if !parser_append_cow(parser, &name, "*") { return {}, false }
			}
			for parser_expect_peek(parser, .Space, .Tab) { parser_next(parser) }
		}
		if parser_expect_peek(parser, .Space, .Tab) {
			for parser_expect_peek(parser, .Space, .Tab) { parser_next(parser) }
			if parser_expect_peek(parser, .Lparen, .Lsqbrace) { parser_next(parser) }
		} else if parser_expect_peek(parser, .Lparen, .Lsqbrace) {
			parser_next(parser)
		}
	}

	if !real && push_name && !parser_push_end_environment(parser, cow_str_string(name), span) {
		return {}, false
	}
	args, args_ok := parser_parse_function_arguments(parser, !real)
	if !args_ok { return {}, false }
	defer if !ok { arg_list_deinit(&args, parser.options.allocator) }

	if !real {
		if math_environment { parser.document.math_mode = false }
		return Begin_Phantom_Environ_Stmt{name = name, args = args, add_newline = add_newline}, true
	}
	if len(args) > 0 {
		if !parser_expect(parser, .Rparen, .Rsqbrace, .Star) {
			return {}, parser_error_current(parser, "environment argument is not properly closed")
		}
		parser_next(parser)
	}
	parser_eat_whitespace(parser, true)
	if !parser_expect(parser, .Lbrace) {
		return {}, parser_error_current(parser, "environment body must begin with a brace")
	}
	body_statement, body_ok := parser_parse_brace(parser, false)
	if !body_ok { return {}, false }
	body, unwrap_ok := parser_take_braced_inner(&body_statement)
	if !unwrap_ok {
		stmt_deinit(&body_statement, parser.options.allocator)
		return {}, parser_error_current(parser, "internal parser error while unwrapping environment")
	}
	if math_environment { parser.document.math_mode = false }
	return Environment_Stmt{name = name, args = args, inner = body}, true
}

parser_parse_end_environment :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	if parser_expect_peek(parser, .Bang) {
		parser_next(parser)
		parser_next(parser)
		parser_eat_whitespace(parser, false)
		if !parser_token_can_be_name(parser_current_kind(parser)) {
			return {}, parser_error(parser, "environment name expected after endenv!", span)
		}
		name, ok := parser_owned_cow(parser, parser_current(parser).literal.in_text)
		if !ok { return {}, false }
		return End_Phantom_Environ_Stmt{name = name}, true
	}
	name, ok := parser_pop_end_environment(parser, span)
	if !ok { return {}, false }
	return End_Phantom_Environ_Stmt{name = cow_str_borrowed(name)}, true
}

parser_definition_parameters :: proc(parser: ^Parser, tokens: []Token, span: Span) -> (Cow_Str, bool) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for token in tokens {
		if token.kind == .BuiltinFunction {
			parameter, parameter_ok := token_is_function_param(token.builtin_name)
			if !parameter_ok {
				return {}, parser_error(parser, "builtin is not a valid function parameter", token.span)
			}
			if parameter % 10 == 0 {
				return {}, parser_error(parser, "function parameter number must end in 1 through 9", token.span)
			}
			nesting := parameter / 10
			if nesting >= uint(size_of(uint)*8) {
				return {}, parser_error(parser, "function parameter nesting overflows", token.span)
			}
			sharp_count := uint(1) << nesting
			for _ in 0..<int(sharp_count) { _ = strings.write_byte(&builder, '#') }
			_ = strings.write_byte(&builder, byte('0' + rune(parameter % 10)))
		} else {
			_ = strings.write_string(&builder, token.literal.in_text)
		}
	}
	result, result_ok := parser_owned_cow(parser, strings.to_string(builder))
	if !result_ok {
		return {}, parser_error(parser, "cannot allocate definition parameters", span)
	}
	return result, true
}

parser_parse_definition :: proc(parser: ^Parser, environment, xparse: bool) -> (result: Stmt, ok: bool) {
	span := parser_current(parser).span
	expected := Token_Kind.DefineFunction
	if environment { expected = .DefineEnv }
	_, ok = parser_expect_token(parser, expected, true)
	if !ok { return }
	parser_eat_whitespace(parser, false)

	function_kind := Defun_Kind{}
	environment_kind := Defenv_Kind{}
	if parser_expect(parser, .Lsqbrace) {
		kind_span := parser_current(parser).span
		parser_next(parser)
		kind_builder := strings.builder_make()
		defer strings.builder_destroy(&kind_builder)
		for !parser_expect(parser, .Rsqbrace, .Eof) {
			_ = strings.write_string(&kind_builder, parser_current(parser).literal.in_text)
			parser_next(parser)
		}
		if parser_expect(parser, .Eof) {
			return {}, parser_error(parser, "unexpected end of input in definition modifiers", kind_span)
		}
		kind_text := strings.to_string(kind_builder)
		kind_ok := defenv_kind_parse(&environment_kind, kind_text) if environment else
		           defun_kind_parse(&function_kind, kind_text, xparse)
		if !kind_ok {
			return {}, parser_error(parser, "invalid definition modifier combination", kind_span, kind_text)
		}
		parser_next(parser)
	} else if !environment && xparse {
		function_kind.xparse = true
	}
	parser_eat_whitespace(parser, false)
	if !environment { parser.document.xparse_defun = true }
	if !parser_token_can_be_name(parser_current_kind(parser)) {
		return {}, parser_error(parser, "definition name expected", span)
	}
	name, name_ok := parser_owned_cow(parser, parser_current(parser).literal.in_text)
	if !name_ok { return {}, false }
	defer if !ok { cow_str_deinit(&name, parser.options.allocator) }
	parser_next(parser)
	parser_eat_whitespace(parser, false)

	parameters: Maybe(Cow_Str)
	if parser_expect(parser, .Lparen) {
		parameter_span := parser_current(parser).span
		parser_next(parser)
		parameter_tokens := make([dynamic]Token, 0, 20)
		defer delete(parameter_tokens)
		nested := 1
		for {
			kind := parser_current_kind(parser)
			if kind == .Lparen {
				nested += 1
			} else if kind == .Rparen {
				nested -= 1
				if nested == 0 { break }
			} else if kind == .Eof {
				return {}, parser_error(parser, "unexpected end of input in definition parameters", parameter_span)
			}
			append(&parameter_tokens, parser_current(parser))
			parser_next(parser)
		}
		parameter, parameter_ok := parser_definition_parameters(parser, parameter_tokens[:], parameter_span)
		if !parameter_ok { return {}, false }
		parameters = parameter
		parser_next(parser)
	}
	defer if !ok {
		if parameter, has_parameter := parameters.?; has_parameter {
			cow_str_deinit(&parameter, parser.options.allocator)
		}
	}
	parser_eat_whitespace(parser, true)
	if !parser_expect(parser, .Lbrace) {
		return {}, parser_error_current(parser, "definition body must begin with a brace")
	}

	begin_statement, begin_ok := parser_parse_brace(parser, false)
	if !begin_ok { return {}, false }
	begin_body, unwrap_ok := parser_take_braced_inner(&begin_statement)
	if !unwrap_ok { return {}, false }
	if !environment {
		return Define_Function_Stmt{
			name = name,
			param_str = parameters,
			kind = function_kind,
			inner = begin_body,
		}, true
	}
	parser_next(parser)
	parser_eat_whitespace(parser, true)
	if !parser_expect(parser, .Lbrace) {
		stmt_list_deinit(&begin_body, parser.options.allocator)
		return {}, parser_error_current(parser, "environment definition requires an end body")
	}
	end_statement, end_ok := parser_parse_brace(parser, false)
	if !end_ok {
		stmt_list_deinit(&begin_body, parser.options.allocator)
		return {}, false
	}
	end_body, end_unwrap_ok := parser_take_braced_inner(&end_statement)
	if !end_unwrap_ok {
		stmt_list_deinit(&begin_body, parser.options.allocator)
		return {}, false
	}
	parser_eat_whitespace(parser, true)
	return Define_Env_Stmt{
		name = name,
		param_str = parameters,
		kind = environment_kind,
		inner_begin = begin_body,
		inner_end = end_body,
	}, true
}

parser_parse_lua_code :: proc(parser: ^Parser) -> (result: Stmt, ok: bool) {
	span := parser_current(parser).span
	_, ok = parser_expect_token(parser, .LuaCodeStart, true)
	if !ok { return }
	code := make(Byte_Buffer, 0, 25)
	defer if !ok { delete(code) }
	for !parser_expect(parser, .LuaCodeEnd, .Eof) {
		append(&code, parser_current(parser).literal.in_text)
		parser_next(parser)
	}
	if parser_expect(parser, .Eof) {
		return {}, parser_error(parser, "unexpected end of input in Lua block", span)
	}
	is_global := false
	if parser_expect_peek(parser, .Star) {
		parser_next(parser)
		is_global = true
	}
	imports: Maybe([dynamic]string)
	if parser_expect_peek(parser, .Lsqbrace) {
		list := make([dynamic]string, 0, 10)
		parser_next(parser)
		parser_next(parser)
		for {
			parser_eat_whitespace(parser, true)
			if parser_expect(parser, .Rsqbrace) { break }
			if !parser_expect(parser, .Text) {
				delete(list)
				return {}, parser_error_current(parser, "Lua import name expected")
			}
			append(&list, parser_current(parser).literal.in_text)
			parser_next(parser)
			parser_eat_whitespace(parser, true)
			if parser_expect(parser, .Rsqbrace) { break }
			if !parser_expect(parser, .Comma) {
				delete(list)
				return {}, parser_error_current(parser, "expected comma in Lua import list")
			}
			parser_next(parser)
		}
		imports = list
	}
	code_export: Maybe(string)
	if parser_expect_peek(parser, .Less) {
		parser_next(parser)
		parser_next(parser)
		if !parser_expect(parser, .Text) {
			if list, has_list := imports.?; has_list { delete(list) }
			return {}, parser_error_current(parser, "Lua export name expected")
		}
		code_export = parser_current(parser).literal.in_text
		parser_next(parser)
		if !parser_expect(parser, .Great) {
			if list, has_list := imports.?; has_list { delete(list) }
			return {}, parser_error_current(parser, "Lua export must end with >")
		}
	}
	return Lua_Code_Stmt{
		code_span = span,
		is_global = is_global,
		code_import = imports,
		code_export = code_export,
		code = code,
	}, true
}

parser_owned_text_statement :: proc(parser: ^Parser, text: string) -> (Stmt, bool) {
	owned, ok := parser_owned_cow(parser, text)
	if !ok { return {}, false }
	return Text_Lit_Stmt{text = owned}, true
}

parser_parse_builtin_arguments :: proc(
	parser: ^Parser,
	span: Span,
	open, close: Token_Kind,
	ignore_newline: bool,
) -> (buffer: Byte_Buffer, ok: bool) {
	_, ok = parser_expect_token(parser, open, true)
	if !ok { return }
	buffer = make(Byte_Buffer, 0, 30)
	defer if !ok { delete(buffer) }
	nested := 1
	for {
		kind := parser_current_kind(parser)
		if kind == open {
			nested += 1
		} else if kind == close {
			nested -= 1
			if nested == 0 { break }
		} else if kind == .Eof {
			return buffer, parser_error(parser, "unexpected end of input in builtin argument", span)
		}
		append(&buffer, parser_current(parser).literal.in_text)
		parser_next(parser)
	}
	parser_next(parser)
	parser_eat_whitespace(parser, ignore_newline)
	return buffer, true
}

parser_parse_builtin :: proc(parser: ^Parser, name: string) -> (Stmt, bool) {
	span := parser_current(parser).span
	if parameter, parameter_ok := token_is_function_param(name); parameter_ok {
		if parameter % 10 == 0 {
			return {}, parser_error(parser, "function parameter number must end in 1 through 9", span)
		}
		return Defun_Param_List_Stmt{
			nested = parameter / 10,
			arg_num = parameter % 10,
			span = span,
		}, true
	}

	switch name {
	case "textmode":      return parser_builtin_textmode(parser)
	case "mathmode":      return parser_builtin_mathmode(parser)
	case "label":         return parser_builtin_label(parser)
	case "eq":            return parser_builtin_equation(parser)
	case "showfont":      return parser_builtin_showfont(parser)
	case "chardef":       return parser_builtin_chardef(parser)
	case "mathchardef":   return parser_builtin_mathchardef(parser)
	case "enum":          return parser_builtin_enum(parser)
	case "enum_counter":  return parser_builtin_enum_counter(parser)
	case "get_filepath":  return parser_builtin_get_filepath(parser)
	case "picture":       return parser_builtin_picture(parser)
	case "raw_tex":       return parser_builtin_raw_tex(parser)
	case "engine_type":   return parser_builtin_engine_type(parser)
	case "copy_file":     return parser_builtin_copy_file(parser)
	}
	return {}, parser_error(parser, "invalid builtin function", span, name)
}

parser_builtin_textmode :: proc(parser: ^Parser) -> (result: Stmt, ok: bool) {
	span := parser_current(parser).span
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if !parser.document.math_mode {
		return {}, parser_error(parser, "#textmode may only be used in math mode", span)
	}
	if !parser_expect(parser, .Lbrace) {
		return {}, parser_error_current(parser, "#textmode requires a braced body")
	}
	parser.document.math_mode = false
	result, ok = parser_parse_brace(parser, false)
	parser.document.math_mode = true
	if !ok { return }
	#partial switch &value in result {
	case Braced_Stmt: value.unwrap_brace = true
	}
	return result, true
}

parser_builtin_mathmode :: proc(parser: ^Parser) -> (result: Stmt, ok: bool) {
	span := parser_current(parser).span
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if parser.document.math_mode {
		return {}, parser_error(parser, "#mathmode may not be used in math mode", span)
	}
	if !parser_expect(parser, .Lbrace) {
		return {}, parser_error_current(parser, "#mathmode requires a braced body")
	}
	parser.document.math_mode = true
	result, ok = parser_parse_brace(parser, false)
	parser.document.math_mode = false
	if !ok { return }
	#partial switch &value in result {
	case Braced_Stmt: value.unwrap_brace = true
	}
	return result, true
}

parser_builtin_label :: proc(parser: ^Parser) -> (result: Stmt, ok: bool) {
	span := parser_current(parser).span
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	label, label_ok := parser_parse_builtin_arguments(parser, span, .Lparen, .Rparen, true)
	if !label_ok { return {}, false }
	defer if !ok { delete(label) }
	if !parser_expect(parser, .Useenv) {
		return {}, parser_error(parser, "#label must appear immediately before useenv", span)
	}
	result, ok = parser_parse_environment(parser, true)
	if !ok { return }
	#partial switch &environment in result {
	case Environment_Stmt:
		environment.label = label
		label = nil
	}
	return result, true
}

parser_builtin_equation :: proc(parser: ^Parser) -> (result: Stmt, ok: bool) {
	span := parser_current(parser).span
	if parser.document.math_mode {
		return {}, parser_error(parser, "#eq may not be used inside math mode", span)
	}
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	label: Maybe(Byte_Buffer)
	if parser_expect(parser, .Lparen) {
		parsed, label_ok := parser_parse_builtin_arguments(parser, span, .Lparen, .Rparen, true)
		if !label_ok { return {}, false }
		label = parsed
	}
	defer if !ok {
		if value, has_value := label.?; has_value { delete(value) }
	}
	if !parser_expect(parser, .Lbrace) {
		return {}, parser_error_current(parser, "#eq requires a braced body")
	}
	parser.document.math_mode = true
	body_statement, body_ok := parser_parse_brace(parser, false)
	parser.document.math_mode = false
	if !body_ok { return {}, false }
	body, unwrap_ok := parser_take_braced_inner(&body_statement)
	if !unwrap_ok { return {}, false }
	return Math_Ctx_Stmt{state = .Labeled, inner = body, label = label}, true
}

parser_builtin_raw_tex :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	for parser_expect_peek(parser, .Space, .Tab) { parser_next(parser) }
	if !parser_expect_peek(parser, .DefineFunction) {
		return {}, parser_error(parser, "#raw_tex must appear immediately before defun", span)
	}
	parser.document.xparse_defun = false
	return Nop_Stmt{}, true
}

parser_builtin_engine_type :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	if span.start.row != 1 {
		return {}, parser_error(parser, "#engine_type must be on the first line", span)
	}
	if !parser.options.allow_engine_change || parser.engine_changed || parser.options.engine == nil {
		return {}, parser_error(parser, "LaTeX engine cannot be changed in this context", span)
	}
	parser_next(parser)
	for !parser_expect(parser, .Lparen, .Eof) { parser_next(parser) }
	_, ok := parser_expect_token(parser, .Lparen, true)
	if !ok { return {}, false }
	parser_eat_whitespace(parser, true)
	if !parser_expect(parser, .Text) {
		return {}, parser_error_current(parser, "LaTeX engine name expected")
	}
	engine: Latex_Engine
	engine_ok := true
	switch parser_current(parser).literal.in_text {
	case "plain": engine = .latex
	case "pdf":   engine = .pdflatex
	case "xe":    engine = .xelatex
	case "lua":   engine = .lualatex
	case "tect":  engine = .tectonic
	case: engine_ok = false
	}
	if !engine_ok {
		return {}, parser_error_current(parser, "invalid LaTeX engine")
	}
	parser_next(parser)
	parser_eat_whitespace(parser, true)
	if !parser_expect(parser, .Rparen) {
		return {}, parser_error_current(parser, "#engine_type argument is not closed")
	}
	parser.options.engine^ = engine
	parser.current_engine = engine
	parser.engine_changed = true
	return Nop_Stmt{}, true
}

parser_builtin_showfont :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	_, ok := parser_expect_token(parser, .Lparen, true)
	if !ok { return {}, false }
	if !parser_expect(parser, .Integer) {
		return {}, parser_error(parser, "#showfont expects an integer", span)
	}
	number, number_ok := strconv.parse_uint(parser_current(parser).literal.in_text, 10)
	if !number_ok || number > 255 {
		return {}, parser_error(parser, "#showfont integer must be between 0 and 255", span)
	}
	parser_next(parser)
	if !parser_expect(parser, .Rparen) {
		return {}, parser_error_current(parser, "#showfont argument is not closed")
	}
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	_ = strings.write_string(&builder, " {\\ttfamily\\expandafter\\meaning\\the\\textfont")
	_ = fmt.sbprintf(&builder, "%d", number)
	_ = strings.write_byte(&builder, '}')
	return parser_owned_text_statement(parser, strings.to_string(builder))
}

parser_builtin_chardef :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if !parser_expect(parser, .Text, .Integer) {
		return {}, parser_error_current(parser, "#chardef expects a hexadecimal codepoint")
	}
	codepoint, codepoint_ok := strconv.parse_uint(parser_current(parser).literal.in_text, 16)
	if !codepoint_ok {
		return {}, parser_error(parser, "#chardef expects a hexadecimal codepoint", span)
	}
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if !parser_expect(parser, .LatexFunction, .MakeAtLetterFnt) {
		return {}, parser_error_current(parser, "#chardef expects a LaTeX control sequence")
	}
	function := parser_current(parser).literal.in_text
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if !parser_expect(parser, .Newline) {
		return {}, parser_error(parser, "#chardef must end at a newline", span)
	}
	text := fmt.aprintf("\\chardef%s=\"%X\n", function, codepoint)
	defer delete(text)
	return parser_owned_text_statement(parser, text)
}

Parser_Math_Class :: enum u8 {
	ordinary,
	largeop,
	binary,
	relation,
	opening,
	closing,
	punct,
	variable,
}

parser_math_class :: proc(name: string) -> (Parser_Math_Class, bool) {
	switch name {
	case "ordinary": return .ordinary, true
	case "largeop":  return .largeop, true
	case "binary":   return .binary, true
	case "relation": return .relation, true
	case "opening":  return .opening, true
	case "closing":  return .closing, true
	case "punct":    return .punct, true
	case "variable": return .variable, true
	}
	return {}, false
}

parser_builtin_mathchardef :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	_, ok := parser_expect_token(parser, .Period, true)
	if !ok { return {}, false }
	if !parser_expect(parser, .Text) {
		return {}, parser_error_current(parser, "#mathchardef expects a math class")
	}
	class, class_ok := parser_math_class(parser_current(parser).literal.in_text)
	if !class_ok {
		return {}, parser_error(parser, "invalid #mathchardef math class", span)
	}
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if !parser_expect(parser, .Integer) {
		return {}, parser_error_current(parser, "#mathchardef expects a font number")
	}
	font, font_ok := strconv.parse_uint(parser_current(parser).literal.in_text, 10)
	if !font_ok || font > 255 {
		return {}, parser_error(parser, "#mathchardef font must be between 0 and 255", span)
	}
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if !parser_expect(parser, .Text, .Integer) {
		return {}, parser_error_current(parser, "#mathchardef expects a hexadecimal codepoint")
	}
	codepoint, codepoint_ok := strconv.parse_uint(parser_current(parser).literal.in_text, 16)
	if !codepoint_ok {
		return {}, parser_error(parser, "#mathchardef expects a hexadecimal codepoint", span)
	}
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if !parser_expect(parser, .LatexFunction, .MakeAtLetterFnt) {
		return {}, parser_error_current(parser, "#mathchardef expects a LaTeX control sequence")
	}
	function := parser_current(parser).literal.in_text
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if !parser_expect(parser, .Newline) {
		return {}, parser_error(parser, "#mathchardef must end at a newline", span)
	}
	text := fmt.aprintf(
		"\\Umathchardef%s=%d %d \"%X\n",
		function,
		int(class),
		font,
		codepoint,
	)
	defer delete(text)
	return parser_owned_text_statement(parser, text)
}

parser_enum_label_name :: proc(depth: int) -> string {
	switch depth {
	case 1: return "labelenumi"
	case 2: return "labelenumii"
	case 3: return "labelenumiii"
	case 4: return "labelenumiv"
	}
	return "labelenumi"
}

parser_enum_counter_name :: proc(depth: int) -> string {
	switch depth {
	case 1: return "enumi"
	case 2: return "enumii"
	case 3: return "enumiii"
	case 4: return "enumiv"
	}
	return "enumi"
}

parser_builtin_enum :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	if parser.enum_depth >= 4 {
		return {}, parser_error(parser, "#enum cannot be nested more than four times", span)
	}
	parser.enum_depth += 1
	defer parser.enum_depth -= 1
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	label: Maybe(Byte_Buffer)
	if parser_expect(parser, .Lparen) {
		value, label_ok := parser_parse_builtin_arguments(parser, span, .Lparen, .Rparen, true)
		if !label_ok { return {}, false }
		label = value
	}
	defer {
		if value, has_value := label.?; has_value { delete(value) }
	}
	if !parser_expect(parser, .Lbrace) {
		return {}, parser_error_current(parser, "#enum requires a braced body")
	}
	body_statement, body_ok := parser_parse_brace(parser, false)
	if !body_ok { return {}, false }
	body, unwrap_ok := parser_take_braced_inner(&body_statement)
	if !unwrap_ok { return {}, false }
	output := make(Stmt_List, 0, 4)
	append(&output, Text_Lit_Stmt{text = cow_str_borrowed("\\begingroup ")})
	if value, has_value := label.?; has_value {
		builder := strings.builder_make()
		_ = strings.write_string(&builder, "\\renewcommand{\\")
		_ = strings.write_string(&builder, parser_enum_label_name(parser.enum_depth))
		_ = strings.write_string(&builder, "}{")
		index := 0
		for index < len(value) {
			if value[index] != '*' {
				_ = strings.write_byte(&builder, value[index])
				index += 1
				continue
			}
			if index + 1 < len(value) && value[index+1] == '*' {
				_ = strings.write_byte(&builder, '*')
				index += 2
				continue
			}
			_ = strings.write_byte(&builder, '{')
			_ = strings.write_string(&builder, parser_enum_counter_name(parser.enum_depth))
			_ = strings.write_byte(&builder, '}')
			index += 1
		}
		_ = strings.write_string(&builder, "}\n")
		reset, reset_ok := parser_owned_cow(parser, strings.to_string(builder))
		strings.builder_destroy(&builder)
		if !reset_ok {
			stmt_list_deinit(&body, parser.options.allocator)
			stmt_list_deinit(&output, parser.options.allocator)
			return {}, false
		}
		append(&output, Text_Lit_Stmt{text = reset})
	}
	append(&output, Environment_Stmt{
		name = cow_str_borrowed("enumerate"),
		args = make(Arg_List),
		inner = body,
	})
	append(&output, Text_Lit_Stmt{text = cow_str_borrowed("\\endgroup ")})
	return Braced_Stmt{unwrap_brace = true, inner = output}, true
}

parser_builtin_enum_counter :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	if parser.enum_depth == 0 {
		return {}, parser_error(parser, "#enum_counter may only be used inside #enum", span)
	}
	return parser_owned_text_statement(parser, parser_enum_counter_name(parser.enum_depth))
}

parser_home_directory :: proc(parser: ^Parser) -> (string, bool) {
	when ODIN_OS == .Windows {
		return os.lookup_env("USERPROFILE", parser.options.allocator)
	} else {
		return os.lookup_env("HOME", parser.options.allocator)
	}
}

parser_parse_filepath :: proc(parser: ^Parser, span: Span) -> (path: Byte_Buffer, basename: string, ok: bool) {
	_, ok = parser_expect_token(parser, .Lparen, true)
	if !ok { return }
	raw := make(Byte_Buffer, 0, 30)
	defer if !ok { delete(raw) }
	inside_config := false
	first := true
	nested := 1
	for {
		kind := parser_current_kind(parser)
		if kind == .Lparen {
			nested += 1
		} else if kind == .Rparen {
			nested -= 1
			if nested == 0 { break }
		} else if kind == .Eof {
			return nil, "", parser_error(parser, "file path parenthesis is not closed", span)
		} else if kind == .Tilde && first {
			home, found := parser_home_directory(parser)
			if !found {
				return nil, "", parser_error(parser, "cannot determine home directory", span)
			}
			append(&raw, home)
			delete(home, parser.options.allocator)
			first = false
			parser_next(parser)
			continue
		} else if kind == .At && first {
			inside_config = true
			if !parser_expect_peek(parser, .Slash) {
				return nil, "", parser_error(parser, "@ in a file path must be followed by /", span)
			}
			parser_next(parser)
			first = false
			parser_next(parser)
			continue
		}
		append(&raw, parser_current(parser).literal.in_text)
		first = false
		parser_next(parser)
	}
	trimmed := strings.trim(string(raw[:]), " \t")
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	if inside_config {
		config_path := parser.options.config_directory
		owned_config := false
		if len(config_path) == 0 {
			found: bool
			config_path, found = config_directory(parser.options.allocator)
			if !found {
				return nil, "", parser_error(parser, "cannot determine Vesti config directory", span)
			}
			owned_config = true
		}
		if owned_config { defer delete(config_path, parser.options.allocator) }
		joined, join_err := filepath.join({config_path, trimmed}, parser.options.allocator)
		if join_err != nil {
			return nil, "", parser_error(parser, "cannot construct config-relative file path", span)
		}
		_ = strings.write_string(&builder, joined)
		delete(joined, parser.options.allocator)
	} else if filepath.is_abs(trimmed) {
		_ = strings.write_string(&builder, trimmed)
	} else {
		_ = strings.write_string(&builder, "./")
		_ = strings.write_string(&builder, trimmed)
	}
	delete(raw)
	path = parser_byte_buffer(strings.to_string(builder))
	basename = filepath.base(string(path[:]))
	return path, basename, true
}

parser_builtin_get_filepath :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if !parser_expect(parser, .Lparen) {
		return {}, parser_error_current(parser, "#get_filepath expects a path")
	}
	path, _, path_ok := parser_parse_filepath(parser, span)
	if !path_ok { return {}, false }
	defer delete(path)
	relative, relative_err := filepath.rel(parser.options.dummy_directory, string(path[:]), parser.options.allocator)
	if relative_err != .None {
		return {}, parser_error(parser, "cannot compute path relative to output directory", span)
	}
	defer delete(relative, parser.options.allocator)
	normalized, allocated := strings.replace_all(relative, "\\", "/", parser.options.allocator)
	defer if allocated { delete(normalized, parser.options.allocator) }
	owned, owned_ok := parser_owned_cow(parser, normalized)
	if !owned_ok { return {}, false }
	return File_Path_Stmt{path = owned}, true
}

parser_builtin_picture :: proc(parser: ^Parser) -> (result: Stmt, ok: bool) {
	span := parser_current(parser).span
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	unit_length: Maybe(Byte_Buffer)
	if parser_expect(parser, .Lsqbrace) {
		value, value_ok := parser_parse_builtin_arguments(parser, span, .Lsqbrace, .Rsqbrace, false)
		if !value_ok { return {}, false }
		unit_length = value
	}
	defer if !ok {
		if value, has_value := unit_length.?; has_value { delete(value) }
	}
	_, ok = parser_expect_token(parser, .Lparen, true)
	if !ok { return {}, false }
	if !parser_expect(parser, .Integer) {
		return {}, parser_error_current(parser, "#picture width must be an integer")
	}
	width, width_ok := strconv.parse_uint(parser_current(parser).literal.in_text, 10)
	if !width_ok { return {}, parser_error(parser, "#picture width must be nonnegative", span) }
	parser_next(parser)
	_, ok = parser_expect_token(parser, .Comma, true)
	if !ok { return {}, false }
	parser_eat_whitespace(parser, false)
	if !parser_expect(parser, .Integer) {
		return {}, parser_error_current(parser, "#picture height must be an integer")
	}
	height, height_ok := strconv.parse_uint(parser_current(parser).literal.in_text, 10)
	if !height_ok { return {}, parser_error(parser, "#picture height must be nonnegative", span) }
	parser_next(parser)
	_, ok = parser_expect_token(parser, .Rparen, true)
	if !ok { return {}, false }
	parser_eat_whitespace(parser, false)
	xoffset: Maybe(uint)
	yoffset: Maybe(uint)
	if parser_expect(parser, .Lparen) {
		parser_next(parser)
		if !parser_expect(parser, .Integer) {
			return {}, parser_error_current(parser, "#picture x offset must be an integer")
		}
		x, x_ok := strconv.parse_uint(parser_current(parser).literal.in_text, 10)
		if !x_ok { return {}, parser_error(parser, "#picture x offset must be nonnegative", span) }
		xoffset = x
		parser_next(parser)
		_, ok = parser_expect_token(parser, .Comma, true)
		if !ok { return {}, false }
		parser_eat_whitespace(parser, false)
		if !parser_expect(parser, .Integer) {
			return {}, parser_error_current(parser, "#picture y offset must be an integer")
		}
		y, y_ok := strconv.parse_uint(parser_current(parser).literal.in_text, 10)
		if !y_ok { return {}, parser_error(parser, "#picture y offset must be nonnegative", span) }
		yoffset = y
		parser_next(parser)
		_, ok = parser_expect_token(parser, .Rparen, true)
		if !ok { return {}, false }
	}
	parser_eat_whitespace(parser, true)
	if !parser_expect(parser, .Lbrace) {
		return {}, parser_error_current(parser, "#picture requires a braced body")
	}
	body_statement, body_ok := parser_parse_brace(parser, false)
	if !body_ok { return {}, false }
	body, unwrap_ok := parser_take_braced_inner(&body_statement)
	if !unwrap_ok { return {}, false }
	return Picture_Environment_Stmt{
		width = width,
		height = height,
		xoffset = xoffset,
		yoffset = yoffset,
		unit_length = unit_length,
		inner = body,
	}, true
}

parser_builtin_copy_file :: proc(parser: ^Parser) -> (Stmt, bool) {
	span := parser_current(parser).span
	parser_next(parser)
	parser_eat_whitespace(parser, false)
	if !parser_expect(parser, .Lparen) {
		return {}, parser_error_current(parser, "#copy_file expects a path")
	}
	path, basename, path_ok := parser_parse_filepath(parser, span)
	if !path_ok { return {}, false }
	defer delete(path)
	if parser.options.perform_file_operations {
		destination, join_err := filepath.join(
			{parser.options.dummy_directory, basename},
			parser.options.allocator,
		)
		if join_err != nil {
			return {}, parser_error(parser, "cannot construct #copy_file destination", span)
		}
		defer delete(destination, parser.options.allocator)
		if os.copy_file(destination, string(path[:])) != nil {
			return {}, parser_error(parser, "cannot copy requested file", span, string(path[:]))
		}
	}
	return Nop_Stmt{}, true
}

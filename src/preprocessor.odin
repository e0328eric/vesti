package main

import "core:fmt"
import "core:mem"
import "core:os"
import filepath "core:path/filepath"
import "core:strings"

import lua "vendor:lua/5.4"

// Token_List owns its token buffer and any included source buffers referenced
// by those tokens.  The caller's root source remains borrowed.
Token_List :: struct {
	items:         [dynamic]Token,
	owned_sources: [dynamic]string,
}

token_list_make :: proc(
	capacity := 0,
	allocator := context.allocator,
) -> (list: Token_List, err: mem.Allocator_Error) {
	items := make([dynamic]Token, 0, capacity, allocator) or_return
	return Token_List{items = items}, nil
}

token_list_deinit :: proc(list: ^Token_List, allocator := context.allocator) {
	if list == nil {
		return
	}
	for source in list.owned_sources {
		delete(source, allocator)
	}
	if list.owned_sources != nil {
		delete(list.owned_sources)
	}
	if list.items != nil {
		delete(list.items)
	}
	list^ = {}
}

token_list_len :: proc(list: ^Token_List) -> int {
	return 0 if list == nil else len(list.items)
}

token_list_get :: proc(list: ^Token_List, index: int) -> Token {
	assert(list != nil && index >= 0 && index < len(list.items))
	return list.items[index]
}

token_list_append :: proc(list: ^Token_List, token: Token) -> mem.Allocator_Error {
	_, err := append(&list.items, token)
	return err
}

Comptime_Function :: struct {
	params:   int,
	contents: Token_List,
}

Cond_Kind :: enum u8 {
	If,
	Ifdef,
	Ifndef,
	Elif,
	Elifdef,
	Elifndef,
	Else,
	Endif,
}

Cond_Frame :: struct {
	parent_emit: bool,
	taken:       bool,
	emit:        bool,
	seen_else:   bool,
	open_span:   Span,
}

Preprocessor :: struct {
	allocator:        mem.Allocator,
	diagnostic:       ^Diagnostic,
	source:           string,
	base_dir:         string,
	comptime_fnt:     map[string]Comptime_Function,
	included_stack:   [dynamic]string,
	included_sources: [dynamic]string,
	cond_stack:       [dynamic]Cond_Frame,
	lua_state:        ^lua.State,
	allow_latex3:     bool,
	is_premiere:      bool,
	expansion_depth:  int,
	processed:        bool,
}

Preprocess_Cursor :: struct {
	lexer: Lexer,
	curr:  Token,
	peek:  Token,
}

// source, base_dir, and diagnostic are borrowed. The returned preprocessor is
// single-use and must be released with preprocessor_deinit.
preprocessor_init :: proc(
	source: string,
	base_dir := ".",
	diagnostic: ^Diagnostic = nil,
	allocator := context.allocator,
) -> (preprocessor: Preprocessor, err: mem.Allocator_Error) {
	comptime_fnt, map_err := make(map[string]Comptime_Function, 64, allocator)
	if map_err != nil {
		return {}, map_err
	}
	included_stack, stack_err := make([dynamic]string, 0, 8, allocator)
	if stack_err != nil {
		delete(comptime_fnt)
		return {}, stack_err
	}
	included_sources, sources_err := make([dynamic]string, 0, 8, allocator)
	if sources_err != nil {
		delete(included_stack)
		delete(comptime_fnt)
		return {}, sources_err
	}
	cond_stack, cond_err := make([dynamic]Cond_Frame, 0, 8, allocator)
	if cond_err != nil {
		delete(included_sources)
		delete(included_stack)
		delete(comptime_fnt)
		return {}, cond_err
	}
	return Preprocessor{
		allocator = allocator,
		diagnostic = diagnostic,
		source = source,
		base_dir = base_dir,
		comptime_fnt = comptime_fnt,
		included_stack = included_stack,
		included_sources = included_sources,
		cond_stack = cond_stack,
		allow_latex3 = true,
		is_premiere = true,
	}, nil
}

preprocessor_deinit :: proc(preprocessor: ^Preprocessor) {
	if preprocessor == nil {
		return
	}
	for _, comptime_function in preprocessor.comptime_fnt {
		contents := comptime_function.contents
		token_list_deinit(&contents, preprocessor.allocator)
	}
	if preprocessor.comptime_fnt != nil {
		delete(preprocessor.comptime_fnt)
	}
	for source in preprocessor.included_sources {
		delete(source, preprocessor.allocator)
	}
	if preprocessor.included_sources != nil {
		delete(preprocessor.included_sources)
	}
	for path in preprocessor.included_stack {
		delete(path, preprocessor.allocator)
	}
	if preprocessor.included_stack != nil {
		delete(preprocessor.included_stack)
	}
	if preprocessor.cond_stack != nil {
		delete(preprocessor.cond_stack)
	}
	if preprocessor.lua_state != nil {
		lua.close(preprocessor.lua_state)
	}
	preprocessor^ = {}
}

preprocess_cursor_init :: proc(source: string) -> Preprocess_Cursor {
	cursor := Preprocess_Cursor{
		lexer = lexer_init(source),
		curr = token_invalid(),
		peek = token_invalid(),
	}
	preprocess_cursor_next(&cursor)
	preprocess_cursor_next(&cursor)
	return cursor
}

preprocess_cursor_next :: proc(cursor: ^Preprocess_Cursor) {
	cursor.curr = cursor.peek
	cursor.peek = lexer_next(&cursor.lexer)
}

preprocessor_error :: proc(
	preprocessor: ^Preprocessor,
	span: Span,
	message: string,
	note := "",
) -> bool {
	if preprocessor.diagnostic != nil {
		_ = diagnostic_set(
			preprocessor.diagnostic,
			.Parse,
			message,
			span,
			true,
			note,
		)
	}
	return false
}

preprocessor_errorf :: proc(
	preprocessor: ^Preprocessor,
	span: Span,
	note: string,
	format: string,
	args: ..any,
) -> bool {
	message := fmt.aprintf(format, ..args, allocator = preprocessor.allocator)
	defer delete(message, preprocessor.allocator)
	return preprocessor_error(preprocessor, span, message, note)
}

preprocessor_allocation_error :: proc(preprocessor: ^Preprocessor, span: Span = {}) -> bool {
	return preprocessor_error(preprocessor, span, "memory allocation failed while preprocessing")
}

preprocessor_append :: proc(
	preprocessor: ^Preprocessor,
	list: ^Token_List,
	token: Token,
) -> bool {
	if err := token_list_append(list, token); err != nil {
		return preprocessor_allocation_error(preprocessor, token.span)
	}
	return true
}

preprocessor_is_builtin :: proc(name: string) -> bool {
	return token_is_any_builtin(name)
}

preprocessor_cond_kind :: proc(name: string) -> (Cond_Kind, bool) {
	switch name {
	case "if":       return .If, true
	case "ifdef":    return .Ifdef, true
	case "ifndef":   return .Ifndef, true
	case "elif":     return .Elif, true
	case "elifdef":  return .Elifdef, true
	case "elifndef": return .Elifndef, true
	case "else":     return .Else, true
	case "endif":    return .Endif, true
	}
	return {}, false
}

preprocessor_emitting :: proc(preprocessor: ^Preprocessor) -> bool {
	if len(preprocessor.cond_stack) == 0 {
		return true
	}
	return preprocessor.cond_stack[len(preprocessor.cond_stack)-1].emit
}

preprocessor_skip_whitespace :: proc(cursor: ^Preprocess_Cursor, include_newline := false) {
	for cursor.curr.kind == .Space || cursor.curr.kind == .Tab ||
	    (include_newline && cursor.curr.kind == .Newline) {
		preprocess_cursor_next(cursor)
	}
}

preprocessor_eat_directive_line_end :: proc(cursor: ^Preprocess_Cursor) {
	for cursor.curr.kind == .Space || cursor.curr.kind == .Tab {
		preprocess_cursor_next(cursor)
	}
	if cursor.curr.kind == .Newline {
		preprocess_cursor_next(cursor)
	}
}

preprocessor_is_macro_defined :: proc(preprocessor: ^Preprocessor, name: string) -> bool {
	_, ok := preprocessor.comptime_fnt[name]
	return ok
}

preprocessor_parse_slice_args :: proc(
	preprocessor: ^Preprocessor,
	input: []Token,
	start_index: int,
	params_count: int,
	span: Span,
	args: ^[dynamic]Token_List,
) -> (next_index: int, ok: bool) {
	index := start_index
	for _ in 0 ..< params_count {
		for index < len(input) &&
		    (input[index].kind == .Space || input[index].kind == .Tab ||
		     input[index].kind == .Newline) {
			index += 1
		}
		if index >= len(input) || input[index].kind != .Lparen {
			return index, preprocessor_error(
				preprocessor,
				span,
				"parenthesized macro argument expected",
			)
		}
		index += 1
		argument, err := token_list_make(8, preprocessor.allocator)
		if err != nil {
			return index, preprocessor_allocation_error(preprocessor, span)
		}
		depth := 1
		for index < len(input) {
			token := input[index]
			if token.kind == .Lparen {
				depth += 1
			} else if token.kind == .Rparen {
				depth -= 1
				if depth == 0 {
					index += 1
					break
				}
			}
			if !preprocessor_append(preprocessor, &argument, token) {
				token_list_deinit(&argument, preprocessor.allocator)
				return index, false
			}
			index += 1
		}
		if depth != 0 {
			token_list_deinit(&argument, preprocessor.allocator)
			return index, preprocessor_error(
				preprocessor,
				span,
				"`)` expected to close a macro argument",
			)
		}
		if _, append_err := append(args, argument); append_err != nil {
			token_list_deinit(&argument, preprocessor.allocator)
			return index, preprocessor_allocation_error(preprocessor, span)
		}
	}
	return index, true
}

preprocessor_expand_tokens :: proc(
	preprocessor: ^Preprocessor,
	input: []Token,
	args: []Token_List,
	output: ^Token_List,
) -> bool {
	if preprocessor.expansion_depth >= 256 {
		span := span_init()
		if len(input) > 0 {
			span = input[0].span
		}
		return preprocessor_error(preprocessor, span, "macro expansion limit exceeded")
	}
	preprocessor.expansion_depth += 1
	defer preprocessor.expansion_depth -= 1

	index := 0
	for index < len(input) {
		token := input[index]
		if token.kind != .BuiltinFunction {
			if !preprocessor_append(preprocessor, output, token) {
				return false
			}
			index += 1
			continue
		}

		name := token.builtin_name
		if token_is_preprocess_builtin(name) {
			return preprocessor_errorf(
				preprocessor,
				token.span,
				"preprocessor directives are not valid inside macro bodies",
				"preprocessor directive `#%s` cannot be expanded here",
				name,
			)
		}
		if token_is_builtin(name) {
			if !preprocessor_append(preprocessor, output, token) {
				return false
			}
			index += 1
			continue
		}

		if parameter_index, is_parameter := token_is_function_param(name); is_parameter {
			if parameter_index == 0 || int(parameter_index) > len(args) {
				return preprocessor_errorf(
					preprocessor,
					token.span,
					"macro parameter indices start at one and must be in range",
					"invalid macro parameter `#%d`",
					parameter_index,
				)
			}
			argument := args[int(parameter_index)-1]
			if !preprocessor_expand_tokens(preprocessor, argument.items[:], nil, output) {
				return false
			}
			index += 1
			continue
		}

		comptime_function, defined := preprocessor.comptime_fnt[name]
		if !defined {
			// Undefined builtins in stored bodies stay intact, matching the Zig
			// implementation and allowing a later parser diagnostic.
			if !preprocessor_append(preprocessor, output, token) {
				return false
			}
			index += 1
			continue
		}

		raw_args, raw_args_err := make(
			[dynamic]Token_List,
			0,
			comptime_function.params,
			preprocessor.allocator,
		)
		if raw_args_err != nil {
			return preprocessor_allocation_error(preprocessor, token.span)
		}
		next_index, parsed := preprocessor_parse_slice_args(
			preprocessor,
			input,
			index+1,
			comptime_function.params,
			token.span,
			&raw_args,
		)
		if !parsed {
			for &argument in raw_args {
				token_list_deinit(&argument, preprocessor.allocator)
			}
			delete(raw_args)
			return false
		}

		resolved_args, resolved_args_err := make(
			[dynamic]Token_List,
			0,
			comptime_function.params,
			preprocessor.allocator,
		)
		if resolved_args_err != nil {
			for &argument in raw_args {
				token_list_deinit(&argument, preprocessor.allocator)
			}
			delete(raw_args)
			return preprocessor_allocation_error(preprocessor, token.span)
		}
		resolved_ok := true
		for raw_argument in raw_args {
			resolved_argument, make_err := token_list_make(8, preprocessor.allocator)
			if make_err != nil {
				resolved_ok = false
				break
			}
			if !preprocessor_expand_tokens(
				preprocessor,
				raw_argument.items[:],
				args,
				&resolved_argument,
			) {
				token_list_deinit(&resolved_argument, preprocessor.allocator)
				resolved_ok = false
				break
			}
			if _, append_err := append(&resolved_args, resolved_argument); append_err != nil {
				token_list_deinit(&resolved_argument, preprocessor.allocator)
				resolved_ok = false
				break
			}
		}
		for &argument in raw_args {
			token_list_deinit(&argument, preprocessor.allocator)
		}
		delete(raw_args)
		if !resolved_ok {
			for &argument in resolved_args {
				token_list_deinit(&argument, preprocessor.allocator)
			}
			delete(resolved_args)
			if preprocessor.diagnostic == nil || preprocessor.diagnostic.kind == .None {
				_ = preprocessor_allocation_error(preprocessor, token.span)
			}
			return false
		}

		expanded := preprocessor_expand_tokens(
			preprocessor,
			comptime_function.contents.items[:],
			resolved_args[:],
			output,
		)
		for &argument in resolved_args {
			token_list_deinit(&argument, preprocessor.allocator)
		}
		delete(resolved_args)
		if !expanded {
			return false
		}
		index = next_index
	}
	return true
}

preprocessor_collect_condition :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	span: Span,
	condition: ^[dynamic]u8,
) -> bool {
	preprocess_cursor_next(cursor) // directive
	preprocessor_skip_whitespace(cursor)
	if cursor.curr.kind != .Lparen {
		return preprocessor_error(
			preprocessor,
			span,
			"`(` expected after `#if`/`#elif`",
		)
	}
	preprocess_cursor_next(cursor)

	raw_tokens, make_err := token_list_make(16, preprocessor.allocator)
	if make_err != nil {
		return preprocessor_allocation_error(preprocessor, span)
	}
	defer token_list_deinit(&raw_tokens, preprocessor.allocator)
	depth := 1
	condition_loop: for {
		#partial switch cursor.curr.kind {
		case .Lparen:
			depth += 1
		case .Rparen:
			depth -= 1
			if depth == 0 {
				preprocess_cursor_next(cursor)
				break condition_loop
			}
		case .Eof:
			return preprocessor_error(
				preprocessor,
				span,
				"`)` expected to close the `#if`/`#elif` condition",
			)
		}
		if !preprocessor_append(preprocessor, &raw_tokens, cursor.curr) {
			return false
		}
		preprocess_cursor_next(cursor)
	}

	expanded, expanded_err := token_list_make(len(raw_tokens.items), preprocessor.allocator)
	if expanded_err != nil {
		return preprocessor_allocation_error(preprocessor, span)
	}
	defer token_list_deinit(&expanded, preprocessor.allocator)
	if !preprocessor_expand_tokens(preprocessor, raw_tokens.items[:], nil, &expanded) {
		return false
	}
	for token in expanded.items {
		if _, append_err := append(condition, token.literal.in_text); append_err != nil {
			return preprocessor_allocation_error(preprocessor, span)
		}
	}
	return true
}

preprocessor_skip_condition :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	span: Span,
) -> bool {
	preprocess_cursor_next(cursor)
	preprocessor_skip_whitespace(cursor)
	if cursor.curr.kind != .Lparen {
		return preprocessor_error(
			preprocessor,
			span,
			"`(` expected after `#if`/`#elif`",
		)
	}
	preprocess_cursor_next(cursor)
	depth := 1
	for depth > 0 {
		#partial switch cursor.curr.kind {
		case .Lparen:
			depth += 1
		case .Rparen:
			depth -= 1
		case .Eof:
			return preprocessor_error(
				preprocessor,
				span,
				"`)` expected to close the `#if`/`#elif` condition",
			)
		}
		preprocess_cursor_next(cursor)
	}
	return true
}

preprocessor_lua :: proc(preprocessor: ^Preprocessor, span: Span) -> (^lua.State, bool) {
	if preprocessor.lua_state != nil {
		return preprocessor.lua_state, true
	}
	state := lua.L_newstate()
	if state == nil {
		_ = preprocessor_error(preprocessor, span, "failed to initialize Lua for `#if`")
		return nil, false
	}
	lua.L_openlibs(state)
	preprocessor.lua_state = state
	return state, true
}

preprocessor_eval_if :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	span: Span,
) -> (value: bool, ok: bool) {
	expression := make([dynamic]u8, 0, 64, preprocessor.allocator) or_else nil
	if expression == nil {
		_ = preprocessor_allocation_error(preprocessor, span)
		return false, false
	}
	defer delete(expression)
	if !preprocessor_collect_condition(preprocessor, cursor, span, &expression) {
		return false, false
	}

	code := make(
		[dynamic]u8,
		0,
		len(expression)+10,
		preprocessor.allocator,
	) or_else nil
	if code == nil {
		_ = preprocessor_allocation_error(preprocessor, span)
		return false, false
	}
	defer delete(code)
	if _, err := append(&code, "return ("); err != nil {
		_ = preprocessor_allocation_error(preprocessor, span)
		return false, false
	}
	if _, err := append(&code, string(expression[:])); err != nil {
		_ = preprocessor_allocation_error(preprocessor, span)
		return false, false
	}
	if _, err := append(&code, ")"); err != nil {
		_ = preprocessor_allocation_error(preprocessor, span)
		return false, false
	}
	c_code, clone_err := strings.clone_to_cstring(string(code[:]), preprocessor.allocator)
	if clone_err != nil {
		_ = preprocessor_allocation_error(preprocessor, span)
		return false, false
	}
	defer delete(c_code, preprocessor.allocator)

	state, state_ok := preprocessor_lua(preprocessor, span)
	if !state_ok {
		return false, false
	}
	status := lua.L_dostring(state, c_code)
	if status != 0 {
		lua.settop(state, 0)
		_ = preprocessor_error(
			preprocessor,
			span,
			"failed to evaluate `#if`/`#elif` condition as Lua",
		)
		return false, false
	}
	value = lua.gettop(state) > 0 && bool(lua.toboolean(state, -1))
	lua.settop(state, 0)
	return value, true
}

preprocessor_eval_defined :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	span: Span,
	negate: bool,
) -> (value: bool, ok: bool) {
	preprocess_cursor_next(cursor)
	preprocessor_skip_whitespace(cursor)
	if cursor.curr.kind != .BuiltinFunction {
		_ = preprocessor_error(
			preprocessor,
			span,
			"macro name `#NAME` expected after `#ifdef`/`#ifndef`",
		)
		return false, false
	}
	value = preprocessor_is_macro_defined(preprocessor, cursor.curr.builtin_name) != negate
	preprocess_cursor_next(cursor)
	return value, true
}

preprocessor_skip_defined :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	span: Span,
) -> bool {
	preprocess_cursor_next(cursor)
	preprocessor_skip_whitespace(cursor)
	if cursor.curr.kind != .BuiltinFunction {
		return preprocessor_error(
			preprocessor,
			span,
			"macro name `#NAME` expected after `#ifdef`/`#ifndef`",
		)
	}
	preprocess_cursor_next(cursor)
	return true
}

preprocessor_skip_conditional_argument :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	kind: Cond_Kind,
	span: Span,
) -> bool {
	switch kind {
	case .If, .Elif:
		return preprocessor_skip_condition(preprocessor, cursor, span)
	case .Ifdef, .Ifndef, .Elifdef, .Elifndef:
		return preprocessor_skip_defined(preprocessor, cursor, span)
	case .Else, .Endif:
		preprocess_cursor_next(cursor)
		return true
	}
	return false
}

preprocessor_handle_conditional :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	kind: Cond_Kind,
) -> bool {
	span := cursor.curr.span
	switch kind {
	case .If, .Ifdef, .Ifndef:
		parent_emit := preprocessor_emitting(preprocessor)
		condition := false
		if parent_emit {
			condition_ok := false
			#partial switch kind {
			case .If:
				condition, condition_ok = preprocessor_eval_if(preprocessor, cursor, span)
			case .Ifdef:
				condition, condition_ok = preprocessor_eval_defined(
					preprocessor,
					cursor,
					span,
					false,
				)
			case .Ifndef:
				condition, condition_ok = preprocessor_eval_defined(
					preprocessor,
					cursor,
					span,
					true,
				)
			}
			if !condition_ok {
				return false
			}
		} else if !preprocessor_skip_conditional_argument(
			preprocessor,
			cursor,
			kind,
			span,
		) {
			return false
		}
		frame := Cond_Frame{
			parent_emit = parent_emit,
			taken = !parent_emit || condition,
			emit = parent_emit && condition,
			open_span = span,
		}
		if _, err := append(&preprocessor.cond_stack, frame); err != nil {
			return preprocessor_allocation_error(preprocessor, span)
		}

	case .Elif, .Elifdef, .Elifndef, .Else:
		if len(preprocessor.cond_stack) == 0 {
			return preprocessor_error(
				preprocessor,
				span,
				"`#elif`/`#else` without a matching `#if`",
			)
		}
		frame := &preprocessor.cond_stack[len(preprocessor.cond_stack)-1]
		if frame.seen_else {
			return preprocessor_error(
				preprocessor,
				span,
				"`#elif`/`#else` after `#else`",
			)
		}
		if kind == .Else {
			frame.seen_else = true
		}

		if frame.parent_emit && !frame.taken {
			condition := kind == .Else
			condition_ok := true
			#partial switch kind {
			case .Elif:
				condition, condition_ok = preprocessor_eval_if(preprocessor, cursor, span)
			case .Elifdef:
				condition, condition_ok = preprocessor_eval_defined(
					preprocessor,
					cursor,
					span,
					false,
				)
			case .Elifndef:
				condition, condition_ok = preprocessor_eval_defined(
					preprocessor,
					cursor,
					span,
					true,
				)
			case .Else:
				preprocess_cursor_next(cursor)
			}
			if !condition_ok {
				return false
			}
			frame.emit = condition
			if condition {
				frame.taken = true
			}
		} else {
			frame.emit = false
			if !preprocessor_skip_conditional_argument(
				preprocessor,
				cursor,
				kind,
				span,
			) {
				return false
			}
		}

	case .Endif:
		if len(preprocessor.cond_stack) == 0 {
			return preprocessor_error(
				preprocessor,
				span,
				"`#endif` without a matching `#if`",
			)
		}
		pop(&preprocessor.cond_stack)
		preprocess_cursor_next(cursor)
	}
	preprocessor_eat_directive_line_end(cursor)
	return true
}

preprocessor_parse_cursor_argument :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	span: Span,
) -> (argument: Token_List, ok: bool) {
	if cursor.curr.kind != .Lparen {
		_ = preprocessor_error(
			preprocessor,
			span,
			"parenthesized macro argument expected",
		)
		return {}, false
	}
	make_err: mem.Allocator_Error
	argument, make_err = token_list_make(8, preprocessor.allocator)
	if make_err != nil {
		_ = preprocessor_allocation_error(preprocessor, span)
		return {}, false
	}
	preprocess_cursor_next(cursor)
	depth := 1
	for {
		if cursor.curr.kind == .Eof {
			token_list_deinit(&argument, preprocessor.allocator)
			_ = preprocessor_error(
				preprocessor,
				span,
				"`)` expected to close a macro argument",
			)
			return {}, false
		}
		if cursor.curr.kind == .Lparen {
			depth += 1
		} else if cursor.curr.kind == .Rparen {
			depth -= 1
			if depth == 0 {
				preprocess_cursor_next(cursor)
				break
			}
		}
		if !preprocessor_append(preprocessor, &argument, cursor.curr) {
			token_list_deinit(&argument, preprocessor.allocator)
			return {}, false
		}
		preprocess_cursor_next(cursor)
	}
	return argument, true
}

preprocessor_expand_macro_cursor :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	name: string,
	span: Span,
	output: ^Token_List,
) -> bool {
	comptime_function, defined := preprocessor.comptime_fnt[name]
	if !defined {
		return preprocessor_errorf(
			preprocessor,
			span,
			"define it first with `#def #NAME {...}`",
			"macro `#%s` is not defined",
			name,
		)
	}

	preprocess_cursor_next(cursor)
	preprocessor_skip_whitespace(cursor)
	raw_args, raw_err := make(
		[dynamic]Token_List,
		0,
		comptime_function.params,
		preprocessor.allocator,
	)
	if raw_err != nil {
		return preprocessor_allocation_error(preprocessor, span)
	}
	defer {
		for &argument in raw_args {
			token_list_deinit(&argument, preprocessor.allocator)
		}
		delete(raw_args)
	}
	for _ in 0 ..< comptime_function.params {
		argument, argument_ok := preprocessor_parse_cursor_argument(
			preprocessor,
			cursor,
			span,
		)
		if !argument_ok {
			return false
		}
		if _, append_err := append(&raw_args, argument); append_err != nil {
			token_list_deinit(&argument, preprocessor.allocator)
			return preprocessor_allocation_error(preprocessor, span)
		}
	}

	resolved_args, resolved_err := make(
		[dynamic]Token_List,
		0,
		comptime_function.params,
		preprocessor.allocator,
	)
	if resolved_err != nil {
		return preprocessor_allocation_error(preprocessor, span)
	}
	defer {
		for &argument in resolved_args {
			token_list_deinit(&argument, preprocessor.allocator)
		}
		delete(resolved_args)
	}
	for raw_argument in raw_args {
		resolved_argument, make_err := token_list_make(
			len(raw_argument.items),
			preprocessor.allocator,
		)
		if make_err != nil {
			return preprocessor_allocation_error(preprocessor, span)
		}
		if !preprocessor_expand_tokens(
			preprocessor,
			raw_argument.items[:],
			nil,
			&resolved_argument,
		) {
			token_list_deinit(&resolved_argument, preprocessor.allocator)
			return false
		}
		for resolved_token in resolved_argument.items {
			if resolved_token.kind != .BuiltinFunction {
				continue
			}
			resolved_name := resolved_token.builtin_name
			if token_is_builtin(resolved_name) {
				continue
			}
			_, known_macro := preprocessor.comptime_fnt[resolved_name]
			if !known_macro {
				token_list_deinit(&resolved_argument, preprocessor.allocator)
				return preprocessor_errorf(
					preprocessor,
					resolved_token.span,
					"define it before using it in a macro argument",
					"macro `#%s` is not defined",
					resolved_name,
				)
			}
		}
		if _, append_err := append(&resolved_args, resolved_argument); append_err != nil {
			token_list_deinit(&resolved_argument, preprocessor.allocator)
			return preprocessor_allocation_error(preprocessor, span)
		}
	}

	return preprocessor_expand_tokens(
		preprocessor,
		comptime_function.contents.items[:],
		resolved_args[:],
		output,
	)
}

preprocessor_define :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
) -> bool {
	definition_span := cursor.curr.span
	preprocess_cursor_next(cursor)
	preprocessor_skip_whitespace(cursor)
	if cursor.curr.kind != .BuiltinFunction {
		return preprocessor_error(
			preprocessor,
			cursor.curr.span,
			"macro name expected after `#def`",
			"write it as `#def #NAME {...}`",
		)
	}
	name := cursor.curr.builtin_name
	if preprocessor_is_builtin(name) {
		return preprocessor_errorf(
			preprocessor,
			definition_span,
			"built-in functions cannot be overridden",
			"cannot define reserved builtin `#%s`",
			name,
		)
	}
	preprocess_cursor_next(cursor)
	preprocessor_skip_whitespace(cursor)
	if cursor.curr.kind != .Lbrace {
		return preprocessor_error(
			preprocessor,
			cursor.curr.span,
			"`{` expected to start a macro body",
		)
	}
	preprocess_cursor_next(cursor)

	contents, make_err := token_list_make(16, preprocessor.allocator)
	if make_err != nil {
		return preprocessor_allocation_error(preprocessor, definition_span)
	}
	contents_owned := true
	defer {
		if contents_owned {
			token_list_deinit(&contents, preprocessor.allocator)
		}
	}
	params := 0
	depth := 1
	for {
		if cursor.curr.kind == .Eof {
			return preprocessor_error(
				preprocessor,
				definition_span,
				"unexpected end of file inside `#def` body",
			)
		}
		if cursor.curr.kind == .Lbrace {
			depth += 1
		} else if cursor.curr.kind == .Rbrace {
			depth -= 1
			if depth == 0 {
				break
			}
		}
		if cursor.curr.kind == .BuiltinFunction {
			builtin_name := cursor.curr.builtin_name
			if token_is_preprocess_builtin(builtin_name) {
				return preprocessor_errorf(
					preprocessor,
					cursor.curr.span,
					"preprocessor directives are not valid inside macro bodies",
					"directive `#%s` is not allowed in this macro body",
					builtin_name,
				)
			}
			if parameter, is_parameter := token_is_function_param(builtin_name); is_parameter {
				if parameter == 0 {
					return preprocessor_error(
						preprocessor,
						cursor.curr.span,
						"macro parameter `#0` is invalid",
					)
				}
				params = max(params, int(parameter))
			}
		}
		if !preprocessor_append(preprocessor, &contents, cursor.curr) {
			return false
		}
		preprocess_cursor_next(cursor)
	}

	// Consume `}` and one directive line ending, exactly as `#def` does in
	// the Zig implementation.
	preprocess_cursor_next(cursor)
	had_horizontal_space := false
	for cursor.curr.kind == .Space || cursor.curr.kind == .Tab {
		had_horizontal_space = true
		preprocess_cursor_next(cursor)
	}
	if !had_horizontal_space && cursor.curr.kind == .Newline {
		preprocess_cursor_next(cursor)
		// Zig's preprocessor advances once more after the directive callback.
		// With an immediate line ending, its callback has already walked onto
		// the following line's indentation, so that outer advance drops it.
		// This cursor loop uses `continue` instead; consume the indentation here
		// to preserve the same (observable) output.
		preprocessor_skip_whitespace(cursor)
	}

	if old, exists := &preprocessor.comptime_fnt[name]; exists {
		token_list_deinit(&old.contents, preprocessor.allocator)
	}
	preprocessor.comptime_fnt[name] = Comptime_Function{
		params = params,
		contents = contents,
	}
	contents_owned = false
	return true
}

preprocessor_undefine :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
) -> bool {
	span := cursor.curr.span
	preprocess_cursor_next(cursor)
	preprocessor_skip_whitespace(cursor)
	if cursor.curr.kind != .BuiltinFunction {
		return preprocessor_error(
			preprocessor,
			cursor.curr.span,
			"macro name expected after `#undef`",
		)
	}
	name := cursor.curr.builtin_name
	if preprocessor_is_builtin(name) {
		return preprocessor_errorf(
			preprocessor,
			span,
			"built-in functions cannot be undefined",
			"cannot undefine reserved builtin `#%s`",
			name,
		)
	}
	comptime_function, exists := &preprocessor.comptime_fnt[name]
	if !exists {
		return preprocessor_errorf(
			preprocessor,
			span,
			"only previously defined macros may be undefined",
			"macro `#%s` is not defined",
			name,
		)
	}
	preprocess_cursor_next(cursor)
	preprocessor_skip_whitespace(cursor)
	if cursor.curr.kind != .Newline {
		return preprocessor_error(
			preprocessor,
			cursor.curr.span,
			"newline expected after `#undef`",
		)
	}
	token_list_deinit(&comptime_function.contents, preprocessor.allocator)
	delete_key(&preprocessor.comptime_fnt, name)
	preprocess_cursor_next(cursor)
	return true
}

preprocessor_append_mode_command :: proc(
	preprocessor: ^Preprocessor,
	output: ^Token_List,
	span: Span,
	command: string,
) -> bool {
	return preprocessor_append(
		preprocessor,
		output,
		token_make_same_literal(.Newline, "\n", span.start, span.end),
	) && preprocessor_append(
		preprocessor,
		output,
		token_make_same_literal(.LatexFunction, command, span.start, span.end),
	) && preprocessor_append(
		preprocessor,
		output,
		token_make_same_literal(.Newline, "\n", span.start, span.end),
	)
}

preprocessor_mode_directive :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	output: ^Token_List,
	name: string,
) -> bool {
	span := cursor.curr.span
	command := ""
	switch name {
	case "at_on":
		cursor.lexer.make_at_letter = true
		command = "\\makeatletter"
	case "at_off":
		cursor.lexer.make_at_letter = false
		command = "\\makeatother"
	case "ltx3_on":
		if !preprocessor.allow_latex3 {
			return preprocessor_error(
				preprocessor,
				span,
				"`#ltx3_on` is disabled by `#noltx3`",
				"remove `#noltx3` to use this directive",
			)
		}
		cursor.lexer.is_latex3_on = true
		command = "\\ExplSyntaxOn"
	case "ltx3_off":
		if !preprocessor.allow_latex3 {
			return preprocessor_error(
				preprocessor,
				span,
				"`#ltx3_off` is disabled by `#noltx3`",
				"remove `#noltx3` to use this directive",
			)
		}
		cursor.lexer.is_latex3_on = false
		command = "\\ExplSyntaxOff"
	case:
		return false
	}
	if !preprocessor_append_mode_command(preprocessor, output, span, command) {
		return false
	}
	preprocess_cursor_next(cursor)
	if cursor.curr.kind == .Space || cursor.curr.kind == .Tab {
		preprocess_cursor_next(cursor)
	}
	return true
}

preprocessor_disable_latex3 :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
) -> bool {
	if !preprocessor.is_premiere {
		return preprocessor_error(
			preprocessor,
			cursor.curr.span,
			"`#noltx3` is only valid in the preamble",
		)
	}
	preprocessor.allow_latex3 = false
	preprocess_cursor_next(cursor)
	if cursor.curr.kind == .Space || cursor.curr.kind == .Tab {
		preprocess_cursor_next(cursor)
	}
	return true
}

preprocessor_collect_include_path :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	span: Span,
) -> (path: string, ok: bool) {
	if cursor.curr.kind != .Lparen {
		_ = preprocessor_error(
			preprocessor,
			span,
			"`(` expected after `#include`",
		)
		return "", false
	}
	buffer := make([dynamic]u8, 0, 64, preprocessor.allocator) or_else nil
	if buffer == nil {
		_ = preprocessor_allocation_error(preprocessor, span)
		return "", false
	}
	defer delete(buffer)
	preprocess_cursor_next(cursor)
	depth := 1
	for {
		if cursor.curr.kind == .Eof {
			_ = preprocessor_error(
				preprocessor,
				span,
				"`)` expected to close the `#include` path",
			)
			return "", false
		}
		append_literal := true
		if cursor.curr.kind == .Lparen {
			depth += 1
			append_literal = false
		} else if cursor.curr.kind == .Rparen {
			depth -= 1
			append_literal = false
			if depth == 0 {
				preprocess_cursor_next(cursor)
				break
			}
		}
		if append_literal {
			if _, append_err := append(&buffer, cursor.curr.literal.in_text); append_err != nil {
				_ = preprocessor_allocation_error(preprocessor, span)
				return "", false
			}
		}
		preprocess_cursor_next(cursor)
	}
	trimmed := strings.trim(string(buffer[:]), " \t")
	if len(trimmed) == 0 {
		_ = preprocessor_error(preprocessor, span, "included file path cannot be empty")
		return "", false
	}
	cloned, clone_err := strings.clone(trimmed, preprocessor.allocator)
	if clone_err != nil {
		_ = preprocessor_allocation_error(preprocessor, span)
		return "", false
	}
	return cloned, true
}

preprocessor_home_directory :: proc(
	preprocessor: ^Preprocessor,
	span: Span,
) -> (string, bool) {
	variable := "HOME"
	when ODIN_OS == .Windows {
		variable = "USERPROFILE"
	}
	home, found := os.lookup_env(variable, preprocessor.allocator)
	if !found {
		_ = preprocessor_errorf(
			preprocessor,
			span,
			"set the home-directory environment variable",
			"environment variable `%s` is not defined",
			variable,
		)
		return "", false
	}
	return home, true
}

preprocessor_resolve_include_path :: proc(
	preprocessor: ^Preprocessor,
	raw_path: string,
	base_dir: string,
	span: Span,
) -> (canonical: string, ok: bool) {
	candidate := ""
	candidate_owned := false
	defer {
		if candidate_owned {
			delete(candidate, preprocessor.allocator)
		}
	}

	if strings.has_prefix(raw_path, "@/") || strings.has_prefix(raw_path, "@\\") {
		config_dir, config_ok := config_directory(preprocessor.allocator)
		if !config_ok {
			_ = preprocessor_error(
				preprocessor,
				span,
				"cannot resolve the Vesti configuration directory",
			)
			return "", false
		}
		defer delete(config_dir, preprocessor.allocator)
		joined, join_err := filepath.join(
			{config_dir, raw_path[2:]},
			preprocessor.allocator,
		)
		if join_err != nil {
			_ = preprocessor_allocation_error(preprocessor, span)
			return "", false
		}
		candidate = joined
		candidate_owned = true
	} else if strings.has_prefix(raw_path, "~") {
		home, home_ok := preprocessor_home_directory(preprocessor, span)
		if !home_ok {
			return "", false
		}
		defer delete(home, preprocessor.allocator)
		joined, join_err := strings.concatenate(
			{home, raw_path[1:]},
			preprocessor.allocator,
		)
		if join_err != nil {
			_ = preprocessor_allocation_error(preprocessor, span)
			return "", false
		}
		candidate = joined
		candidate_owned = true
	} else if filepath.is_abs(raw_path) {
		cloned, clone_err := strings.clone(raw_path, preprocessor.allocator)
		if clone_err != nil {
			_ = preprocessor_allocation_error(preprocessor, span)
			return "", false
		}
		candidate = cloned
		candidate_owned = true
	} else {
		joined, join_err := filepath.join(
			{base_dir, raw_path},
			preprocessor.allocator,
		)
		if join_err != nil {
			_ = preprocessor_allocation_error(preprocessor, span)
			return "", false
		}
		candidate = joined
		candidate_owned = true
	}

	absolute, absolute_err := filepath.abs(candidate, preprocessor.allocator)
	if absolute_err != nil {
		_ = preprocessor_errorf(
			preprocessor,
			span,
			"check that the include path is valid",
			"cannot resolve included path `%s`",
			raw_path,
		)
		return "", false
	}
	cleaned, clean_err := filepath.clean(absolute, preprocessor.allocator)
	delete(absolute, preprocessor.allocator)
	if clean_err != nil {
		_ = preprocessor_allocation_error(preprocessor, span)
		return "", false
	}
	return cleaned, true
}

preprocessor_paths_equal :: proc(left, right: string) -> bool {
	when ODIN_OS == .Windows {
		return strings.equal_fold(left, right)
	} else {
		return left == right
	}
}

preprocessor_include :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	base_dir: string,
	output: ^Token_List,
) -> bool {
	span := cursor.curr.span
	preprocess_cursor_next(cursor)
	preprocessor_skip_whitespace(cursor)
	raw_path, path_ok := preprocessor_collect_include_path(
		preprocessor,
		cursor,
		span,
	)
	if !path_ok {
		return false
	}
	defer delete(raw_path, preprocessor.allocator)
	canonical, resolve_ok := preprocessor_resolve_include_path(
		preprocessor,
		raw_path,
		base_dir,
		span,
	)
	if !resolve_ok {
		return false
	}

	for open_path in preprocessor.included_stack {
		if preprocessor_paths_equal(open_path, canonical) {
			delete(canonical, preprocessor.allocator)
			return preprocessor_errorf(
				preprocessor,
				span,
				"an included file cannot include itself recursively",
				"circular `#include` detected for `%s`",
				raw_path,
			)
		}
	}

	bytes, read_err := os.read_entire_file(canonical, preprocessor.allocator)
	if read_err != nil {
		delete(canonical, preprocessor.allocator)
		return preprocessor_errorf(
			preprocessor,
			span,
			"check that the file exists and is readable",
			"failed to read included file `%s`",
			raw_path,
		)
	}
	source := string(bytes)
	if _, append_err := append(&preprocessor.included_sources, source); append_err != nil {
		delete(source, preprocessor.allocator)
		delete(canonical, preprocessor.allocator)
		return preprocessor_allocation_error(preprocessor, span)
	}
	if _, append_err := append(&preprocessor.included_stack, canonical); append_err != nil {
		// included_sources now owns source and will release it on failure.
		delete(canonical, preprocessor.allocator)
		return preprocessor_allocation_error(preprocessor, span)
	}
	defer {
		popped_path := pop(&preprocessor.included_stack)
		delete(popped_path, preprocessor.allocator)
	}

	included_cursor := preprocess_cursor_init(source)
	included_base := filepath.dir(canonical)
	return preprocessor_process_cursor(
		preprocessor,
		&included_cursor,
		included_base,
		output,
	)
}

preprocessor_process_cursor :: proc(
	preprocessor: ^Preprocessor,
	cursor: ^Preprocess_Cursor,
	base_dir: string,
	output: ^Token_List,
) -> bool {
	for cursor.curr.kind != .Eof {
		if cursor.curr.kind == .BuiltinFunction {
			if cond_kind, is_conditional := preprocessor_cond_kind(
				cursor.curr.builtin_name,
			); is_conditional {
				if !preprocessor_handle_conditional(preprocessor, cursor, cond_kind) {
					return false
				}
				continue
			}
		}

		if !preprocessor_emitting(preprocessor) {
			preprocess_cursor_next(cursor)
			continue
		}

		if cursor.curr.kind == .BuiltinFunction {
			name := cursor.curr.builtin_name
			switch name {
			case "at_on", "at_off", "ltx3_on", "ltx3_off":
				if !preprocessor_mode_directive(preprocessor, cursor, output, name) {
					return false
				}
				continue
			case "noltx3":
				if !preprocessor_disable_latex3(preprocessor, cursor) {
					return false
				}
				continue
			case "def":
				if !preprocessor_define(preprocessor, cursor) {
					return false
				}
				continue
			case "undef":
				if !preprocessor_undefine(preprocessor, cursor) {
					return false
				}
				continue
			case "include":
				if !preprocessor_include(preprocessor, cursor, base_dir, output) {
					return false
				}
				continue
			case:
			}

			if token_is_builtin(name) {
				if !preprocessor_append(preprocessor, output, cursor.curr) {
					return false
				}
				preprocess_cursor_next(cursor)
				continue
			}
			if _, is_parameter := token_is_function_param(name); is_parameter {
				if !preprocessor_append(preprocessor, output, cursor.curr) {
					return false
				}
				preprocess_cursor_next(cursor)
				continue
			}
			if !preprocessor_expand_macro_cursor(
				preprocessor,
				cursor,
				name,
				cursor.curr.span,
				output,
			) {
				return false
			}
			continue
		}

		if cursor.curr.kind == .StartDoc {
			preprocessor.is_premiere = false
		}
		if !preprocessor_append(preprocessor, output, cursor.curr) {
			return false
		}
		preprocess_cursor_next(cursor)
	}
	return true
}

// The successful Token_List is self-contained except for the borrowed root
// source. It may outlive Preprocessor because included sources are transferred
// into Token_List. Call token_list_deinit with the initialization allocator.
preprocessor_process :: proc(preprocessor: ^Preprocessor) -> (tokens: Token_List, ok: bool) {
	if preprocessor == nil {
		return {}, false
	}
	if preprocessor.processed {
		_ = preprocessor_error(
			preprocessor,
			span_init(),
			"a Preprocessor instance can only be processed once",
		)
		return {}, false
	}
	preprocessor.processed = true
	output, make_err := token_list_make(128, preprocessor.allocator)
	if make_err != nil {
		_ = preprocessor_allocation_error(preprocessor)
		return {}, false
	}
	cursor := preprocess_cursor_init(preprocessor.source)
	if !preprocessor_process_cursor(
		preprocessor,
		&cursor,
		preprocessor.base_dir,
		&output,
	) {
		token_list_deinit(&output, preprocessor.allocator)
		return {}, false
	}
	if len(preprocessor.cond_stack) > 0 {
		open_span := preprocessor.cond_stack[len(preprocessor.cond_stack)-1].open_span
		token_list_deinit(&output, preprocessor.allocator)
		_ = preprocessor_error(
			preprocessor,
			open_span,
			"unterminated `#if` block; `#endif` expected",
		)
		return {}, false
	}
	if !preprocessor_append(preprocessor, &output, token_eof(cursor.curr.span)) {
		token_list_deinit(&output, preprocessor.allocator)
		return {}, false
	}
	output.owned_sources = preprocessor.included_sources
	preprocessor.included_sources = nil
	return output, true
}

package main

import "core:fmt"
import "core:mem"
import "core:strings"

// Lua is deliberately kept behind this callback until the Lua runtime itself
// is ported.  A nil callback has the same behaviour as passing null for Lua to
// the Zig code generator: Lua_Code_Stmt nodes produce no output.
Codegen_Lua_Evaluator :: #type proc(
	code: string,
	output: ^strings.Builder,
	user_data: rawptr,
) -> bool

Codegen_Lua_Export :: struct {
	label: string,
	code:  Byte_Buffer,
}

Codegen :: struct {
	allocator:     mem.Allocator,
	source:        string,
	stmts:         []Stmt,
	diagnostic:    ^Diagnostic,
	is_main:       bool,
	lua_evaluator: Codegen_Lua_Evaluator,
	lua_user_data: rawptr,
	lua_exports:   [dynamic]Codegen_Lua_Export,
}

codegen_init :: proc(
	allocator: mem.Allocator,
	source: string,
	stmts: []Stmt,
	is_main: bool,
	diagnostic: ^Diagnostic,
	lua_evaluator: Codegen_Lua_Evaluator = nil,
	lua_user_data: rawptr = nil,
) -> Codegen {
	assert(diagnostic != nil)
	return Codegen{
		allocator      = allocator,
		source         = source,
		stmts          = stmts,
		diagnostic     = diagnostic,
		is_main        = is_main,
		lua_evaluator  = lua_evaluator,
		lua_user_data  = lua_user_data,
		lua_exports    = make([dynamic]Codegen_Lua_Export, allocator),
	}
}

codegen_deinit :: proc(generator: ^Codegen) {
	if generator == nil {
		return
	}
	for &item in generator.lua_exports {
		if item.code != nil {
			delete(item.code)
		}
	}
	if generator.lua_exports != nil {
		delete(generator.lua_exports)
	}
	generator.lua_exports = nil
}

// codegen_emit appends generated TeX to output.  placeholder is the optional
// global-definition list inserted by Placeholder_Stmt.
codegen_emit :: proc(
	generator: ^Codegen,
	placeholder: ^Stmt_List,
	output: ^strings.Builder,
) -> bool {
	assert(generator != nil)
	assert(output != nil)
	return _codegen_stmts(generator, generator.stmts, placeholder, output)
}

// codegen is the convenient one-shot form for callers that do not need Lua.
codegen :: proc(
	stmts: []Stmt,
	placeholder: ^Stmt_List,
	output: ^strings.Builder,
	diagnostic: ^Diagnostic,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	generator := codegen_init(allocator, "", stmts, false, diagnostic)
	defer codegen_deinit(&generator)
	return codegen_emit(&generator, placeholder, output)
}

_codegen_write :: proc(output: ^strings.Builder, value: string) {
	_ = strings.write_string(output, value)
}

_codegen_write_byte :: proc(output: ^strings.Builder, value: byte) {
	_ = strings.write_byte(output, value)
}

_codegen_write_uint :: proc(output: ^strings.Builder, value: uint) {
	_ = fmt.sbprintf(output, "%d", value)
}

_codegen_write_cow :: proc(output: ^strings.Builder, value: Cow_Str) {
	_codegen_write(output, cow_str_string(value))
}

_codegen_write_options :: proc(output: ^strings.Builder, options: Maybe(Cow_Str_List)) {
	values, present := options.?
	if !present {
		return
	}
	_codegen_write_byte(output, '[')
	for option, index in values {
		if index > 0 {
			_codegen_write_byte(output, ',')
		}
		_codegen_write_cow(output, option)
	}
	_codegen_write_byte(output, ']')
}

_codegen_stmts :: proc(
	generator: ^Codegen,
	stmts: []Stmt,
	placeholder: ^Stmt_List,
	output: ^strings.Builder,
) -> bool {
	for stmt in stmts {
		if !_codegen_stmt(generator, stmt, placeholder, output) {
			return false
		}
	}
	return true
}

_codegen_args :: proc(
	generator: ^Codegen,
	args: []Arg,
	placeholder: ^Stmt_List,
	output: ^strings.Builder,
) -> bool {
	for arg in args {
		switch arg.needed {
		case .Main_Arg:
			_codegen_write_byte(output, '{')
			if !_codegen_stmts(generator, arg.ctx[:], placeholder, output) do return false
			_codegen_write_byte(output, '}')
		case .Optional:
			_codegen_write_byte(output, '[')
			if !_codegen_stmts(generator, arg.ctx[:], placeholder, output) do return false
			_codegen_write_byte(output, ']')
		case .Star_Arg:
			_codegen_write_byte(output, '*')
		}
	}
	return true
}

_codegen_find_lua_export :: proc(
	generator: ^Codegen,
	label: string,
) -> (^Codegen_Lua_Export, bool) {
	for &item in generator.lua_exports {
		if item.label == label {
			return &item, true
		}
	}
	return nil, false
}

_codegen_lua :: proc(
	generator: ^Codegen,
	block: Lua_Code_Stmt,
	output: ^strings.Builder,
) -> bool {
	if generator.lua_evaluator == nil {
		return true
	}

	combined := strings.builder_make(allocator = generator.allocator)
	defer strings.builder_destroy(&combined)

	if imports, present := block.code_import.?; present {
		for label in imports {
			exported, found := _codegen_find_lua_export(generator, label)
			if !found {
				_ = diagnostic_setf(
					generator.diagnostic,
					.Lua,
					block.code_span,
					true,
					"labels should be declared before they are used",
					"label `%s` is not found",
					label,
				)
				return false
			}
			_codegen_write(&combined, string(exported.code[:]))
			_codegen_write_byte(&combined, '\n')
		}
	}
	_codegen_write(&combined, string(block.code[:]))

	if export_label, present := block.code_export.?; present {
		if _, found := _codegen_find_lua_export(generator, export_label); found {
			_ = diagnostic_setf(
				generator.diagnostic,
				.Lua,
				block.code_span,
				true,
				"",
				"label `%s` is duplicated",
				export_label,
			)
			return false
		}
		combined_code := strings.to_string(combined)
		stored := make(Byte_Buffer, 0, len(combined_code), generator.allocator)
		append(&stored, combined_code)
		append(&generator.lua_exports, Codegen_Lua_Export{label = export_label, code = stored})
		return true
	}

	evaluated := strings.builder_make(allocator = generator.allocator)
	defer strings.builder_destroy(&evaluated)
	if !generator.lua_evaluator(
		strings.to_string(combined),
		&evaluated,
		generator.lua_user_data,
	) {
		_ = diagnostic_set(
			generator.diagnostic,
			.Lua,
			"lua exception occurred: failed to run luacode",
			block.code_span,
			true,
			"see the Lua error message above",
		)
		return false
	}
	_codegen_write(output, strings.to_string(evaluated))
	return true
}

_codegen_stmt :: proc(
	generator: ^Codegen,
	stmt: Stmt,
	placeholder: ^Stmt_List,
	output: ^strings.Builder,
) -> bool {
	switch value in stmt {
	case Nop_Stmt:
		return true
	case Placeholder_Stmt:
		_codegen_write(output, "\n%%%    Global Definitions\n")
		if placeholder != nil {
			if !_codegen_stmts(generator, placeholder^[:], placeholder, output) do return false
		}
		_codegen_write(output, "\n%%%    End Global Definitions\n")
	case Text_Lit_Stmt:
		_codegen_write_cow(output, value.text)
	case Math_Lit_Stmt:
		_codegen_write(output, value.text)
	case Math_Ctx_Stmt:
		start, end: string
		switch value.state {
		case .Inline:  start, end = "$", "$"
		case .Display: start, end = "\\[", "\\]"
		case .Labeled: start, end = "\\begin{equation}", "\\end{equation}"
		}
		_codegen_write(output, start)
		if label, present := value.label.?; present {
			_codegen_write(output, "\\label{")
			_codegen_write(output, string(label[:]))
			_codegen_write_byte(output, '}')
		}
		if !_codegen_stmts(generator, value.inner[:], placeholder, output) do return false
		_codegen_write(output, end)
	case Braced_Stmt:
		if !value.unwrap_brace do _codegen_write_byte(output, '{')
		if !_codegen_stmts(generator, value.inner[:], placeholder, output) do return false
		if !value.unwrap_brace do _codegen_write_byte(output, '}')
	case Fraction_Stmt:
		_codegen_write(output, "\\frac{")
		if !_codegen_stmts(generator, value.numerator[:], placeholder, output) do return false
		_codegen_write(output, "}{")
		if !_codegen_stmts(generator, value.denominator[:], placeholder, output) do return false
		_codegen_write_byte(output, '}')
	case Document_Start_Stmt:
		_codegen_write(output, "\n\\begin{document}")
	case Document_End_Stmt:
		_codegen_write(output, "\n\\end{document}\n")
	case Document_Class_Stmt:
		_codegen_write(output, "\\documentclass")
		_codegen_write_options(output, value.options)
		_codegen_write_byte(output, '{')
		_codegen_write_cow(output, value.name)
		_codegen_write(output, "}\n\\usepackage{amstext}\n")
	case Import_Single_Pkg_Stmt:
		_codegen_write(output, "\\usepackage")
		_codegen_write_options(output, value.pkg.options)
		_codegen_write_byte(output, '{')
		_codegen_write_cow(output, value.pkg.name)
		_codegen_write(output, "}\n")
	case Import_Multiple_Pkgs_Stmt:
		for pkg in value.packages {
			_codegen_write(output, "\\usepackage")
			_codegen_write_options(output, pkg.options)
			_codegen_write_byte(output, '{')
			_codegen_write_cow(output, pkg.name)
			_codegen_write(output, "}\n")
		}
	case Import_Vesti_Stmt:
		_codegen_write(output, "\\input{")
		_codegen_write(output, string(value.name[:]))
		_codegen_write_byte(output, '}')
	case Plain_Text_In_Math_Stmt:
		_codegen_write(output, "\\text{")
		if value.add_front_space do _codegen_write_byte(output, ' ')
		if !_codegen_stmts(generator, value.inner[:], placeholder, output) do return false
		if value.add_back_space do _codegen_write_byte(output, ' ')
		_codegen_write_byte(output, '}')
	case Math_Delimiter_Stmt:
		switch value.kind {
		case .None:      _codegen_write(output, value.delimiter)
		case .Left_Big:
			_codegen_write(output, "\\left")
			_codegen_write(output, value.delimiter)
		case .Right_Big:
			_codegen_write(output, "\\right")
			_codegen_write(output, value.delimiter)
		}
	case Defun_Param_List_Stmt:
		if value.nested >= uint(size_of(uint)*8) {
			_ = diagnostic_setf(
				generator.diagnostic,
				.Parse,
				value.span,
				true,
				"",
				"2 to the power of %d exceeds max value of 2^%d",
				value.nested,
				size_of(uint),
			)
			return false
		}
		count := uint(1) << value.nested
		for index := uint(0); index < count; index += 1 {
			_codegen_write_byte(output, '#')
		}
		_codegen_write_uint(output, value.arg_num)
	case Define_Function_Stmt:
		name := cow_str_string(value.name)
		param: Maybe(string)
		if param_value, present := value.param_str.?; present {
			param = cow_str_string(param_value)
		}
		_ = defun_kind_write_prologue(value.kind, name, output)
		_ = defun_kind_write_param(value.kind, param, output)

		body := strings.builder_make(allocator = generator.allocator)
		if !_codegen_stmts(generator, value.inner[:], placeholder, &body) {
			strings.builder_destroy(&body)
			return false
		}
		body_text := strings.to_string(body)
		if defun_kind_trim_left(value.kind) do body_text = strings.trim_left(body_text, " \t\r\n")
		if defun_kind_trim_right(value.kind) do body_text = strings.trim_right(body_text, " \t\r\n")
		_codegen_write(output, body_text)
		strings.builder_destroy(&body)
		_ = defun_kind_write_epilogue(value.kind, name, output)
	case Define_Env_Stmt:
		name := cow_str_string(value.name)
		param: Maybe(string)
		if param_value, present := value.param_str.?; present {
			param = cow_str_string(param_value)
		}
		_ = defenv_kind_write_prologue(value.kind, name, output)
		_ = defenv_kind_write_param(value.kind, param, output)

		begin_body := strings.builder_make(allocator = generator.allocator)
		if !_codegen_stmts(generator, value.inner_begin[:], placeholder, &begin_body) {
			strings.builder_destroy(&begin_body)
			return false
		}
		begin_text := strings.to_string(begin_body)
		if defenv_kind_begin_trim_left(value.kind) do begin_text = strings.trim_left(begin_text, " \t\r\n")
		if defenv_kind_begin_trim_right(value.kind) do begin_text = strings.trim_right(begin_text, " \t\r\n")
		_codegen_write(output, begin_text)
		strings.builder_destroy(&begin_body)
		_codegen_write(output, "}{")

		end_body := strings.builder_make(allocator = generator.allocator)
		if !_codegen_stmts(generator, value.inner_end[:], placeholder, &end_body) {
			strings.builder_destroy(&end_body)
			return false
		}
		end_text := strings.to_string(end_body)
		if defenv_kind_end_trim_left(value.kind) do end_text = strings.trim_left(end_text, " \t\r\n")
		if defenv_kind_end_trim_right(value.kind) do end_text = strings.trim_right(end_text, " \t\r\n")
		_codegen_write(output, end_text)
		strings.builder_destroy(&end_body)
		_ = defenv_kind_write_epilogue(value.kind, output)
	case Environment_Stmt:
		_codegen_write(output, "\\begin{")
		_codegen_write_cow(output, value.name)
		_codegen_write_byte(output, '}')
		if !_codegen_args(generator, value.args[:], placeholder, output) do return false
		if label, present := value.label.?; present {
			_codegen_write(output, "\\label{")
			_codegen_write(output, string(label[:]))
			_codegen_write_byte(output, '}')
		}
		if !_codegen_stmts(generator, value.inner[:], placeholder, output) do return false
		_codegen_write(output, "\\end{")
		_codegen_write_cow(output, value.name)
		_codegen_write_byte(output, '}')
	case Picture_Environment_Stmt:
		if unit_length, present := value.unit_length.?; present {
			_codegen_write(output, "\\setlength{\\unitlength}{")
			_codegen_write(output, string(unit_length[:]))
			_codegen_write(output, "}\n")
		}
		_codegen_write(output, "\\begin{picture}(")
		_codegen_write_uint(output, value.width)
		_codegen_write_byte(output, ',')
		_codegen_write_uint(output, value.height)
		_codegen_write_byte(output, ')')
		if xoffset, present := value.xoffset.?; present {
			yoffset, has_yoffset := value.yoffset.?
			assert(has_yoffset)
			_codegen_write_byte(output, '(')
			_codegen_write_uint(output, xoffset)
			_codegen_write_byte(output, ',')
			_codegen_write_uint(output, yoffset)
			_codegen_write_byte(output, ')')
		}
		if !_codegen_stmts(generator, value.inner[:], placeholder, output) do return false
		_codegen_write(output, "\\end{picture}")
	case Begin_Phantom_Environ_Stmt:
		_codegen_write(output, "\\begin{")
		_codegen_write_cow(output, value.name)
		_codegen_write_byte(output, '}')
		if !_codegen_args(generator, value.args[:], placeholder, output) do return false
		if value.add_newline do _codegen_write_byte(output, '\n')
	case End_Phantom_Environ_Stmt:
		_codegen_write(output, "\\end{")
		_codegen_write_cow(output, value.name)
		_codegen_write_byte(output, '}')
	case File_Path_Stmt:
		_codegen_write_cow(output, value.path)
	case Lua_Code_Stmt:
		return _codegen_lua(generator, value, output)
	}
	return true
}

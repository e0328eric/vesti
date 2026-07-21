package main

import "core:strings"

// Defun_Kind controls both the TeX primitive used for a function definition
// and the whitespace policy applied to its generated body.
Defun_Kind :: struct {
	redef:      bool,
	declare:    bool,
	provide:    bool,
	expand:     bool,
	global:     bool,
	xparse:     bool,
	keep_left_whitespace:  bool,
	keep_right_whitespace: bool,
}

// Defenv_Kind controls the xparse environment constructor and independently
// tracks whitespace trimming for the begin and end bodies.
Defenv_Kind :: struct {
	redef:            bool,
	provide:          bool,
	declare:          bool,
	keep_begin_left_whitespace:  bool,
	keep_begin_right_whitespace: bool,
	keep_end_left_whitespace:    bool,
	keep_end_right_whitespace:   bool,
}

// Trim settings use inverted storage so the useful defaults remain the zero
// value, just like DefunKind{} and DefenvKind{} in the Zig implementation.
defun_kind_trim_left  :: proc(kind: Defun_Kind) -> bool { return !kind.keep_left_whitespace }
defun_kind_trim_right :: proc(kind: Defun_Kind) -> bool { return !kind.keep_right_whitespace }

defenv_kind_begin_trim_left  :: proc(kind: Defenv_Kind) -> bool { return !kind.keep_begin_left_whitespace }
defenv_kind_begin_trim_right :: proc(kind: Defenv_Kind) -> bool { return !kind.keep_begin_right_whitespace }
defenv_kind_end_trim_left    :: proc(kind: Defenv_Kind) -> bool { return !kind.keep_end_left_whitespace }
defenv_kind_end_trim_right   :: proc(kind: Defenv_Kind) -> bool { return !kind.keep_end_right_whitespace }

// defun_kind_is_valid implements the combinations accepted by the Zig port:
// primitive definitions may freely combine r/!/e/g, while xparse definitions
// allow at most one of new/renew/provide/declare and may be expandable.
defun_kind_is_valid :: proc(kind: Defun_Kind) -> bool {
	if !kind.xparse {
		return !kind.provide
	}
	if kind.global {
		return false
	}

	mode_count := 0
	if kind.redef   { mode_count += 1 }
	if kind.provide { mode_count += 1 }
	if kind.declare { mode_count += 1 }
	return mode_count <= 1
}

// Like the Zig parser, this applies flags as they are read.  A false result
// therefore leaves output containing any flags consumed before the failure.
defun_kind_parse :: proc(output: ^Defun_Kind, text: string, is_xparse: bool) -> bool {
	assert(output != nil)
	for char in text {
		switch char {
		case 'r', 'R': output.redef = true
		case 'p', 'P': output.provide = true
		case '!':      output.declare = true
		case 'e', 'E': output.expand = true
		case 'g', 'G': output.global = true
		case '<':      output.keep_left_whitespace = true
		case '>':      output.keep_right_whitespace = true
		case:          return false
		}
	}
	output.xparse = is_xparse
	return defun_kind_is_valid(output^)
}

parse_defun_kind :: proc(text: string, is_xparse: bool) -> (kind: Defun_Kind, ok: bool) {
	ok = defun_kind_parse(&kind, text, is_xparse)
	return
}

defenv_kind_is_valid :: proc(kind: Defenv_Kind) -> bool {
	mode_count := 0
	if kind.redef   { mode_count += 1 }
	if kind.provide { mode_count += 1 }
	if kind.declare { mode_count += 1 }
	return mode_count <= 1
}

// As with defun_kind_parse, flags consumed before an error remain in output.
defenv_kind_parse :: proc(output: ^Defenv_Kind, text: string) -> bool {
	assert(output != nil)
	for char in text {
		switch char {
		case 'r', 'R': output.redef = true
		case 'p', 'P': output.provide = true
		case '!':      output.declare = true
		case '<':      output.keep_begin_left_whitespace = true
		case '>':      output.keep_begin_right_whitespace = true
		case '(':      output.keep_end_left_whitespace = true
		case ')':      output.keep_end_right_whitespace = true
		case:          return false
		}
	}
	return defenv_kind_is_valid(output^)
}

parse_defenv_kind :: proc(text: string) -> (kind: Defenv_Kind, ok: bool) {
	ok = defenv_kind_parse(&kind, text)
	return
}

_defun_xparse_command :: proc(kind: Defun_Kind) -> string {
	if kind.expand {
		if kind.redef   { return "\\RenewExpandableDocumentCommand" }
		if kind.provide { return "\\ProvideExpandableDocumentCommand" }
		if kind.declare { return "\\DeclareExpandableDocumentCommand" }
		return "\\NewExpandableDocumentCommand"
	}
	if kind.redef   { return "\\RenewDocumentCommand" }
	if kind.provide { return "\\ProvideDocumentCommand" }
	if kind.declare { return "\\DeclareDocumentCommand" }
	return "\\NewDocumentCommand"
}

_defun_primitive_command :: proc(kind: Defun_Kind, builder: ^strings.Builder) {
	if !kind.declare {
		_ = strings.write_string(builder, "\\protected")
	}
	if kind.global {
		if kind.expand {
			_ = strings.write_string(builder, "\\xdef")
		} else {
			_ = strings.write_string(builder, "\\gdef")
		}
	} else {
		if kind.expand {
			_ = strings.write_string(builder, "\\edef")
		} else {
			_ = strings.write_string(builder, "\\def")
		}
	}
}

// defun_kind_write_prologue appends the TeX prefix for a function definition.
// name does not include the leading backslash.
defun_kind_write_prologue :: proc(kind: Defun_Kind, name: string, builder: ^strings.Builder) -> int {
	assert(builder != nil)
	assert(defun_kind_is_valid(kind))
	start := strings.builder_len(builder^)

	if kind.xparse {
		_ = strings.write_string(builder, _defun_xparse_command(kind))
		_ = strings.write_string(builder, "{\\")
		_ = strings.write_string(builder, name)
		_ = strings.write_byte(builder, '}')
		return strings.builder_len(builder^) - start
	}

	if !kind.redef {
		_ = strings.write_string(builder, "\\expandafter\\ifx\\csname ")
		_ = strings.write_string(builder, name)
		_ = strings.write_string(builder, "\\endcsname\\relax\n")
	}
	_defun_primitive_command(kind, builder)
	_ = strings.write_byte(builder, '\\')
	_ = strings.write_string(builder, name)
	return strings.builder_len(builder^) - start
}

// defun_kind_write_param opens the function body, including an xparse
// parameter specification when applicable.
defun_kind_write_param :: proc(kind: Defun_Kind, param_str: Maybe(string), builder: ^strings.Builder) -> int {
	assert(builder != nil)
	start := strings.builder_len(builder^)
	if kind.xparse {
		_ = strings.write_byte(builder, '{')
		if param, ok := param_str.?; ok {
			_ = strings.write_string(builder, param)
		}
		_ = strings.write_string(builder, "}{")
	} else {
		if param, ok := param_str.?; ok {
			_ = strings.write_string(builder, param)
		}
		_ = strings.write_byte(builder, '{')
	}
	return strings.builder_len(builder^) - start
}

defun_kind_write_epilogue :: proc(kind: Defun_Kind, name: string, builder: ^strings.Builder) -> int {
	assert(builder != nil)
	start := strings.builder_len(builder^)
	if !kind.redef && !kind.xparse {
		_ = strings.write_string(builder, "}%\n\\else\\errmessage{")
		_ = strings.write_string(builder, name)
		_ = strings.write_string(builder, " is already defined}\\fi\n")
	} else {
		_ = strings.write_string(builder, "}%\n")
	}
	return strings.builder_len(builder^) - start
}

_defenv_command :: proc(kind: Defenv_Kind) -> string {
	if kind.redef   { return "\\RenewDocumentEnvironment" }
	if kind.provide { return "\\ProvideDocumentEnvironment" }
	if kind.declare { return "\\DeclareDocumentEnvironment" }
	return "\\NewDocumentEnvironment"
}

defenv_kind_write_prologue :: proc(kind: Defenv_Kind, name: string, builder: ^strings.Builder) -> int {
	assert(builder != nil)
	assert(defenv_kind_is_valid(kind))
	start := strings.builder_len(builder^)
	_ = strings.write_string(builder, _defenv_command(kind))
	_ = strings.write_byte(builder, '{')
	_ = strings.write_string(builder, name)
	_ = strings.write_byte(builder, '}')
	return strings.builder_len(builder^) - start
}

// Environment definitions always use xparse parameter syntax.
defenv_kind_write_param :: proc(kind: Defenv_Kind, param_str: Maybe(string), builder: ^strings.Builder) -> int {
	_ = kind
	assert(builder != nil)
	start := strings.builder_len(builder^)
	_ = strings.write_byte(builder, '{')
	if param, ok := param_str.?; ok {
		_ = strings.write_string(builder, param)
	}
	_ = strings.write_string(builder, "}{")
	return strings.builder_len(builder^) - start
}

defenv_kind_write_epilogue :: proc(kind: Defenv_Kind, builder: ^strings.Builder) -> int {
	_ = kind
	assert(builder != nil)
	return strings.write_string(builder, "}%\n")
}

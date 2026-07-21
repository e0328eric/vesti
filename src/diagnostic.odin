package main

import "core:fmt"
import "core:mem"
import "core:strings"

// Diagnostic is the single owned error slot used throughout the compiler.
// Keeping it payload-agnostic avoids the Parser <-> Compiler package cycle in
// the Zig implementation while preserving its user-facing source diagnostics.
Diagnostic_Kind :: enum {
	None,
	Parse,
	IO,
	Lua,
	Backend,
}

Diagnostic :: struct {
	allocator:          mem.Allocator,
	kind:               Diagnostic_Kind,
	message:            string,
	note:               string,
	absolute_filename:  string,
	source:             string,
	span:               Span,
	has_span:           bool,
	owns_message:       bool,
	owns_note:          bool,
	owns_filename:      bool,
	owns_source:        bool,
	lock_print_at_main: bool,
}

diagnostic_init :: proc(allocator := context.allocator) -> Diagnostic {
	return Diagnostic{allocator = allocator}
}

diagnostic_free_string :: proc(value: string, owned: bool, allocator: mem.Allocator) {
	if owned && len(value) > 0 {
		delete(value, allocator)
	}
}

diagnostic_clear_error :: proc(diagnostic: ^Diagnostic) {
	diagnostic_free_string(diagnostic.message, diagnostic.owns_message, diagnostic.allocator)
	diagnostic_free_string(diagnostic.note, diagnostic.owns_note, diagnostic.allocator)
	diagnostic.kind = .None
	diagnostic.message = ""
	diagnostic.note = ""
	diagnostic.span = {}
	diagnostic.has_span = false
	diagnostic.owns_message = false
	diagnostic.owns_note = false
}

diagnostic_deinit :: proc(diagnostic: ^Diagnostic) {
	diagnostic_clear_error(diagnostic)
	diagnostic_free_string(
		diagnostic.absolute_filename,
		diagnostic.owns_filename,
		diagnostic.allocator,
	)
	diagnostic_free_string(diagnostic.source, diagnostic.owns_source, diagnostic.allocator)
	diagnostic.absolute_filename = ""
	diagnostic.source = ""
	diagnostic.owns_filename = false
	diagnostic.owns_source = false
}

diagnostic_replace_owned :: proc(
	destination: ^string,
	owned: ^bool,
	value: string,
	allocator: mem.Allocator,
) -> bool {
	diagnostic_free_string(destination^, owned^, allocator)
	copy, err := strings.clone(value, allocator)
	if err != nil {
		destination^ = ""
		owned^ = false
		return false
	}
	destination^ = copy
	owned^ = true
	return true
}

diagnostic_set_metadata :: proc(
	diagnostic: ^Diagnostic,
	absolute_filename: string,
	source: string,
) -> bool {
	if !diagnostic_replace_owned(
		&diagnostic.absolute_filename,
		&diagnostic.owns_filename,
		absolute_filename,
		diagnostic.allocator,
	) {
		return false
	}
	if !diagnostic_replace_owned(
		&diagnostic.source,
		&diagnostic.owns_source,
		source,
		diagnostic.allocator,
	) {
		return false
	}
	return true
}

diagnostic_set :: proc(
	diagnostic: ^Diagnostic,
	kind: Diagnostic_Kind,
	message: string,
	span: Span = {},
	has_span := false,
	note := "",
) -> bool {
	diagnostic_clear_error(diagnostic)
	diagnostic.kind = kind
	diagnostic.span = span
	diagnostic.has_span = has_span
	if !diagnostic_replace_owned(
		&diagnostic.message,
		&diagnostic.owns_message,
		message,
		diagnostic.allocator,
	) {
		return false
	}
	if len(note) > 0 {
		if !diagnostic_replace_owned(
			&diagnostic.note,
			&diagnostic.owns_note,
			note,
			diagnostic.allocator,
		) {
			return false
		}
	}
	return true
}

diagnostic_setf :: proc(
	diagnostic: ^Diagnostic,
	kind: Diagnostic_Kind,
	span: Span,
	has_span: bool,
	note: string,
	format: string,
	args: ..any,
) -> bool {
	message := fmt.aprintf(format, ..args, allocator = diagnostic.allocator)
	defer delete(message, diagnostic.allocator)
	return diagnostic_set(diagnostic, kind, message, span, has_span, note)
}

diagnostic_line_at :: proc(source: string, row: int) -> string {
	if row < 1 {
		return ""
	}
	line_start := 0
	current_row := 1
	for index := 0; index <= len(source); index += 1 {
		at_end := index == len(source)
		if at_end || source[index] == '\n' {
			if current_row == row {
				line_end := index
				if line_end > line_start && source[line_end-1] == '\r' {
					line_end -= 1
				}
				return source[line_start:line_end]
			}
			line_start = index + 1
			current_row += 1
		}
	}
	return ""
}

diagnostic_pretty_print :: proc(diagnostic: ^Diagnostic, no_color := false) {
	if diagnostic.kind == .None {
		return
	}

	filename := diagnostic.absolute_filename
	if len(filename) == 0 {
		filename = "^.^"
	}

	use_color := !no_color
	ERROR_PREFIX :: "\x1b[1;31merror:\x1b[0m"
	NOTE_PREFIX  :: "\x1b[1;36mnote:\x1b[0m"
	error_prefix := "error:"
	note_prefix := "note:"
	if use_color {
		error_prefix = ERROR_PREFIX
		note_prefix = NOTE_PREFIX
	}

	if diagnostic.has_span && len(diagnostic.source) > 0 {
		line := diagnostic_line_at(diagnostic.source, diagnostic.span.start.row)
		fmt.eprintf(
			"%s:%d:%d: %s %s\n    %s\n",
			filename,
			diagnostic.span.start.row,
			diagnostic.span.start.col,
			error_prefix,
			diagnostic.message,
			line,
		)

		underline_count := diagnostic.span.end.col - diagnostic.span.start.col
		if underline_count < 1 {
			underline_count = 1
		}
		fmt.eprintf("    ")
		for _ in 1 ..< diagnostic.span.start.col {
			fmt.eprintf(" ")
		}
		for _ in 0 ..< underline_count {
			fmt.eprintf("^")
		}
		fmt.eprintf("\n")
	} else {
		fmt.eprintf("%s: %s %s\n", filename, error_prefix, diagnostic.message)
	}

	if len(diagnostic.note) > 0 {
		fmt.eprintf("%s %s\n", note_prefix, diagnostic.note)
	}
}

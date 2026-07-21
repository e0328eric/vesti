package main

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

Data_Format :: enum u8 {
	JSON,
	YAML,
	TOML,
	MessagePack,
}

Data_Parse_Error :: enum u8 {
	None,
	Invalid_Syntax,
	Trailing_Content,
	Unsupported_Value,
	Out_Of_Memory,
}

Data_File_Error :: enum u8 {
	None,
	Not_Found,
	Ambiguous,
	Path_Error,
}

Data_File :: struct {
	path:   string,
	format: Data_Format,
}

Data_File_Candidate :: struct {
	suffix: string,
	format: Data_Format,
}

DATA_FILE_CANDIDATES :: [?]Data_File_Candidate{
	{".json",     .JSON},
	{".yaml",     .YAML},
	{".yml",      .YAML},
	{".toml",     .TOML},
	{".msgpack",  .MessagePack},
}

data_format_name :: proc(format: Data_Format) -> string {
	switch format {
	case .JSON:        return "JSON"
	case .YAML:        return "YAML"
	case .TOML:        return "TOML"
	case .MessagePack: return "MessagePack"
	}
	return "data"
}

data_parse_error_string :: proc(err: Data_Parse_Error) -> string {
	switch err {
	case .None:              return "none"
	case .Invalid_Syntax:    return "invalid syntax"
	case .Trailing_Content:  return "trailing content"
	case .Unsupported_Value: return "unsupported value"
	case .Out_Of_Memory:     return "out of memory"
	}
	return "invalid data"
}

// Returns an owned path when exactly one supported <stem>.<extension> exists.
data_find_file :: proc(
	directory, stem: string,
	allocator: mem.Allocator = context.allocator,
) -> (file: Data_File, err: Data_File_Error) {
	for candidate in DATA_FILE_CANDIDATES {
		base_name, base_err := strings.concatenate(
			{stem, candidate.suffix},
			allocator,
		)
		if base_err != nil {
			if len(file.path) != 0 do delete(file.path, allocator)
			return {}, .Path_Error
		}
		name, name_err := filepath.join(
			{directory, base_name},
			allocator,
		)
		delete(base_name, allocator)
		if name_err != nil {
			if len(file.path) != 0 do delete(file.path, allocator)
			return {}, .Path_Error
		}
		if !os.is_file(name) {
			delete(name, allocator)
			continue
		}
		if len(file.path) != 0 {
			delete(name, allocator)
			delete(file.path, allocator)
			return {}, .Ambiguous
		}
		file = {path = name, format = candidate.format}
	}
	if len(file.path) == 0 {
		return {}, .Not_Found
	}
	return file, .None
}

data_has_json_trailing_comma :: proc(contents: string) -> bool {
	in_string := false
	escaped := false
	for character, index in contents {
		if in_string {
			if escaped {
				escaped = false
			} else if character == '\\' {
				escaped = true
			} else if character == '"' {
				in_string = false
			}
			continue
		}
		if character == '"' {
			in_string = true
			continue
		}
		if character != ',' do continue
		next := index + 1
		for next < len(contents) &&
			(contents[next] == ' ' || contents[next] == '\t' ||
			 contents[next] == '\r' || contents[next] == '\n') {
			next += 1
		}
		if next < len(contents) && (contents[next] == '}' || contents[next] == ']') {
			return true
		}
	}
	return false
}

data_parse_json :: proc(
	contents: string,
	allocator: mem.Allocator = context.allocator,
) -> (json.Value, Data_Parse_Error) {
	// The core JSON parser routes a few error-cleanup paths through the current
	// context allocator even though the parser itself stores an allocator.
	context.allocator = allocator
	if data_has_json_trailing_comma(contents) {
		return {}, .Invalid_Syntax
	}
	parser := json.make_parser_from_string(
		contents,
		.JSON,
		parse_integers = true,
		allocator = allocator,
	)
	value, parse_err := json.parse_value(&parser)
	if parse_err != .None {
		if parse_err == .Out_Of_Memory do return {}, .Out_Of_Memory
		return {}, .Invalid_Syntax
	}
	if parser.curr_token.kind != .EOF {
		json.destroy_value(value, allocator)
		return {}, .Trailing_Content
	}
	return value, .None
}

data_parse :: proc(
	contents: string,
	format: Data_Format,
	allocator: mem.Allocator = context.allocator,
) -> (json.Value, Data_Parse_Error) {
	switch format {
	case .JSON:        return data_parse_json(contents, allocator)
	case .YAML:        return data_parse_yaml(contents, allocator)
	case .TOML:        return data_parse_toml(contents, allocator)
	case .MessagePack: return data_parse_messagepack(contents, allocator)
	}
	return {}, .Invalid_Syntax
}

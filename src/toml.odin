package main

import "core:encoding/json"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

Toml_Table_Kind :: enum u8 {
	Implicit,
	Dotted,
	Explicit,
	Inline,
	Array_Table,
	Value,
}

Toml_Value_Context :: enum u8 {
	Statement,
	Array,
	Inline,
}

Toml_Key_Path :: [dynamic]string

Toml_Parser :: struct {
	contents:         string,
	position:         int,
	allocator:        mem.Allocator,
	root:             json.Object,
	current:          ^json.Object,
	current_identity: string,
	states:           map[string]Toml_Table_Kind,
}

toml_is_inline_space :: proc(character: u8) -> bool {
	return character == ' ' || character == '\t'
}

toml_is_line_end :: proc(character: u8) -> bool {
	return character == '\r' || character == '\n'
}

toml_is_bare_key_character :: proc(character: u8) -> bool {
	return character >= 'a' && character <= 'z' ||
	       character >= 'A' && character <= 'Z' ||
	       character >= '0' && character <= '9' ||
	       character == '_' || character == '-'
}

toml_skip_inline_space :: proc(parser: ^Toml_Parser) {
	for parser.position < len(parser.contents) &&
	    toml_is_inline_space(parser.contents[parser.position]) {
		parser.position += 1
	}
}

toml_consume_line_end :: proc(parser: ^Toml_Parser) -> bool {
	if parser.position >= len(parser.contents) do return false
	if parser.contents[parser.position] == '\n' {
		parser.position += 1
		return true
	}
	if parser.contents[parser.position] == '\r' &&
	   parser.position + 1 < len(parser.contents) &&
	   parser.contents[parser.position + 1] == '\n' {
		parser.position += 2
		return true
	}
	return false
}

toml_skip_comment :: proc(parser: ^Toml_Parser) {
	if parser.position >= len(parser.contents) || parser.contents[parser.position] != '#' {
		return
	}
	for parser.position < len(parser.contents) &&
	    !toml_is_line_end(parser.contents[parser.position]) {
		parser.position += 1
	}
}

toml_skip_document_space :: proc(parser: ^Toml_Parser) -> bool {
	for {
		toml_skip_inline_space(parser)
		if parser.position < len(parser.contents) && parser.contents[parser.position] == '#' {
			toml_skip_comment(parser)
		}
		if parser.position >= len(parser.contents) do return true
		if !toml_consume_line_end(parser) {
			return !toml_is_line_end(parser.contents[parser.position])
		}
	}
}

toml_finish_statement :: proc(parser: ^Toml_Parser) -> bool {
	toml_skip_inline_space(parser)
	if parser.position < len(parser.contents) && parser.contents[parser.position] == '#' {
		toml_skip_comment(parser)
	}
	if parser.position >= len(parser.contents) do return true
	return toml_consume_line_end(parser)
}

toml_clone :: proc(parser: ^Toml_Parser, value: string) -> (string, Data_Parse_Error) {
	cloned, err := strings.clone(value, parser.allocator)
	if err != nil do return "", .Out_Of_Memory
	return cloned, .None
}

toml_path_child :: proc(
	parser: ^Toml_Parser,
	base, segment: string,
) -> (string, Data_Parse_Error) {
	if len(base) == 0 do return toml_clone(parser, segment)
	joined, err := strings.concatenate({base, "\x1f", segment}, parser.allocator)
	if err != nil do return "", .Out_Of_Memory
	return joined, .None
}

toml_path_index :: proc(
	parser: ^Toml_Parser,
	base: string,
	index: int,
) -> (string, Data_Parse_Error) {
	buffer: [32]byte
	index_text := strconv.write_int(buffer[:], i64(index), 10)
	joined, err := strings.concatenate({base, "\x1e", index_text}, parser.allocator)
	if err != nil do return "", .Out_Of_Memory
	return joined, .None
}

toml_state_set :: proc(
	parser: ^Toml_Parser,
	path: string,
	kind: Toml_Table_Kind,
) -> Data_Parse_Error {
	if _, found := parser.states[path]; found {
		parser.states[path] = kind
		return .None
	}
	owned, clone_err := toml_clone(parser, path)
	if clone_err != .None do return clone_err
	parser.states[owned] = kind
	return .None
}

toml_key_path_destroy :: proc(path: ^Toml_Key_Path, allocator: mem.Allocator) {
	for segment in path^ do delete(segment, allocator)
	delete(path^)
	path^ = nil
}

toml_append_byte :: proc(builder: ^strings.Builder, value: u8) -> bool {
	return strings.write_byte(builder, value) == 1
}

toml_hex_value :: proc(character: u8) -> (u32, bool) {
	if character >= '0' && character <= '9' do return u32(character - '0'), true
	if character >= 'a' && character <= 'f' do return u32(character - 'a' + 10), true
	if character >= 'A' && character <= 'F' do return u32(character - 'A' + 10), true
	return 0, false
}

toml_parse_basic_string :: proc(
	parser: ^Toml_Parser,
) -> (string, Data_Parse_Error) {
	if parser.position >= len(parser.contents) || parser.contents[parser.position] != '"' {
		return "", .Invalid_Syntax
	}
	parser.position += 1
	builder, builder_err := strings.builder_make(parser.allocator)
	if builder_err != nil do return "", .Out_Of_Memory
	defer strings.builder_destroy(&builder)

	for parser.position < len(parser.contents) {
		character := parser.contents[parser.position]
		parser.position += 1
		if character == '"' {
			return toml_clone(parser, strings.to_string(builder))
		}
		if character < 0x20 || character == 0x7f {
			return "", .Invalid_Syntax
		}
		if character != '\\' {
			if !toml_append_byte(&builder, character) do return "", .Out_Of_Memory
			continue
		}
		if parser.position >= len(parser.contents) do return "", .Invalid_Syntax
		escape := parser.contents[parser.position]
		parser.position += 1
		switch escape {
		case 'b': if !toml_append_byte(&builder, '\b') do return "", .Out_Of_Memory
		case 't': if !toml_append_byte(&builder, '\t') do return "", .Out_Of_Memory
		case 'n': if !toml_append_byte(&builder, '\n') do return "", .Out_Of_Memory
		case 'f': if !toml_append_byte(&builder, '\f') do return "", .Out_Of_Memory
		case 'r': if !toml_append_byte(&builder, '\r') do return "", .Out_Of_Memory
		case '"': if !toml_append_byte(&builder, '"') do return "", .Out_Of_Memory
		case '\\': if !toml_append_byte(&builder, '\\') do return "", .Out_Of_Memory
		case 'u', 'U':
			digit_count := escape == 'u' ? 4 : 8
			if parser.position + digit_count > len(parser.contents) {
				return "", .Invalid_Syntax
			}
			codepoint: u32
			for _ in 0 ..< digit_count {
				digit, ok := toml_hex_value(parser.contents[parser.position])
				if !ok do return "", .Invalid_Syntax
				codepoint = codepoint * 16 + digit
				parser.position += 1
			}
			if codepoint > 0x10ffff || codepoint >= 0xd800 && codepoint <= 0xdfff {
				return "", .Invalid_Syntax
			}
			encoded, width := utf8.encode_rune(rune(codepoint))
			if strings.write_bytes(&builder, encoded[:width]) != width {
				return "", .Out_Of_Memory
			}
		case:
			return "", .Invalid_Syntax
		}
	}
	return "", .Invalid_Syntax
}

toml_parse_literal_string :: proc(
	parser: ^Toml_Parser,
) -> (string, Data_Parse_Error) {
	if parser.position >= len(parser.contents) || parser.contents[parser.position] != '\'' {
		return "", .Invalid_Syntax
	}
	parser.position += 1
	start := parser.position
	for parser.position < len(parser.contents) {
		character := parser.contents[parser.position]
		if character == '\'' {
			value, clone_err := toml_clone(parser, parser.contents[start:parser.position])
			if clone_err != .None do return "", clone_err
			parser.position += 1
			return value, .None
		}
		if character < 0x20 || character == 0x7f {
			return "", .Invalid_Syntax
		}
		parser.position += 1
	}
	return "", .Invalid_Syntax
}

toml_parse_key_segment :: proc(
	parser: ^Toml_Parser,
) -> (string, Data_Parse_Error) {
	if parser.position >= len(parser.contents) do return "", .Invalid_Syntax
	switch parser.contents[parser.position] {
	case '"': return toml_parse_basic_string(parser)
	case '\'': return toml_parse_literal_string(parser)
	case:
		start := parser.position
		for parser.position < len(parser.contents) &&
		    toml_is_bare_key_character(parser.contents[parser.position]) {
			parser.position += 1
		}
		if parser.position == start do return "", .Invalid_Syntax
		return toml_clone(parser, parser.contents[start:parser.position])
	}
}

toml_parse_key_path :: proc(
	parser: ^Toml_Parser,
) -> (path: Toml_Key_Path, parse_err: Data_Parse_Error) {
	path = make(Toml_Key_Path, parser.allocator)
	for {
		toml_skip_inline_space(parser)
		segment, segment_err := toml_parse_key_segment(parser)
		if segment_err != .None {
			toml_key_path_destroy(&path, parser.allocator)
			return nil, segment_err
		}
		if _, append_err := append(&path, segment); append_err != nil {
			delete(segment, parser.allocator)
			toml_key_path_destroy(&path, parser.allocator)
			return nil, .Out_Of_Memory
		}
		toml_skip_inline_space(parser)
		if parser.position >= len(parser.contents) || parser.contents[parser.position] != '.' {
			break
		}
		parser.position += 1
	}
	return path, .None
}

toml_token_has_valid_underscores :: proc(token: string) -> bool {
	for character, index in token {
		if character != '_' do continue
		if index == 0 || index + 1 >= len(token) do return false
		before := token[index - 1]
		after := token[index + 1]
		if before < '0' || before > '9' || after < '0' || after > '9' do return false
	}
	return true
}

toml_without_underscores :: proc(
	parser: ^Toml_Parser,
	token: string,
) -> (string, Data_Parse_Error) {
	if !strings.contains(token, "_") do return toml_clone(parser, token)
	builder, builder_err := strings.builder_make(parser.allocator)
	if builder_err != nil do return "", .Out_Of_Memory
	defer strings.builder_destroy(&builder)
	for character in transmute([]u8)token {
		if character == '_' do continue
		if !toml_append_byte(&builder, character) do return "", .Out_Of_Memory
	}
	return toml_clone(parser, strings.to_string(builder))
}

toml_parse_integer_token :: proc(token: string) -> (json.Integer, bool) {
	if len(token) == 0 || !toml_token_has_valid_underscores(token) do return 0, false
	index := 0
	if token[index] == '+' || token[index] == '-' {
		index += 1
		if index >= len(token) do return 0, false
	}

	// TOML base-prefixed integers are unsigned; signed integers are decimal.
	if index == 0 && len(token) >= 3 && token[0] == '0' {
		base := 0
		switch token[1] {
		case 'x': base = 16
		case 'o': base = 8
		case 'b': base = 2
		}
		if base != 0 {
			unsigned, ok := strconv.parse_u64_of_base(token[2:], base)
			if !ok || unsigned > u64(max(i64)) do return 0, false
			return json.Integer(unsigned), true
		}
	}

	digits := token[index:]
	if len(digits) > 1 && digits[0] == '0' do return 0, false
	value, ok := strconv.parse_i64_of_base(token, 10)
	return json.Integer(value), ok
}

toml_is_datetime_token :: proc(token: string) -> bool {
	if len(token) >= 10 &&
	   token[0] >= '0' && token[0] <= '9' &&
	   token[1] >= '0' && token[1] <= '9' &&
	   token[2] >= '0' && token[2] <= '9' &&
	   token[3] >= '0' && token[3] <= '9' &&
	   token[4] == '-' && token[7] == '-' {
		for character in transmute([]u8)token {
			if character >= '0' && character <= '9' ||
			   character == '-' || character == ':' || character == '.' ||
			   character == '+' || character == 'T' || character == 't' ||
			   character == 'Z' || character == 'z' || character == ' ' {
				continue
			}
			return false
		}
		return true
	}
	if len(token) >= 8 && token[2] == ':' && token[5] == ':' {
		for character in transmute([]u8)token {
			if character >= '0' && character <= '9' || character == ':' || character == '.' {
				continue
			}
			return false
		}
		return true
	}
	return false
}

toml_parse_bare_value :: proc(
	parser: ^Toml_Parser,
	value_context: Toml_Value_Context,
) -> (json.Value, Data_Parse_Error) {
	start := parser.position
	for parser.position < len(parser.contents) {
		character := parser.contents[parser.position]
		if toml_is_line_end(character) || character == '#' do break
		if value_context == .Array && (character == ',' || character == ']') do break
		if value_context == .Inline && (character == ',' || character == '}') do break
		parser.position += 1
	}
	token := strings.trim_space(parser.contents[start:parser.position])
	if len(token) == 0 do return {}, .Invalid_Syntax
	if token == "true" do return json.Boolean(true), .None
	if token == "false" do return json.Boolean(false), .None

	if integer, integer_ok := toml_parse_integer_token(token); integer_ok {
		return integer, .None
	}
	if !toml_token_has_valid_underscores(token) do return {}, .Invalid_Syntax
	if token == "inf" || token == "+inf" || token == "-inf" ||
	   token == "nan" || token == "+nan" || token == "-nan" {
		return json.Float(0), .None
	}
	if strings.contains(token, ".") || strings.contains(token, "e") ||
	   strings.contains(token, "E") {
		normalized, normalize_err := toml_without_underscores(parser, token)
		if normalize_err != .None do return {}, normalize_err
		defer delete(normalized, parser.allocator)
		if number, number_ok := strconv.parse_f64(normalized); number_ok {
			return json.Float(number), .None
		}
	}
	if toml_is_datetime_token(token) {
		// JSON has no date/time variant. A non-string scalar preserves the
		// important schema behaviour: known string fields reject it, while
		// unknown valid TOML fields remain ignorable.
		return json.Float(0), .None
	}
	return {}, .Invalid_Syntax
}

toml_insert_value :: proc(
	parser: ^Toml_Parser,
	start_object: ^json.Object,
	start_identity: string,
	path: Toml_Key_Path,
	value: json.Value,
	value_is_inline: bool,
) -> Data_Parse_Error {
	object := start_object
	identity := start_identity
	owned_identity := ""
	defer if len(owned_identity) > 0 do delete(owned_identity, parser.allocator)

	for segment, index in path {
		child_identity, identity_err := toml_path_child(parser, identity, segment)
		if identity_err != .None {
			json.destroy_value(value, parser.allocator)
			return identity_err
		}
		if len(owned_identity) > 0 do delete(owned_identity, parser.allocator)
		owned_identity = child_identity
		identity = owned_identity

		is_final := index + 1 == len(path)
		raw_pointer, found := &object^[segment]
		if is_final {
			if found {
				json.destroy_value(value, parser.allocator)
				return .Invalid_Syntax
			}
			owned_key, clone_err := toml_clone(parser, segment)
			if clone_err != .None {
				json.destroy_value(value, parser.allocator)
				return clone_err
			}
			object^[owned_key] = value
			kind := value_is_inline ? Toml_Table_Kind.Inline : Toml_Table_Kind.Value
			return toml_state_set(parser, identity, kind)
		}

		if !found {
			child := make(json.Object, allocator=parser.allocator)
			owned_key, clone_err := toml_clone(parser, segment)
			if clone_err != .None {
				delete(child)
				json.destroy_value(value, parser.allocator)
				return clone_err
			}
			object^[owned_key] = child
			if state_err := toml_state_set(parser, identity, .Dotted); state_err != .None {
				json.destroy_value(value, parser.allocator)
				return state_err
			}
			inserted, inserted_ok := &object^[segment]
			if !inserted_ok {
				json.destroy_value(value, parser.allocator)
				return .Invalid_Syntax
			}
			object = &inserted^.(json.Object)
			continue
		}
		raw := raw_pointer^
		if _, object_ok := raw.(json.Object); object_ok {
			if kind, has_kind := parser.states[identity]; has_kind && kind == .Inline {
				json.destroy_value(value, parser.allocator)
				return .Invalid_Syntax
			}
			object = &raw_pointer^.(json.Object)
			continue
		}
		if array, array_ok := raw.(json.Array); array_ok {
			kind, has_kind := parser.states[identity]
			if !has_kind || kind != .Array_Table || len(array) == 0 {
				json.destroy_value(value, parser.allocator)
				return .Invalid_Syntax
			}
			_, table_ok := array[len(array) - 1].(json.Object)
			if !table_ok {
				json.destroy_value(value, parser.allocator)
				return .Invalid_Syntax
			}
			indexed, indexed_err := toml_path_index(parser, identity, len(array) - 1)
			if indexed_err != .None {
				json.destroy_value(value, parser.allocator)
				return indexed_err
			}
			delete(owned_identity, parser.allocator)
			owned_identity = indexed
			identity = indexed
			object = &raw_pointer^.(json.Array)[len(array) - 1].(json.Object)
			continue
		}
		json.destroy_value(value, parser.allocator)
		return .Invalid_Syntax
	}
	json.destroy_value(value, parser.allocator)
	return .Invalid_Syntax
}

toml_skip_array_space :: proc(parser: ^Toml_Parser) -> bool {
	for {
		toml_skip_inline_space(parser)
		if parser.position < len(parser.contents) && parser.contents[parser.position] == '#' {
			toml_skip_comment(parser)
		}
		if parser.position >= len(parser.contents) do return true
		if !toml_is_line_end(parser.contents[parser.position]) do return true
		if !toml_consume_line_end(parser) do return false
	}
}

toml_parse_value :: proc(
	parser: ^Toml_Parser,
	value_context: Toml_Value_Context,
) -> (value: json.Value, is_inline: bool, parse_err: Data_Parse_Error) {
	toml_skip_inline_space(parser)
	if parser.position >= len(parser.contents) do return {}, false, .Invalid_Syntax
	switch parser.contents[parser.position] {
	case '"':
		text, text_err := toml_parse_basic_string(parser)
		if text_err != .None do return {}, false, text_err
		return json.String(text), false, .None
	case '\'':
		text, text_err := toml_parse_literal_string(parser)
		if text_err != .None do return {}, false, text_err
		return json.String(text), false, .None
	case '[':
		parser.position += 1
		array := make(json.Array, parser.allocator)
		if !toml_skip_array_space(parser) {
			delete(array)
			return {}, false, .Invalid_Syntax
		}
		if parser.position < len(parser.contents) && parser.contents[parser.position] == ']' {
			parser.position += 1
			return array, false, .None
		}
		for {
			element, _, element_err := toml_parse_value(parser, .Array)
			if element_err != .None {
				json.destroy_value(array, parser.allocator)
				return {}, false, element_err
			}
			if _, append_err := append(&array, element); append_err != nil {
				json.destroy_value(element, parser.allocator)
				json.destroy_value(array, parser.allocator)
				return {}, false, .Out_Of_Memory
			}
			if !toml_skip_array_space(parser) {
				json.destroy_value(array, parser.allocator)
				return {}, false, .Invalid_Syntax
			}
			if parser.position >= len(parser.contents) {
				json.destroy_value(array, parser.allocator)
				return {}, false, .Invalid_Syntax
			}
			if parser.contents[parser.position] == ']' {
				parser.position += 1
				return array, false, .None
			}
			if parser.contents[parser.position] != ',' {
				json.destroy_value(array, parser.allocator)
				return {}, false, .Invalid_Syntax
			}
			parser.position += 1
			if !toml_skip_array_space(parser) {
				json.destroy_value(array, parser.allocator)
				return {}, false, .Invalid_Syntax
			}
			if parser.position < len(parser.contents) && parser.contents[parser.position] == ']' {
				parser.position += 1
				return array, false, .None
			}
		}
	case '{':
		inline_start := parser.position
		parser.position += 1
		object := make(json.Object, allocator=parser.allocator)
		buffer: [32]byte
		position_text := strconv.write_int(buffer[:], i64(inline_start), 10)
		identity, identity_err := strings.concatenate(
			{"\x1dinline", position_text},
			parser.allocator,
		)
		if identity_err != nil {
			delete(object)
			return {}, false, .Out_Of_Memory
		}
		defer delete(identity, parser.allocator)
		toml_skip_inline_space(parser)
		if parser.position < len(parser.contents) && parser.contents[parser.position] == '}' {
			parser.position += 1
			return object, true, .None
		}
		for {
			path, path_err := toml_parse_key_path(parser)
			if path_err != .None {
				json.destroy_value(object, parser.allocator)
				return {}, false, path_err
			}
			toml_skip_inline_space(parser)
			if parser.position >= len(parser.contents) || parser.contents[parser.position] != '=' {
				toml_key_path_destroy(&path, parser.allocator)
				json.destroy_value(object, parser.allocator)
				return {}, false, .Invalid_Syntax
			}
			parser.position += 1
			member, member_inline, member_err := toml_parse_value(parser, .Inline)
			if member_err != .None {
				toml_key_path_destroy(&path, parser.allocator)
				json.destroy_value(object, parser.allocator)
				return {}, false, member_err
			}
			insert_err := toml_insert_value(
				parser,
				&object,
				identity,
				path,
				member,
				member_inline,
			)
			toml_key_path_destroy(&path, parser.allocator)
			if insert_err != .None {
				json.destroy_value(object, parser.allocator)
				return {}, false, insert_err
			}
			toml_skip_inline_space(parser)
			if parser.position >= len(parser.contents) || toml_is_line_end(parser.contents[parser.position]) {
				json.destroy_value(object, parser.allocator)
				return {}, false, .Invalid_Syntax
			}
			if parser.contents[parser.position] == '}' {
				parser.position += 1
				return object, true, .None
			}
			if parser.contents[parser.position] != ',' {
				json.destroy_value(object, parser.allocator)
				return {}, false, .Invalid_Syntax
			}
			parser.position += 1
			toml_skip_inline_space(parser)
			// TOML inline tables do not permit a trailing comma.
			if parser.position >= len(parser.contents) || parser.contents[parser.position] == '}' {
				json.destroy_value(object, parser.allocator)
				return {}, false, .Invalid_Syntax
			}
		}
	case:
		bare, bare_err := toml_parse_bare_value(parser, value_context)
		return bare, false, bare_err
	}
}

toml_resolve_table :: proc(
	parser: ^Toml_Parser,
	path: Toml_Key_Path,
	is_array_table: bool,
) -> (^json.Object, string, Data_Parse_Error) {
	object := &parser.root
	identity := ""
	owned_identity := ""
	defer if len(owned_identity) > 0 do delete(owned_identity, parser.allocator)

	for segment, index in path {
		child_identity, identity_err := toml_path_child(parser, identity, segment)
		if identity_err != .None do return {}, "", identity_err
		if len(owned_identity) > 0 do delete(owned_identity, parser.allocator)
		owned_identity = child_identity
		identity = owned_identity
		is_final := index + 1 == len(path)
		raw_pointer, found := &object^[segment]
		raw: json.Value
		if found do raw = raw_pointer^

		if is_final && is_array_table {
			if found {
				_, array_ok := raw.(json.Array)
				kind, has_kind := parser.states[identity]
				if !array_ok || !has_kind || kind != .Array_Table {
					return nil, "", .Invalid_Syntax
				}
				array_pointer := &raw_pointer^.(json.Array)
				child := make(json.Object, allocator=parser.allocator)
				if _, append_err := append(array_pointer, json.Value(child)); append_err != nil {
					delete(child)
					return nil, "", .Out_Of_Memory
				}
				indexed, indexed_err := toml_path_index(parser, identity, len(array_pointer^) - 1)
				if indexed_err != .None do return nil, "", indexed_err
				return &array_pointer^[len(array_pointer^) - 1].(json.Object), indexed, .None
			}

			array := make(json.Array, parser.allocator)
			child := make(json.Object, allocator=parser.allocator)
			if _, append_err := append(&array, json.Value(child)); append_err != nil {
				delete(child)
				delete(array)
				return nil, "", .Out_Of_Memory
			}
			{
				owned_key, clone_err := toml_clone(parser, segment)
				if clone_err != .None {
					json.destroy_value(array, parser.allocator)
					return nil, "", clone_err
				}
				object^[owned_key] = array
				if state_err := toml_state_set(parser, identity, .Array_Table); state_err != .None {
					return nil, "", state_err
				}
			}
			indexed, indexed_err := toml_path_index(parser, identity, len(array) - 1)
			if indexed_err != .None do return nil, "", indexed_err
			inserted, inserted_ok := &object^[segment]
			if !inserted_ok do return nil, "", .Invalid_Syntax
			array_pointer := &inserted^.(json.Array)
			return &array_pointer^[len(array_pointer^) - 1].(json.Object), indexed, .None
		}

		if is_final {
			if found {
				_, object_ok := raw.(json.Object)
				if !object_ok do return nil, "", .Invalid_Syntax
				kind, has_kind := parser.states[identity]
				if !has_kind || kind != .Implicit do return nil, "", .Invalid_Syntax
				if state_err := toml_state_set(parser, identity, .Explicit); state_err != .None {
					return nil, "", state_err
				}
				result_identity, clone_err := toml_clone(parser, identity)
				if clone_err != .None do return nil, "", clone_err
				return &raw_pointer^.(json.Object), result_identity, .None
			}
			child := make(json.Object, allocator=parser.allocator)
			owned_key, clone_err := toml_clone(parser, segment)
			if clone_err != .None {
				delete(child)
				return nil, "", clone_err
			}
			object^[owned_key] = child
			if state_err := toml_state_set(parser, identity, .Explicit); state_err != .None {
				return nil, "", state_err
			}
			result_identity, result_err := toml_clone(parser, identity)
			if result_err != .None do return nil, "", result_err
			inserted, inserted_ok := &object^[segment]
			if !inserted_ok do return nil, "", .Invalid_Syntax
			return &inserted^.(json.Object), result_identity, .None
		}

		if !found {
			child := make(json.Object, allocator=parser.allocator)
			owned_key, clone_err := toml_clone(parser, segment)
			if clone_err != .None {
				delete(child)
				return nil, "", clone_err
			}
			object^[owned_key] = child
			if state_err := toml_state_set(parser, identity, .Implicit); state_err != .None {
				return nil, "", state_err
			}
			inserted, inserted_ok := &object^[segment]
			if !inserted_ok do return nil, "", .Invalid_Syntax
			object = &inserted^.(json.Object)
			continue
		}
		if _, object_ok := raw.(json.Object); object_ok {
			if kind, has_kind := parser.states[identity]; has_kind &&
			   (kind == .Inline || kind == .Value) {
				return nil, "", .Invalid_Syntax
			}
			object = &raw_pointer^.(json.Object)
			continue
		}
		if array, array_ok := raw.(json.Array); array_ok {
			kind, has_kind := parser.states[identity]
			if !has_kind || kind != .Array_Table || len(array) == 0 {
				return nil, "", .Invalid_Syntax
			}
			_, table_ok := array[len(array) - 1].(json.Object)
			if !table_ok do return nil, "", .Invalid_Syntax
			indexed, indexed_err := toml_path_index(parser, identity, len(array) - 1)
			if indexed_err != .None do return nil, "", indexed_err
			delete(owned_identity, parser.allocator)
			owned_identity = indexed
			identity = indexed
			object = &raw_pointer^.(json.Array)[len(array) - 1].(json.Object)
			continue
		}
		return nil, "", .Invalid_Syntax
	}
	return nil, "", .Invalid_Syntax
}

toml_parse_header :: proc(parser: ^Toml_Parser) -> Data_Parse_Error {
	if parser.position >= len(parser.contents) || parser.contents[parser.position] != '[' {
		return .Invalid_Syntax
	}
	parser.position += 1
	is_array_table := false
	if parser.position < len(parser.contents) && parser.contents[parser.position] == '[' {
		is_array_table = true
		parser.position += 1
	}
	path, path_err := toml_parse_key_path(parser)
	if path_err != .None do return path_err
	defer toml_key_path_destroy(&path, parser.allocator)
	toml_skip_inline_space(parser)
	if parser.position >= len(parser.contents) || parser.contents[parser.position] != ']' {
		return .Invalid_Syntax
	}
	parser.position += 1
	if is_array_table {
		if parser.position >= len(parser.contents) || parser.contents[parser.position] != ']' {
			return .Invalid_Syntax
		}
		parser.position += 1
	}
	if !toml_finish_statement(parser) do return .Invalid_Syntax

	table, identity, resolve_err := toml_resolve_table(parser, path, is_array_table)
	if resolve_err != .None do return resolve_err
	if len(parser.current_identity) > 0 do delete(parser.current_identity, parser.allocator)
	parser.current = table
	parser.current_identity = identity
	return .None
}

toml_parse_assignment :: proc(parser: ^Toml_Parser) -> Data_Parse_Error {
	path, path_err := toml_parse_key_path(parser)
	if path_err != .None do return path_err
	defer toml_key_path_destroy(&path, parser.allocator)
	toml_skip_inline_space(parser)
	if parser.position >= len(parser.contents) || parser.contents[parser.position] != '=' {
		return .Invalid_Syntax
	}
	parser.position += 1
	value, is_inline, value_err := toml_parse_value(parser, .Statement)
	if value_err != .None do return value_err
	if !toml_finish_statement(parser) {
		json.destroy_value(value, parser.allocator)
		return .Invalid_Syntax
	}
	return toml_insert_value(
		parser,
		parser.current,
		parser.current_identity,
		path,
		value,
		is_inline,
	)
}

toml_parser_destroy_metadata :: proc(parser: ^Toml_Parser) {
	if len(parser.current_identity) > 0 {
		delete(parser.current_identity, parser.allocator)
		parser.current_identity = ""
	}
	for key in parser.states do delete(key, parser.allocator)
	delete(parser.states)
	parser.states = nil
}

data_parse_toml :: proc(
	contents: string,
	allocator: mem.Allocator = context.allocator,
) -> (json.Value, Data_Parse_Error) {
	if !utf8.valid_string(contents) do return {}, .Invalid_Syntax
	parser := Toml_Parser{
		contents = contents,
		allocator = allocator,
		root = make(json.Object, allocator=allocator),
		states = make(map[string]Toml_Table_Kind, allocator=allocator),
	}
	parser.current = &parser.root
	defer toml_parser_destroy_metadata(&parser)

	if !toml_skip_document_space(&parser) {
		json.destroy_value(parser.root, allocator)
		return {}, .Invalid_Syntax
	}
	for parser.position < len(contents) {
		parse_err: Data_Parse_Error
		if parser.contents[parser.position] == '[' {
			parse_err = toml_parse_header(&parser)
		} else {
			parse_err = toml_parse_assignment(&parser)
		}
		if parse_err != .None {
			json.destroy_value(parser.root, allocator)
			return {}, parse_err
		}
		if !toml_skip_document_space(&parser) {
			json.destroy_value(parser.root, allocator)
			return {}, .Invalid_Syntax
		}
	}
	return parser.root, .None
}

@test
toml_parser_feature_test :: proc(t: ^testing.T) {
	value, parse_err := data_parse_toml(
		"title = 'literal'\n" +
		"lua.make_log = true\n" +
		"lua.line_limit = 72\n" +
		"values = [1, 2, { label = \"three\" },]\n" +
		"[lua.extra]\n" +
		"enabled = false\n" +
		"[[exports]]\n" +
		"name = \"one.ves\"\n" +
		"[[exports]]\n" +
		"name = \"two.ves\"\n",
	)
	if !testing.expect_value(t, parse_err, Data_Parse_Error.None) do return
	defer json.destroy_value(value)
	root, root_ok := value.(json.Object)
	if !testing.expect_value(t, root_ok, true) do return
	title, title_ok := root["title"].(json.String)
	if testing.expect_value(t, title_ok, true) {
		testing.expect_value(t, string(title), "literal")
	}
	lua, lua_ok := root["lua"].(json.Object)
	if testing.expect_value(t, lua_ok, true) {
		limit, limit_ok := lua["line_limit"].(json.Integer)
		if testing.expect_value(t, limit_ok, true) do testing.expect_value(t, limit, i64(72))
	}
	exports, exports_ok := root["exports"].(json.Array)
	if testing.expect_value(t, exports_ok, true) {
		testing.expect_value(t, len(exports), 2)
	}
}

@test
toml_parser_collision_test :: proc(t: ^testing.T) {
	invalid := [?]string{
		"a = 1\na = 2\n",
		"a = { b = 1 }\na.c = 2\n",
		"a = 1\n[a]\nb = 2\n",
		"a.b = 1\n[a]\nc = 2\n",
		"[a]\nb = 1\n[a]\nc = 2\n",
		"a = { b = 1, }\n",
		"a = [1 2]\n",
		"a = 1 trailing\n",
	}
	for source in invalid {
		value, parse_err := data_parse_toml(source)
		testing.expect(t, parse_err != .None)
		if parse_err == .None do json.destroy_value(value)
	}
}

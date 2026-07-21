package main

import "core:encoding/json"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

YAML_MAX_DEPTH :: 128

YAML_Line :: struct {
	indent: int,
	text:   string,
}

YAML_Parser :: struct {
	lines:     []YAML_Line,
	index:     int,
	allocator: mem.Allocator,
}

YAML_Flow_Parser :: struct {
	text:      string,
	position:  int,
	allocator: mem.Allocator,
}

yaml_is_space :: proc(character: byte) -> bool {
	return character == ' ' || character == '\t'
}

yaml_trim :: proc(value: string) -> string {
	return strings.trim(value, " \t")
}

yaml_valid_utf8 :: proc(value: string) -> bool {
	position := 0
	for position < len(value) {
		decoded, width := utf8.decode_rune_in_string(value[position:])
		if width == 0 {
			return false
		}
		if decoded == utf8.RUNE_ERROR && width == 1 && value[position] >= 0x80 {
			return false
		}
		position += width
	}
	return true
}

yaml_quote_may_start :: proc(line: string, position: int) -> bool {
	if position == 0 {
		return true
	}
	previous := position - 1
	for previous >= 0 && yaml_is_space(line[previous]) {
		previous -= 1
	}
	if previous < 0 {
		return true
	}
	switch line[previous] {
	case ':', '-', ',', '[', '{':
		return true
	}
	return false
}

// Returns the end of the YAML content before a comment. Quotes are tracked so
// that a '#' in a quoted scalar remains data.
yaml_comment_end :: proc(line: string) -> (int, bool) {
	single_quoted := false
	double_quoted := false
	escaped := false
	position := 0
	for position < len(line) {
		character := line[position]
		if double_quoted {
			if escaped {
				escaped = false
			} else if character == '\\' {
				escaped = true
			} else if character == '"' {
				double_quoted = false
			}
			position += 1
			continue
		}
		if single_quoted {
			if character == '\'' {
				if position + 1 < len(line) && line[position+1] == '\'' {
					position += 2
					continue
				}
				single_quoted = false
			}
			position += 1
			continue
		}
		if character == '"' && yaml_quote_may_start(line, position) {
			double_quoted = true
			position += 1
			continue
		}
		if character == '\'' && yaml_quote_may_start(line, position) {
			single_quoted = true
			position += 1
			continue
		}
		if character == '#' &&
		   (position == 0 || yaml_is_space(line[position-1])) {
			return position, true
		}
		position += 1
	}
	return len(line), !single_quoted && !double_quoted && !escaped
}

yaml_collect_lines :: proc(
	contents: string,
	allocator: mem.Allocator,
) -> (lines: [dynamic]YAML_Line, result: Data_Parse_Error) {
	if !yaml_valid_utf8(contents) {
		return nil, .Invalid_Syntax
	}

	make_error: mem.Allocator_Error
	lines, make_error = make([dynamic]YAML_Line, 0, 32, allocator)
	if make_error != nil {
		return nil, .Out_Of_Memory
	}

	source := contents
	if len(source) >= 3 &&
	   source[0] == 0xef && source[1] == 0xbb && source[2] == 0xbf {
		source = source[3:]
	}

	seen_start_marker := false
	seen_content := false
	seen_end_marker := false
	line_start := 0
	for line_start <= len(source) {
		line_end := line_start
		for line_end < len(source) && source[line_end] != '\n' {
			line_end += 1
		}
		raw_line := source[line_start:line_end]
		if len(raw_line) > 0 && raw_line[len(raw_line)-1] == '\r' {
			raw_line = raw_line[:len(raw_line)-1]
		}

		indent := 0
		for indent < len(raw_line) && raw_line[indent] == ' ' {
			indent += 1
		}
		if indent < len(raw_line) && raw_line[indent] == '\t' {
			delete(lines)
			return nil, .Invalid_Syntax
		}
		for character in raw_line {
			if character < 0x20 && character != '\t' {
				delete(lines)
				return nil, .Invalid_Syntax
			}
		}

		comment_end, quotes_ok := yaml_comment_end(raw_line)
		if !quotes_ok {
			delete(lines)
			return nil, .Invalid_Syntax
		}
		text := strings.trim_right(raw_line[indent:comment_end], " \t")
		if len(text) != 0 {
			if indent == 0 && text == "---" {
				if seen_start_marker || seen_content || seen_end_marker {
					delete(lines)
					return nil, .Invalid_Syntax
				}
				seen_start_marker = true
			} else if indent == 0 && text == "..." {
				if seen_end_marker {
					delete(lines)
					return nil, .Invalid_Syntax
				}
				seen_end_marker = true
			} else {
				if seen_end_marker {
					delete(lines)
					return nil, .Trailing_Content
				}
				if _, append_error := append(&lines, YAML_Line{indent, text});
				   append_error != nil {
					delete(lines)
					return nil, .Out_Of_Memory
				}
				seen_content = true
			}
		}

		if line_end == len(source) {
			break
		}
		line_start = line_end + 1
	}
	return lines, .None
}

yaml_is_sequence_line :: proc(text: string) -> bool {
	return text == "-" ||
		(len(text) > 1 && text[0] == '-' && yaml_is_space(text[1]))
}

yaml_find_mapping_colon :: proc(text: string) -> (int, bool) {
	single_quoted := false
	double_quoted := false
	escaped := false
	flow_depth := 0
	position := 0
	for position < len(text) {
		character := text[position]
		if double_quoted {
			if escaped {
				escaped = false
			} else if character == '\\' {
				escaped = true
			} else if character == '"' {
				double_quoted = false
			}
			position += 1
			continue
		}
		if single_quoted {
			if character == '\'' {
				if position + 1 < len(text) && text[position+1] == '\'' {
					position += 2
					continue
				}
				single_quoted = false
			}
			position += 1
			continue
		}
		switch character {
		case '"':
			double_quoted = true
		case '\'':
			single_quoted = true
		case '[', '{':
			flow_depth += 1
		case ']', '}':
			flow_depth -= 1
			if flow_depth < 0 do return 0, false
		case ':':
			if flow_depth == 0 &&
			   (position + 1 == len(text) || yaml_is_space(text[position+1])) {
				return position, true
			}
		}
		position += 1
	}
	return 0, false
}

yaml_hex_digit :: proc(character: byte) -> (u32, bool) {
	switch character {
	case '0'..='9': return u32(character - '0'), true
	case 'a'..='f': return u32(character - 'a' + 10), true
	case 'A'..='F': return u32(character - 'A' + 10), true
	}
	return 0, false
}

yaml_flow_skip_space :: proc(parser: ^YAML_Flow_Parser) {
	for parser.position < len(parser.text) &&
	    yaml_is_space(parser.text[parser.position]) {
		parser.position += 1
	}
}

yaml_clone_string :: proc(
	value: string,
	allocator: mem.Allocator,
) -> (string, Data_Parse_Error) {
	cloned, clone_error := strings.clone(value, allocator)
	if clone_error != nil {
		return "", .Out_Of_Memory
	}
	return cloned, .None
}

yaml_parse_quoted_string :: proc(
	parser: ^YAML_Flow_Parser,
) -> (string, Data_Parse_Error) {
	if parser.position >= len(parser.text) {
		return "", .Invalid_Syntax
	}
	quote := parser.text[parser.position]
	if quote != '\'' && quote != '"' {
		return "", .Invalid_Syntax
	}
	parser.position += 1

	builder, builder_error := strings.builder_make(0, 32, parser.allocator)
	if builder_error != nil {
		return "", .Out_Of_Memory
	}
	defer strings.builder_destroy(&builder)

	for parser.position < len(parser.text) {
		character := parser.text[parser.position]
		if quote == '\'' {
			if character == '\'' {
				if parser.position + 1 < len(parser.text) &&
				   parser.text[parser.position+1] == '\'' {
					if strings.write_byte(&builder, '\'') != 1 {
						return "", .Out_Of_Memory
					}
					parser.position += 2
					continue
				}
				parser.position += 1
				return yaml_clone_string(strings.to_string(builder), parser.allocator)
			}
			if character < 0x20 {
				return "", .Invalid_Syntax
			}
			if strings.write_byte(&builder, character) != 1 {
				return "", .Out_Of_Memory
			}
			parser.position += 1
			continue
		}

		if character == '"' {
			parser.position += 1
			return yaml_clone_string(strings.to_string(builder), parser.allocator)
		}
		if character != '\\' {
			if character < 0x20 {
				return "", .Invalid_Syntax
			}
			if strings.write_byte(&builder, character) != 1 {
				return "", .Out_Of_Memory
			}
			parser.position += 1
			continue
		}

		parser.position += 1
		if parser.position >= len(parser.text) {
			return "", .Invalid_Syntax
		}
		escape := parser.text[parser.position]
		parser.position += 1
		switch escape {
		case '0':
			if strings.write_byte(&builder, 0) != 1 do return "", .Out_Of_Memory
		case 'a':
			if strings.write_byte(&builder, 0x07) != 1 do return "", .Out_Of_Memory
		case 'b':
			if strings.write_byte(&builder, 0x08) != 1 do return "", .Out_Of_Memory
		case 't', '\t':
			if strings.write_byte(&builder, '\t') != 1 do return "", .Out_Of_Memory
		case 'n':
			if strings.write_byte(&builder, '\n') != 1 do return "", .Out_Of_Memory
		case 'v':
			if strings.write_byte(&builder, 0x0b) != 1 do return "", .Out_Of_Memory
		case 'f':
			if strings.write_byte(&builder, 0x0c) != 1 do return "", .Out_Of_Memory
		case 'r':
			if strings.write_byte(&builder, '\r') != 1 do return "", .Out_Of_Memory
		case 'e':
			if strings.write_byte(&builder, 0x1b) != 1 do return "", .Out_Of_Memory
		case ' ', '"', '/', '\\':
			if strings.write_byte(&builder, escape) != 1 do return "", .Out_Of_Memory
		case 'N', '_', 'L', 'P':
			decoded: rune
			switch escape {
			case 'N': decoded = '\u0085'
			case '_': decoded = '\u00a0'
			case 'L': decoded = '\u2028'
			case 'P': decoded = '\u2029'
			}
			if _, write_error := strings.write_rune(&builder, decoded);
			   write_error != nil {
				return "", .Out_Of_Memory
			}
		case 'x', 'u', 'U':
			digits := 2
			if escape == 'u' do digits = 4
			if escape == 'U' do digits = 8
			if parser.position + digits > len(parser.text) {
				return "", .Invalid_Syntax
			}
			codepoint: u32
			for index in 0..<digits {
				digit, digit_ok := yaml_hex_digit(parser.text[parser.position+index])
				if !digit_ok {
					return "", .Invalid_Syntax
				}
				codepoint = codepoint * 16 + digit
			}
			parser.position += digits
			if codepoint > 0x10ffff ||
			   (codepoint >= 0xd800 && codepoint <= 0xdfff) {
				return "", .Invalid_Syntax
			}
			if _, write_error := strings.write_rune(&builder, rune(codepoint));
			   write_error != nil {
				return "", .Out_Of_Memory
			}
		case:
			return "", .Invalid_Syntax
		}
	}
	return "", .Invalid_Syntax
}

yaml_plain_is_decimal_integer :: proc(value: string) -> bool {
	if len(value) == 0 do return false
	position := 0
	if value[0] == '+' || value[0] == '-' {
		position = 1
	}
	if position == len(value) do return false
	for position < len(value) {
		if value[position] < '0' || value[position] > '9' {
			return false
		}
		position += 1
	}
	return true
}

yaml_parse_plain_scalar :: proc(
	raw_value: string,
	allocator: mem.Allocator,
) -> (json.Value, Data_Parse_Error) {
	value := yaml_trim(raw_value)
	if len(value) == 0 {
		return {}, .Invalid_Syntax
	}
	switch value[0] {
	case '&', '*', '!', '|', '>':
		return {}, .Unsupported_Value
	case '%', '@', '`':
		return {}, .Invalid_Syntax
	}
	if value == "?" || strings.has_prefix(value, "? ") {
		return {}, .Unsupported_Value
	}

	switch value {
	case "null", "Null", "NULL", "~":
		return json.Null{}, .None
	case "true", "True", "TRUE":
		return json.Boolean(true), .None
	case "false", "False", "FALSE":
		return json.Boolean(false), .None
	case ".nan", ".NaN", ".NAN", ".inf", ".Inf", ".INF",
	     "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF":
		return {}, .Unsupported_Value
	}

	if yaml_plain_is_decimal_integer(value) {
		consumed := 0
		integer, integer_ok := strconv.parse_i64(value, 10, &consumed)
		if !integer_ok || consumed != len(value) {
			return {}, .Unsupported_Value
		}
		return json.Integer(integer), .None
	}

	cloned, clone_result := yaml_clone_string(value, allocator)
	if clone_result != .None {
		return {}, clone_result
	}
	return json.String(cloned), .None
}

yaml_parse_flow_array :: proc(
	parser: ^YAML_Flow_Parser,
	depth: int,
) -> (json.Value, Data_Parse_Error) {
	if depth > YAML_MAX_DEPTH do return {}, .Unsupported_Value
	parser.position += 1 // '['
	array, make_error := make(json.Array, 0, 4, parser.allocator)
	if make_error != nil do return {}, .Out_Of_Memory

	yaml_flow_skip_space(parser)
	if parser.position < len(parser.text) && parser.text[parser.position] == ']' {
		parser.position += 1
		return array, .None
	}
	for {
		value, value_result := yaml_parse_flow_value(parser, true, depth + 1)
		if value_result != .None {
			json.destroy_value(array, parser.allocator)
			return {}, value_result
		}
		if _, append_error := append(&array, value); append_error != nil {
			json.destroy_value(value, parser.allocator)
			json.destroy_value(array, parser.allocator)
			return {}, .Out_Of_Memory
		}
		yaml_flow_skip_space(parser)
		if parser.position >= len(parser.text) {
			json.destroy_value(array, parser.allocator)
			return {}, .Invalid_Syntax
		}
		if parser.text[parser.position] == ']' {
			parser.position += 1
			return array, .None
		}
		if parser.text[parser.position] != ',' {
			json.destroy_value(array, parser.allocator)
			return {}, .Invalid_Syntax
		}
		parser.position += 1
		yaml_flow_skip_space(parser)
		if parser.position < len(parser.text) && parser.text[parser.position] == ']' {
			parser.position += 1
			return array, .None
		}
	}
}

yaml_parse_flow_key :: proc(
	parser: ^YAML_Flow_Parser,
) -> (string, Data_Parse_Error) {
	yaml_flow_skip_space(parser)
	if parser.position >= len(parser.text) {
		return "", .Invalid_Syntax
	}
	if parser.text[parser.position] == '\'' || parser.text[parser.position] == '"' {
		return yaml_parse_quoted_string(parser)
	}
	start := parser.position
	for parser.position < len(parser.text) && parser.text[parser.position] != ':' {
		if parser.text[parser.position] == ',' ||
		   parser.text[parser.position] == '}' ||
		   parser.text[parser.position] == ']' {
			return "", .Invalid_Syntax
		}
		parser.position += 1
	}
	key := yaml_trim(parser.text[start:parser.position])
	if len(key) == 0 do return "", .Invalid_Syntax
	switch key[0] {
	case '&', '*', '!', '|', '>', '?': return "", .Unsupported_Value
	}
	if key == "<<" do return "", .Unsupported_Value
	return yaml_clone_string(key, parser.allocator)
}

yaml_parse_flow_object :: proc(
	parser: ^YAML_Flow_Parser,
	depth: int,
) -> (json.Value, Data_Parse_Error) {
	if depth > YAML_MAX_DEPTH do return {}, .Unsupported_Value
	parser.position += 1 // '{'
	object, make_error := make(json.Object, 8, parser.allocator)
	if make_error != nil do return {}, .Out_Of_Memory

	yaml_flow_skip_space(parser)
	if parser.position < len(parser.text) && parser.text[parser.position] == '}' {
		parser.position += 1
		return object, .None
	}
	for {
		key, key_result := yaml_parse_flow_key(parser)
		if key_result != .None {
			json.destroy_value(object, parser.allocator)
			return {}, key_result
		}
		yaml_flow_skip_space(parser)
		if parser.position >= len(parser.text) || parser.text[parser.position] != ':' {
			delete(key, parser.allocator)
			json.destroy_value(object, parser.allocator)
			return {}, .Invalid_Syntax
		}
		parser.position += 1
		if _, duplicate := object[key]; duplicate {
			delete(key, parser.allocator)
			json.destroy_value(object, parser.allocator)
			return {}, .Invalid_Syntax
		}
		value, value_result := yaml_parse_flow_value(parser, true, depth + 1)
		if value_result != .None {
			delete(key, parser.allocator)
			json.destroy_value(object, parser.allocator)
			return {}, value_result
		}
		object[key] = value

		yaml_flow_skip_space(parser)
		if parser.position >= len(parser.text) {
			json.destroy_value(object, parser.allocator)
			return {}, .Invalid_Syntax
		}
		if parser.text[parser.position] == '}' {
			parser.position += 1
			return object, .None
		}
		if parser.text[parser.position] != ',' {
			json.destroy_value(object, parser.allocator)
			return {}, .Invalid_Syntax
		}
		parser.position += 1
		yaml_flow_skip_space(parser)
		if parser.position < len(parser.text) && parser.text[parser.position] == '}' {
			parser.position += 1
			return object, .None
		}
	}
}

yaml_parse_flow_value :: proc(
	parser: ^YAML_Flow_Parser,
	inside_flow: bool,
	depth: int,
) -> (json.Value, Data_Parse_Error) {
	if depth > YAML_MAX_DEPTH do return {}, .Unsupported_Value
	yaml_flow_skip_space(parser)
	if parser.position >= len(parser.text) do return {}, .Invalid_Syntax
	switch parser.text[parser.position] {
	case '[':
		return yaml_parse_flow_array(parser, depth)
	case '{':
		return yaml_parse_flow_object(parser, depth)
	case '\'', '"':
		value, result := yaml_parse_quoted_string(parser)
		if result != .None do return {}, result
		return json.String(value), .None
	}

	start := parser.position
	for parser.position < len(parser.text) {
		character := parser.text[parser.position]
		if inside_flow && (character == ',' || character == ']' || character == '}') {
			break
		}
		parser.position += 1
	}
	return yaml_parse_plain_scalar(parser.text[start:parser.position], parser.allocator)
}

yaml_parse_inline :: proc(
	text: string,
	allocator: mem.Allocator,
	depth: int,
) -> (json.Value, Data_Parse_Error) {
	flow := YAML_Flow_Parser{text = text, allocator = allocator}
	value, result := yaml_parse_flow_value(&flow, false, depth)
	if result != .None do return {}, result
	yaml_flow_skip_space(&flow)
	if flow.position != len(flow.text) {
		json.destroy_value(value, allocator)
		return {}, .Trailing_Content
	}
	return value, .None
}

yaml_parse_key :: proc(
	raw_key: string,
	allocator: mem.Allocator,
) -> (string, Data_Parse_Error) {
	key := yaml_trim(raw_key)
	if len(key) == 0 do return "", .Invalid_Syntax
	if key[0] == '\'' || key[0] == '"' {
		flow := YAML_Flow_Parser{text = key, allocator = allocator}
		decoded, result := yaml_parse_quoted_string(&flow)
		if result != .None do return "", result
		yaml_flow_skip_space(&flow)
		if flow.position != len(flow.text) {
			delete(decoded, allocator)
			return "", .Invalid_Syntax
		}
		return decoded, .None
	}
	switch key[0] {
	case '&', '*', '!', '|', '>', '?': return "", .Unsupported_Value
	case '[', '{':                   return "", .Unsupported_Value
	}
	if key == "<<" do return "", .Unsupported_Value
	return yaml_clone_string(key, allocator)
}

yaml_parse_mapping_entry :: proc(
	parser: ^YAML_Parser,
	object: ^json.Object,
	text: string,
	indent: int,
	depth: int,
) -> Data_Parse_Error {
	colon, colon_ok := yaml_find_mapping_colon(text)
	if !colon_ok do return .Invalid_Syntax
	key, key_result := yaml_parse_key(text[:colon], parser.allocator)
	if key_result != .None do return key_result
	if _, duplicate := object[key]; duplicate {
		delete(key, parser.allocator)
		return .Invalid_Syntax
	}

	remainder := yaml_trim(text[colon+1:])
	value: json.Value
	value_result := Data_Parse_Error.None
	if len(remainder) == 0 {
		if parser.index < len(parser.lines) && parser.lines[parser.index].indent > indent {
			value, value_result = yaml_parse_block(
				parser,
				parser.lines[parser.index].indent,
				depth + 1,
			)
		} else {
			value = json.Null{}
		}
	} else {
		value, value_result = yaml_parse_inline(remainder, parser.allocator, depth + 1)
	}
	if value_result != .None {
		delete(key, parser.allocator)
		return value_result
	}
	object[key] = value
	return .None
}

yaml_parse_mapping_entries :: proc(
	parser: ^YAML_Parser,
	indent: int,
	object: ^json.Object,
	depth: int,
) -> Data_Parse_Error {
	for parser.index < len(parser.lines) {
		line := parser.lines[parser.index]
		if line.indent < indent do break
		if line.indent != indent || yaml_is_sequence_line(line.text) {
			return .Invalid_Syntax
		}
		if _, colon_ok := yaml_find_mapping_colon(line.text); !colon_ok {
			return .Invalid_Syntax
		}
		parser.index += 1
		result := yaml_parse_mapping_entry(parser, object, line.text, indent, depth)
		if result != .None do return result
	}
	return .None
}

yaml_parse_mapping :: proc(
	parser: ^YAML_Parser,
	indent: int,
	depth: int,
) -> (json.Value, Data_Parse_Error) {
	object, make_error := make(json.Object, 8, parser.allocator)
	if make_error != nil do return {}, .Out_Of_Memory
	result := yaml_parse_mapping_entries(parser, indent, &object, depth)
	if result != .None {
		json.destroy_value(object, parser.allocator)
		return {}, result
	}
	return object, .None
}

yaml_parse_sequence :: proc(
	parser: ^YAML_Parser,
	indent: int,
	depth: int,
) -> (json.Value, Data_Parse_Error) {
	array, make_error := make(json.Array, 0, 4, parser.allocator)
	if make_error != nil do return {}, .Out_Of_Memory

	for parser.index < len(parser.lines) {
		line := parser.lines[parser.index]
		if line.indent < indent do break
		if line.indent != indent || !yaml_is_sequence_line(line.text) {
			json.destroy_value(array, parser.allocator)
			return {}, .Invalid_Syntax
		}
		parser.index += 1
		payload := yaml_trim(line.text[1:])
		item: json.Value
		item_result := Data_Parse_Error.None
		if len(payload) == 0 {
			if parser.index < len(parser.lines) && parser.lines[parser.index].indent > indent {
				item, item_result = yaml_parse_block(
					parser,
					parser.lines[parser.index].indent,
					depth + 1,
				)
			} else {
				item = json.Null{}
			}
		} else if _, is_mapping := yaml_find_mapping_colon(payload); is_mapping {
			object, object_error := make(json.Object, 4, parser.allocator)
			if object_error != nil {
				json.destroy_value(array, parser.allocator)
				return {}, .Out_Of_Memory
			}
			mapping_indent := indent + 2
			item_result = yaml_parse_mapping_entry(
				parser,
				&object,
				payload,
				mapping_indent,
				depth + 1,
			)
			if item_result == .None && parser.index < len(parser.lines) &&
			   parser.lines[parser.index].indent > indent {
				if parser.lines[parser.index].indent != mapping_indent ||
				   yaml_is_sequence_line(parser.lines[parser.index].text) {
					item_result = .Invalid_Syntax
				} else {
					item_result = yaml_parse_mapping_entries(
						parser,
						mapping_indent,
						&object,
						depth + 1,
					)
				}
			}
			if item_result != .None {
				json.destroy_value(object, parser.allocator)
			} else {
				item = object
			}
		} else {
			item, item_result = yaml_parse_inline(payload, parser.allocator, depth + 1)
		}

		if item_result != .None {
			json.destroy_value(array, parser.allocator)
			return {}, item_result
		}
		if parser.index < len(parser.lines) && parser.lines[parser.index].indent > indent {
			json.destroy_value(item, parser.allocator)
			json.destroy_value(array, parser.allocator)
			return {}, .Invalid_Syntax
		}
		if _, append_error := append(&array, item); append_error != nil {
			json.destroy_value(item, parser.allocator)
			json.destroy_value(array, parser.allocator)
			return {}, .Out_Of_Memory
		}
	}
	return array, .None
}

yaml_parse_block :: proc(
	parser: ^YAML_Parser,
	indent: int,
	depth: int,
) -> (json.Value, Data_Parse_Error) {
	if depth > YAML_MAX_DEPTH do return {}, .Unsupported_Value
	if parser.index >= len(parser.lines) || parser.lines[parser.index].indent != indent {
		return {}, .Invalid_Syntax
	}
	line := parser.lines[parser.index]
	if yaml_is_sequence_line(line.text) {
		return yaml_parse_sequence(parser, indent, depth)
	}
	if _, mapping := yaml_find_mapping_colon(line.text); mapping {
		return yaml_parse_mapping(parser, indent, depth)
	}

	parser.index += 1
	value, result := yaml_parse_inline(line.text, parser.allocator, depth)
	if result != .None do return {}, result
	if parser.index < len(parser.lines) && parser.lines[parser.index].indent >= indent {
		json.destroy_value(value, parser.allocator)
		return {}, .Invalid_Syntax
	}
	return value, .None
}

data_parse_yaml :: proc(
	contents: string,
	allocator: mem.Allocator = context.allocator,
) -> (json.Value, Data_Parse_Error) {
	lines, collect_result := yaml_collect_lines(contents, allocator)
	if collect_result != .None {
		return {}, collect_result
	}
	defer delete(lines)
	if len(lines) == 0 {
		return json.Null{}, .None
	}
	if lines[0].indent != 0 {
		return {}, .Invalid_Syntax
	}
	parser := YAML_Parser{lines = lines[:], allocator = allocator}
	value, result := yaml_parse_block(&parser, 0, 0)
	if result != .None {
		return {}, result
	}
	if parser.index != len(parser.lines) {
		json.destroy_value(value, allocator)
		return {}, .Invalid_Syntax
	}
	return value, .None
}

package main

import "core:encoding/endian"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

MESSAGEPACK_MAX_DEPTH :: 64
MESSAGEPACK_NODE_BUDGET :: 1_000_000

MessagePack_Reader :: struct {
	data:            []u8,
	position:        int,
	nodes_remaining: int,
	allocator:       mem.Allocator,
}

messagepack_take :: proc(reader: ^MessagePack_Reader, count: int) -> ([]u8, bool) {
	if count < 0 || reader.position < 0 || reader.position > len(reader.data) {
		return nil, false
	}
	// Subtract before comparing so a corrupt length can never overflow position.
	if count > len(reader.data)-reader.position {
		return nil, false
	}
	start := reader.position
	reader.position += count
	return reader.data[start:reader.position], true
}

messagepack_read_u8 :: proc(reader: ^MessagePack_Reader) -> (u8, bool) {
	bytes, ok := messagepack_take(reader, 1)
	if !ok do return 0, false
	return bytes[0], true
}

messagepack_read_u16 :: proc(reader: ^MessagePack_Reader) -> (u16, bool) {
	bytes, ok := messagepack_take(reader, 2)
	if !ok do return 0, false
	return endian.unchecked_get_u16be(bytes), true
}

messagepack_read_u32 :: proc(reader: ^MessagePack_Reader) -> (u32, bool) {
	bytes, ok := messagepack_take(reader, 4)
	if !ok do return 0, false
	return endian.unchecked_get_u32be(bytes), true
}

messagepack_read_u64 :: proc(reader: ^MessagePack_Reader) -> (u64, bool) {
	bytes, ok := messagepack_take(reader, 8)
	if !ok do return 0, false
	return endian.unchecked_get_u64be(bytes), true
}

messagepack_u64_to_length :: proc(value: u64) -> (int, bool) {
	if value > u64(max(int)) do return 0, false
	return int(value), true
}

messagepack_read_length8 :: proc(reader: ^MessagePack_Reader) -> (int, bool) {
	value, ok := messagepack_read_u8(reader)
	return int(value), ok
}

messagepack_read_length16 :: proc(reader: ^MessagePack_Reader) -> (int, bool) {
	value, ok := messagepack_read_u16(reader)
	return int(value), ok
}

messagepack_read_length32 :: proc(reader: ^MessagePack_Reader) -> (int, bool) {
	value, ok := messagepack_read_u32(reader)
	if !ok do return 0, false
	return messagepack_u64_to_length(u64(value))
}

messagepack_clone_string :: proc(
	reader: ^MessagePack_Reader,
	count: int,
) -> (json.Value, Data_Parse_Error) {
	bytes, ok := messagepack_take(reader, count)
	if !ok do return {}, .Invalid_Syntax
	view := string(bytes)
	if !utf8.valid_string(view) do return {}, .Invalid_Syntax
	owned, clone_err := strings.clone(view, reader.allocator)
	if clone_err != nil do return {}, .Out_Of_Memory
	return json.String(owned), .None
}

messagepack_destroy_array :: proc(array: json.Array, allocator: mem.Allocator) {
	for value in array {
		json.destroy_value(value, allocator)
	}
	delete(array)
}

messagepack_destroy_object :: proc(object: json.Object, allocator: mem.Allocator) {
	for key, value in object {
		delete(key, allocator)
		json.destroy_value(value, allocator)
	}
	delete(object)
}

messagepack_read_array :: proc(
	reader: ^MessagePack_Reader,
	count: int,
	depth: int,
) -> (value: json.Value, err: Data_Parse_Error) {
	remaining_bytes := len(reader.data)-reader.position
	if count < 0 || count > remaining_bytes || count > reader.nodes_remaining {
		return {}, .Invalid_Syntax
	}

	array, alloc_err := make(json.Array, count, count, reader.allocator)
	if alloc_err != nil do return {}, .Out_Of_Memory
	initialized := 0
	defer if err != .None {
		for index in 0..<initialized {
			json.destroy_value(array[index], reader.allocator)
		}
		delete(array)
	}

	for index in 0..<count {
		element, element_err := messagepack_read_value(reader, depth+1)
		if element_err != .None do return {}, element_err
		array[index] = element
		initialized += 1
	}
	return array, .None
}

messagepack_read_map :: proc(
	reader: ^MessagePack_Reader,
	count: int,
	depth: int,
) -> (value: json.Value, err: Data_Parse_Error) {
	remaining_bytes := len(reader.data)-reader.position
	// Every entry needs at least a one-byte key and a one-byte value.
	if count < 0 || count > remaining_bytes/2 || count > reader.nodes_remaining/2 {
		return {}, .Invalid_Syntax
	}

	object, alloc_err := make(json.Object, count, reader.allocator)
	if alloc_err != nil do return {}, .Out_Of_Memory
	defer if err != .None {
		messagepack_destroy_object(object, reader.allocator)
	}

	for _ in 0..<count {
		key_value, key_err := messagepack_read_value(reader, depth+1)
		if key_err != .None do return {}, key_err
		key, key_ok := key_value.(json.String)
		if !key_ok {
			json.destroy_value(key_value, reader.allocator)
			return {}, .Invalid_Syntax
		}
		if key in object {
			delete(key, reader.allocator)
			return {}, .Invalid_Syntax
		}

		element, element_err := messagepack_read_value(reader, depth+1)
		if element_err != .None {
			delete(key, reader.allocator)
			return {}, element_err
		}
		object[key] = element
	}
	return object, .None
}

messagepack_consume_unsupported :: proc(
	reader: ^MessagePack_Reader,
	count: int,
	has_extension_type := false,
) -> (json.Value, Data_Parse_Error) {
	if has_extension_type {
		if _, ok := messagepack_take(reader, 1); !ok {
			return {}, .Invalid_Syntax
		}
	}
	if _, ok := messagepack_take(reader, count); !ok {
		return {}, .Invalid_Syntax
	}
	return {}, .Unsupported_Value
}

messagepack_read_value :: proc(
	reader: ^MessagePack_Reader,
	depth: int,
) -> (json.Value, Data_Parse_Error) {
	if depth > MESSAGEPACK_MAX_DEPTH || reader.nodes_remaining <= 0 {
		return {}, .Invalid_Syntax
	}
	reader.nodes_remaining -= 1

	tag, tag_ok := messagepack_read_u8(reader)
	if !tag_ok do return {}, .Invalid_Syntax

	switch tag {
	case 0x00..=0x7f:
		return json.Integer(i64(tag)), .None
	case 0x80..=0x8f:
		return messagepack_read_map(reader, int(tag&0x0f), depth)
	case 0x90..=0x9f:
		return messagepack_read_array(reader, int(tag&0x0f), depth)
	case 0xa0..=0xbf:
		return messagepack_clone_string(reader, int(tag&0x1f))
	case 0xe0..=0xff:
		return json.Integer(i64(cast(i8)tag)), .None
	}

	switch tag {
	case 0xc0:
		return json.Null(nil), .None
	case 0xc1:
		return {}, .Invalid_Syntax
	case 0xc2:
		return json.Boolean(false), .None
	case 0xc3:
		return json.Boolean(true), .None

	// Binary and extension values have no lossless json.Value counterpart.
	// Consume and bounds-check their payload so truncation remains a syntax
	// error, then report a consistent unsupported-value error.
	case 0xc4:
		count, ok := messagepack_read_length8(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_consume_unsupported(reader, count)
	case 0xc5:
		count, ok := messagepack_read_length16(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_consume_unsupported(reader, count)
	case 0xc6:
		count, ok := messagepack_read_length32(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_consume_unsupported(reader, count)
	case 0xc7:
		count, ok := messagepack_read_length8(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_consume_unsupported(reader, count, true)
	case 0xc8:
		count, ok := messagepack_read_length16(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_consume_unsupported(reader, count, true)
	case 0xc9:
		count, ok := messagepack_read_length32(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_consume_unsupported(reader, count, true)

	case 0xca:
		bits, ok := messagepack_read_u32(reader)
		if !ok do return {}, .Invalid_Syntax
		return json.Float(f64(transmute(f32)bits)), .None
	case 0xcb:
		bits, ok := messagepack_read_u64(reader)
		if !ok do return {}, .Invalid_Syntax
		return json.Float(transmute(f64)bits), .None

	case 0xcc:
		integer, ok := messagepack_read_u8(reader)
		if !ok do return {}, .Invalid_Syntax
		return json.Integer(i64(integer)), .None
	case 0xcd:
		integer, ok := messagepack_read_u16(reader)
		if !ok do return {}, .Invalid_Syntax
		return json.Integer(i64(integer)), .None
	case 0xce:
		integer, ok := messagepack_read_u32(reader)
		if !ok do return {}, .Invalid_Syntax
		return json.Integer(i64(integer)), .None
	case 0xcf:
		integer, ok := messagepack_read_u64(reader)
		if !ok do return {}, .Invalid_Syntax
		if integer > u64(max(i64)) do return {}, .Unsupported_Value
		return json.Integer(i64(integer)), .None

	case 0xd0:
		bits, ok := messagepack_read_u8(reader)
		if !ok do return {}, .Invalid_Syntax
		return json.Integer(i64(cast(i8)bits)), .None
	case 0xd1:
		bits, ok := messagepack_read_u16(reader)
		if !ok do return {}, .Invalid_Syntax
		return json.Integer(i64(cast(i16)bits)), .None
	case 0xd2:
		bits, ok := messagepack_read_u32(reader)
		if !ok do return {}, .Invalid_Syntax
		return json.Integer(i64(cast(i32)bits)), .None
	case 0xd3:
		bits, ok := messagepack_read_u64(reader)
		if !ok do return {}, .Invalid_Syntax
		return json.Integer(cast(i64)bits), .None

	case 0xd4: return messagepack_consume_unsupported(reader, 1,  true)
	case 0xd5: return messagepack_consume_unsupported(reader, 2,  true)
	case 0xd6: return messagepack_consume_unsupported(reader, 4,  true)
	case 0xd7: return messagepack_consume_unsupported(reader, 8,  true)
	case 0xd8: return messagepack_consume_unsupported(reader, 16, true)

	case 0xd9:
		count, ok := messagepack_read_length8(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_clone_string(reader, count)
	case 0xda:
		count, ok := messagepack_read_length16(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_clone_string(reader, count)
	case 0xdb:
		count, ok := messagepack_read_length32(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_clone_string(reader, count)

	case 0xdc:
		count, ok := messagepack_read_length16(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_read_array(reader, count, depth)
	case 0xdd:
		count, ok := messagepack_read_length32(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_read_array(reader, count, depth)
	case 0xde:
		count, ok := messagepack_read_length16(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_read_map(reader, count, depth)
	case 0xdf:
		count, ok := messagepack_read_length32(reader)
		if !ok do return {}, .Invalid_Syntax
		return messagepack_read_map(reader, count, depth)
	}

	return {}, .Invalid_Syntax
}

data_parse_messagepack :: proc(
	contents: string,
	allocator: mem.Allocator = context.allocator,
) -> (json.Value, Data_Parse_Error) {
	reader := MessagePack_Reader{
		data            = transmute([]u8)contents,
		nodes_remaining = MESSAGEPACK_NODE_BUDGET,
		allocator       = allocator,
	}
	value, parse_err := messagepack_read_value(&reader, 0)
	if parse_err != .None do return {}, parse_err
	if reader.position != len(reader.data) {
		json.destroy_value(value, allocator)
		return {}, .Trailing_Content
	}
	return value, .None
}

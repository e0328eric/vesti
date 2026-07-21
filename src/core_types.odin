package main

import "core:mem"

import uucode "./uucode"

// Location uses one-based rows and terminal display columns, matching the Zig
// implementation.  A combining character can therefore leave col unchanged,
// while a wide character advances it by two.
Location :: struct {
	row: int,
	col: int,
}

location_init :: proc() -> Location {
	return Location{row = 1, col = 1}
}

location_move :: proc(location: ^Location, cp: rune) {
	if cp == '\n' {
		location.row += 1
		location.col = 1
		return
	}
	location.col += uucode.wcwidth_standalone(cp)
}

Span :: struct {
	start: Location,
	end:   Location,
}

span_init :: proc() -> Span {
	loc := location_init()
	return Span{start = loc, end = loc}
}

Cow_Str_State :: enum u8 {
	Empty,
	Borrowed,
	Owned,
}

// Cow_Str is deliberately a tagged struct instead of an Odin union.  This
// keeps the borrowed and owned views explicit and makes moving the value into
// recursive AST nodes straightforward.  Only the Owned state may be freed.
Cow_Str :: struct {
	state:    Cow_Str_State,
	borrowed: string,
	owned:    [dynamic]u8,
}

cow_str_empty :: proc() -> Cow_Str {
	return Cow_Str{state = .Empty}
}

cow_str_borrowed :: proc(value: string) -> Cow_Str {
	return Cow_Str{state = .Borrowed, borrowed = value}
}

cow_str_owned_copy :: proc(
	value: string,
	allocator := context.allocator,
) -> (result: Cow_Str, err: mem.Allocator_Error) {
	bytes := make([dynamic]u8, 0, len(value), allocator) or_return
	if len(value) > 0 {
		if _, append_err := append(&bytes, value); append_err != nil {
			delete(bytes)
			return {}, append_err
		}
	}
	return Cow_Str{state = .Owned, owned = bytes}, nil
}

cow_str_from_owned_bytes :: proc(value: [dynamic]u8) -> Cow_Str {
	return Cow_Str{state = .Owned, owned = value}
}

cow_str_string :: proc(value: Cow_Str) -> string {
	switch value.state {
	case .Empty:
		return ""
	case .Borrowed:
		return value.borrowed
	case .Owned:
		return string(value.owned[:])
	}
	return ""
}

cow_str_equal :: proc(value: Cow_Str, rhs: string) -> bool {
	return cow_str_string(value) == rhs
}

cow_str_append :: proc(
	value: ^Cow_Str,
	suffix: string,
	allocator := context.allocator,
) -> mem.Allocator_Error {
	switch value.state {
	case .Empty:
		value^ = cow_str_borrowed(suffix)
		return nil
	case .Borrowed:
		old := value.borrowed
		bytes := make([dynamic]u8, 0, len(old)+len(suffix), allocator) or_return
		if len(old) > 0 {
			if _, err := append(&bytes, old); err != nil {
				delete(bytes)
				return err
			}
		}
		if _, err := append(&bytes, suffix); err != nil {
			delete(bytes)
			return err
		}
		value^ = Cow_Str{state = .Owned, owned = bytes}
		return nil
	case .Owned:
		_, err := append(&value.owned, suffix)
		return err
	}
	return nil
}

cow_str_deinit :: proc(value: ^Cow_Str, allocator := context.allocator) {
	if value == nil {
		return
	}
	if value.state == .Owned && value.owned != nil {
		delete(value.owned)
	}
	value^ = cow_str_empty()
}

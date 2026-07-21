package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

MAX_CODE_POINT :: 0x110000

Code_Point_Info :: struct {
	alphabetic:        bool,
	alphanumeric:      bool,
	numeric:           bool,
	default_ignorable: bool,
	east_asian_wide:   bool,
	regional_indicator: bool,
	zero_width_category: bool,
}

Code_Point_Range :: struct {
	first: u32,
	last:  u32,
}

Width_Range :: struct {
	first: u32,
	last:  u32,
	width: u8,
}

Bool_Field :: enum {
	Alphabetic,
	Alphanumeric,
	Numeric,
}

parse_code_point :: proc(text: string) -> (value: int, ok: bool) {
	n, parsed := strconv.parse_uint(strings.trim_space(text), 16)
	if !parsed || n >= MAX_CODE_POINT {
		return 0, false
	}
	return int(n), true
}

parse_code_point_range :: proc(text: string) -> (first, last: int, ok: bool) {
	head, _, tail := strings.partition(strings.trim_space(text), "..")
	first, ok = parse_code_point(head)
	if !ok {
		return
	}
	if len(tail) == 0 {
		return first, first, true
	}
	last, ok = parse_code_point(tail)
	if !ok || last < first {
		return 0, 0, false
	}
	return first, last, true
}

category_flags :: proc(category: string) -> (alphanumeric, numeric, zero_width: bool) {
	switch category {
	case "Lu", "Ll", "Lt", "Lm", "Lo":
		alphanumeric = true
	case "Nd", "Nl", "No":
		alphanumeric = true
		numeric = true
	case "Cc", "Cs", "Zl", "Zp":
		zero_width = true
	}
	return
}

parse_unicode_data :: proc(path: string, info: []Code_Point_Info) -> bool {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("unicode_gen: cannot read %s: %v", path, read_err)
		return false
	}
	defer delete(data)

	text := string(data)
	pending_first := false
	first_code_point := 0
	first_info: Code_Point_Info
	line_number := 0

	for raw_line in strings.split_lines_iterator(&text) {
		line_number += 1
		line := strings.trim_space(raw_line)
		if len(line) == 0 {
			continue
		}

		fields := line
		field_index := 0
		code_point := -1
		name := ""
		category := ""
		for raw_field in strings.split_iterator(&fields, ";") {
			field := strings.trim_space(raw_field)
			switch field_index {
			case 0:
				ok: bool
				code_point, ok = parse_code_point(field)
				if !ok {
					fmt.eprintfln("unicode_gen: %s:%d: invalid code point %q", path, line_number, field)
					return false
				}
			case 1:
				name = field
			case 2:
				category = field
			}
			field_index += 1
		}

		// `strings.split_iterator` does not yield a final empty field, and many
		// UnicodeData rows end with one. Only the first three fields are needed.
		if field_index < 3 || code_point < 0 || len(name) == 0 || len(category) != 2 {
			fmt.eprintfln("unicode_gen: %s:%d: malformed UnicodeData row", path, line_number)
			return false
		}

		alphanumeric, numeric, zero_width := category_flags(category)
		row := Code_Point_Info{
			alphanumeric = alphanumeric,
			numeric = numeric,
			zero_width_category = zero_width,
		}

		if strings.ends_with(name, ", First>") {
			if pending_first {
				fmt.eprintfln("unicode_gen: %s:%d: nested First range", path, line_number)
				return false
			}
			pending_first = true
			first_code_point = code_point
			first_info = row
			continue
		}

		if strings.ends_with(name, ", Last>") {
			if !pending_first || code_point < first_code_point {
				fmt.eprintfln("unicode_gen: %s:%d: Last without matching First", path, line_number)
				return false
			}
			for cp := first_code_point; cp <= code_point; cp += 1 {
				info[cp] = first_info
			}
			pending_first = false
			continue
		}

		if pending_first {
			fmt.eprintfln("unicode_gen: %s:%d: expected Last range row", path, line_number)
			return false
		}
		info[code_point] = row
	}

	if pending_first {
		fmt.eprintfln("unicode_gen: %s: unterminated First range", path)
		return false
	}
	return true
}

set_range_property :: proc(info: []Code_Point_Info, first, last: int, property: string) {
	for cp := first; cp <= last; cp += 1 {
		switch property {
		case "Alphabetic":
			info[cp].alphabetic = true
		case "Default_Ignorable_Code_Point":
			info[cp].default_ignorable = true
		case "W", "F", "Wide", "Fullwidth":
			info[cp].east_asian_wide = true
		case "Regional_Indicator":
			info[cp].regional_indicator = true
		}
	}
}

set_east_asian_width_range :: proc(info: []Code_Point_Info, first, last: int, wide: bool) {
	for cp := first; cp <= last; cp += 1 {
		info[cp].east_asian_wide = wide
	}
}

parse_property_file :: proc(
	path: string,
	info: []Code_Point_Info,
	wanted_a, wanted_b: string,
	parse_missing: bool = false,
) -> bool {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("unicode_gen: cannot read %s: %v", path, read_err)
		return false
	}
	defer delete(data)

	text := string(data)
	line_number := 0
	for raw_line in strings.split_lines_iterator(&text) {
		line_number += 1
		trimmed := strings.trim_space(raw_line)
		if len(trimmed) == 0 {
			continue
		}

		line := trimmed
		if parse_missing && strings.starts_with(line, "# @missing:") {
			line = strings.trim_space(line[len("# @missing:"):])
		} else {
			line, _, _ = strings.partition(line, "#")
			line = strings.trim_space(line)
			if len(line) == 0 {
				continue
			}
		}

		fields := line
		range_text := ""
		property := ""
		field_index := 0
		for raw_field in strings.split_iterator(&fields, ";") {
			field := strings.trim_space(raw_field)
			if field_index == 0 {
				range_text = field
			} else if field_index == 1 {
				property = field
			}
			field_index += 1
		}

		if !parse_missing && property != wanted_a && property != wanted_b {
			continue
		}
		first, last, ok := parse_code_point_range(range_text)
		if !ok {
			fmt.eprintfln("unicode_gen: %s:%d: invalid range %q", path, line_number, range_text)
			return false
		}
		if parse_missing {
			// DerivedEastAsianWidth starts with @missing defaults and then lists
			// explicit values. Explicit narrow/neutral/ambiguous records must be
			// able to clear an earlier @missing Wide assignment.
			wide := property == wanted_a || property == wanted_b ||
			        property == "Wide" || property == "Fullwidth"
			set_east_asian_width_range(info, first, last, wide)
		} else {
			set_range_property(info, first, last, property)
		}
	}
	return true
}

bool_value :: proc(info: Code_Point_Info, field: Bool_Field) -> bool {
	switch field {
	case .Alphabetic:   return info.alphabetic
	case .Alphanumeric: return info.alphanumeric
	case .Numeric:      return info.numeric
	}
	return false
}

collect_bool_ranges :: proc(info: []Code_Point_Info, field: Bool_Field) -> [dynamic]Code_Point_Range {
	ranges: [dynamic]Code_Point_Range
	first := -1
	for cp in 0..<len(info) {
		value := bool_value(info[cp], field)
		if value && first < 0 {
			first = cp
		} else if !value && first >= 0 {
			append(&ranges, Code_Point_Range{u32(first), u32(cp-1)})
			first = -1
		}
	}
	if first >= 0 {
		append(&ranges, Code_Point_Range{u32(first), u32(len(info)-1)})
	}
	return ranges
}

standalone_width :: proc(cp: int, info: Code_Point_Info) -> u8 {
	width: u8
	if info.zero_width_category {
		width = 0
	} else if cp == 0x00ad {
		width = 1
	} else if info.default_ignorable {
		width = 0
	} else if cp == 0x2e3a {
		width = 2
	} else if cp == 0x2e3b {
		width = 3
	} else if info.east_asian_wide || info.regional_indicator {
		width = 2
	} else {
		width = 1
	}

	if cp == 0x20e3 {
		return 2
	}
	return width
}

collect_width_ranges :: proc(info: []Code_Point_Info) -> [dynamic]Width_Range {
	ranges: [dynamic]Width_Range
	first := -1
	current: u8 = 1
	for cp in 0..<len(info) {
		width := standalone_width(cp, info[cp])
		if width == 1 {
			if first >= 0 {
				append(&ranges, Width_Range{u32(first), u32(cp-1), current})
				first = -1
			}
			continue
		}
		if first < 0 {
			first = cp
			current = width
		} else if width != current {
			append(&ranges, Width_Range{u32(first), u32(cp-1), current})
			first = cp
			current = width
		}
	}
	if first >= 0 {
		append(&ranges, Width_Range{u32(first), u32(len(info)-1), current})
	}
	return ranges
}

emit_bool_ranges :: proc(file: ^os.File, name: string, ranges: []Code_Point_Range) {
	fmt.fprintln(file, "@(rodata)")
	fmt.fprintfln(file, "%s := [?]Code_Point_Range{{", name)
	for item in ranges {
		fmt.fprintfln(file, "\t{{0x%X, 0x%X}},", item.first, item.last)
	}
	fmt.fprintln(file, "}")
	fmt.fprintln(file)
}

emit_width_ranges :: proc(file: ^os.File, ranges: []Width_Range) {
	fmt.fprintln(file, "@(rodata)")
	fmt.fprintln(file, "width_ranges := [?]Code_Point_Width_Range{")
	for item in ranges {
		fmt.fprintfln(file, "\t{{0x%X, 0x%X, %d}},", item.first, item.last, item.width)
	}
	fmt.fprintln(file, "}")
}

emit_tables :: proc(path: string, info: []Code_Point_Info) -> bool {
	alphabetic := collect_bool_ranges(info, .Alphabetic)
	defer delete(alphabetic)
	alphanumeric := collect_bool_ranges(info, .Alphanumeric)
	defer delete(alphanumeric)
	numeric := collect_bool_ranges(info, .Numeric)
	defer delete(numeric)
	widths := collect_width_ranges(info)
	defer delete(widths)

	temp_path := fmt.aprintf("%s.tmp", path)
	defer delete(temp_path)
	file, create_err := os.create(temp_path)
	if create_err != nil {
		fmt.eprintfln("unicode_gen: cannot create %s: %v", temp_path, create_err)
		return false
	}

	fmt.fprintln(file, "// Generated by tools/unicode_gen from Unicode 17.0.0 data; do not edit.")
	fmt.fprintln(file, "package uucode")
	fmt.fprintln(file)
	fmt.fprintln(file, "UNICODE_VERSION :: \"17.0.0\"")
	fmt.fprintln(file)
	emit_bool_ranges(file, "alphabetic_ranges", alphabetic[:])
	emit_bool_ranges(file, "alphanumeric_ranges", alphanumeric[:])
	emit_bool_ranges(file, "numeric_ranges", numeric[:])
	emit_width_ranges(file, widths[:])

	if close_err := os.close(file); close_err != nil {
		fmt.eprintfln("unicode_gen: cannot close %s: %v", temp_path, close_err)
		_ = os.remove(temp_path)
		return false
	}
	if rename_err := os.rename(temp_path, path); rename_err != nil {
		fmt.eprintfln("unicode_gen: cannot replace %s: %v", path, rename_err)
		_ = os.remove(temp_path)
		return false
	}

	fmt.printfln(
		"unicode_gen: wrote %s (alphabetic=%d alphanumeric=%d numeric=%d width=%d)",
		path,
		len(alphabetic),
		len(alphanumeric),
		len(numeric),
		len(widths),
	)
	return true
}

main :: proc() {
	if len(os.args) != 6 {
		fmt.eprintfln(
			"usage: %s <UnicodeData.txt> <DerivedCoreProperties.txt> <DerivedEastAsianWidth.txt> <GraphemeBreakProperty.txt> <output.odin>",
			os.args[0],
		)
		os.exit(2)
	}

	info := make([]Code_Point_Info, MAX_CODE_POINT)
	defer delete(info)
	if !parse_unicode_data(os.args[1], info) ||
	   !parse_property_file(os.args[2], info, "Alphabetic", "Default_Ignorable_Code_Point") ||
	   !parse_property_file(os.args[3], info, "W", "F", true) ||
	   !parse_property_file(os.args[4], info, "Regional_Indicator", "") ||
	   !emit_tables(os.args[5], info) {
		os.exit(1)
	}
}

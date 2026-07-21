package uucode

Code_Point_Range :: struct {
	first: u32,
	last:  u32,
}

Code_Point_Width_Range :: struct {
	first: u32,
	last:  u32,
	width: u8,
}

is_valid_code_point :: proc(cp: rune) -> bool {
	return cp >= 0 && cp <= 0x10ffff
}

contains_code_point :: proc(ranges: []Code_Point_Range, cp: u32) -> bool {
	lo := 0
	hi := len(ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		item := ranges[mid]
		if cp < item.first {
			hi = mid
		} else if cp > item.last {
			lo = mid + 1
		} else {
			return true
		}
	}
	return false
}

is_ascii_digit :: proc(cp: rune) -> bool {
	return cp >= '0' && cp <= '9'
}

is_ascii_alphanumeric :: proc(cp: rune) -> bool {
	return is_ascii_digit(cp) ||
	       (cp >= 'A' && cp <= 'Z') ||
	       (cp >= 'a' && cp <= 'z')
}

is_alphabetic :: proc(cp: rune) -> bool {
	if !is_valid_code_point(cp) {
		return false
	}
	return contains_code_point(alphabetic_ranges[:], u32(cp))
}

is_alphanumeric :: proc(cp: rune) -> bool {
	if !is_valid_code_point(cp) {
		return false
	}
	return contains_code_point(alphanumeric_ranges[:], u32(cp))
}

is_numeric :: proc(cp: rune) -> bool {
	if !is_valid_code_point(cp) {
		return false
	}
	return contains_code_point(numeric_ranges[:], u32(cp))
}

wcwidth_standalone :: proc(cp: rune) -> int {
	if !is_valid_code_point(cp) {
		return 0
	}

	value := u32(cp)
	lo := 0
	hi := len(width_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		item := width_ranges[mid]
		if value < item.first {
			hi = mid
		} else if value > item.last {
			lo = mid + 1
		} else {
			return int(item.width)
		}
	}
	return 1
}


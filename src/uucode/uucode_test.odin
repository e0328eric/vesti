package uucode

import "core:testing"

@(test)
test_ascii_predicates :: proc(t: ^testing.T) {
	testing.expect(t, is_ascii_digit('0'))
	testing.expect(t, is_ascii_digit('9'))
	testing.expect(t, !is_ascii_digit('/'))
	testing.expect(t, !is_ascii_digit(0x0660))
	testing.expect(t, is_ascii_alphanumeric('A'))
	testing.expect(t, is_ascii_alphanumeric('z'))
	testing.expect(t, is_ascii_alphanumeric('7'))
	testing.expect(t, !is_ascii_alphanumeric('_'))
}

@(test)
test_unicode_classification :: proc(t: ^testing.T) {
	testing.expect(t, is_alphabetic('A'))
	testing.expect(t, is_alphabetic(0x0416)) // CYRILLIC CAPITAL LETTER ZHE
	testing.expect(t, is_alphabetic(0x0345)) // Derived Alphabetic, but category Mn
	testing.expect(t, !is_alphanumeric(0x0345)) // Vesti alnum is category L or N

	testing.expect(t, is_numeric(0x00b2)) // SUPERSCRIPT TWO, No
	testing.expect(t, is_numeric(0x216b)) // ROMAN NUMERAL TWELVE, Nl
	testing.expect(t, is_numeric(0xff15)) // FULLWIDTH DIGIT FIVE, Nd
	testing.expect(t, is_alphanumeric(0x00b2))
	testing.expect(t, is_alphanumeric(0x216b))
	testing.expect(t, is_alphanumeric(0xff15))
	testing.expect(t, !is_numeric('A'))
	testing.expect(t, !is_alphanumeric('_'))

	testing.expect(t, !is_alphabetic(-1))
	testing.expect(t, !is_alphanumeric(0x110000))
}

@(test)
test_standalone_width :: proc(t: ^testing.T) {
	testing.expect_value(t, wcwidth_standalone('A'), 1)
	testing.expect_value(t, wcwidth_standalone(0x0000), 0) // control
	testing.expect_value(t, wcwidth_standalone(0xd800), 0) // surrogate
	testing.expect_value(t, wcwidth_standalone(0x2028), 0) // line separator
	testing.expect_value(t, wcwidth_standalone(0x200b), 0) // default ignorable
	testing.expect_value(t, wcwidth_standalone(0x00ad), 1) // soft-hyphen override
	testing.expect_value(t, wcwidth_standalone(0x4e00), 2) // East Asian wide
	testing.expect_value(t, wcwidth_standalone(0x1f1e6), 2) // regional indicator
	testing.expect_value(t, wcwidth_standalone(0x20e3), 2) // keycap override
	testing.expect_value(t, wcwidth_standalone(0x2e3a), 2)
	testing.expect_value(t, wcwidth_standalone(0x2e3b), 3)
	testing.expect_value(t, wcwidth_standalone(-1), 0)
	testing.expect_value(t, wcwidth_standalone(0x110000), 0)
}


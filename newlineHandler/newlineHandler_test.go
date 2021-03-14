package newlineHandler

import "testing"

func TestNewlineHandler(t *testing.T) {
	input := "\t\r\r\n\r\r\n\n\r"
	expectedLst := []rune("\t\n\n\n\n\n\n")

	nlh := New(input)

	for _, expected := range expectedLst {
		got := nlh.Next()
		if got != expected {
			t.Errorf("expected=%q, got=%q", expected, got)
		}
	}
}

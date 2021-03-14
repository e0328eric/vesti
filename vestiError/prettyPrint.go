package vestiError

import (
	"bytes"
	"fmt"
	"strconv"
	"strings"
)

// Color Definition (ANSI Escape code)
const (
	BoldText      = "\x1b[1m"
	ErrColor      = "\x1b[38;5;9m"
	ErrTitleColor = "\x1b[38;5;15m"
	BlueColor     = "\x1b[38;5;12m"
	ResetColor    = "\x1b[0m"
)

// Pretty print of error messages
func PrintErr(source string, filename *string, err VestiErr) string {
	var out bytes.Buffer

	sourceLines := strings.Split(source, "\n")
	errCode := err.ErrKind()
	errStr := err.ErrString()
	errDetailStr := err.ErrDetailStr()
	startLoc := err.Location().Start
	endLoc := err.Location().End

	// Make error color and error title format
	out.WriteString(BoldText)
	out.WriteString(ErrColor)
	out.WriteByte(' ') // This is a just padding space
	out.WriteString(fmt.Sprintf("error[E%04X]%s: %s", errCode, ErrTitleColor, errStr))
	out.WriteString(ResetColor)
	out.WriteByte('\n')

	// Print file name and error location
	startRowNum := strconv.Itoa(startLoc.Row())
	out.WriteByte(' ') // This is a just padding space
	if filename != nil {
		for i := 1; i <= len(startRowNum); i++ {
			out.WriteByte(' ')
		}
		out.WriteString(BoldText)
		out.WriteString(BlueColor)
		out.WriteString("--> ")
		out.WriteString(ResetColor)
		out.WriteString(*filename)
		out.WriteString(fmt.Sprintf(":%d:%d\n", startLoc.Row(), startLoc.Column()))
	}

	// Print main error message
	out.WriteString(BoldText)
	out.WriteString(BlueColor)
	out.WriteByte(' ') // This is a just padding space
	for i := 1; i <= len(startRowNum); i++ {
		out.WriteByte(' ')
	}
	out.WriteString(" |\n")
	out.WriteByte(' ') // This is a just padding space
	out.WriteString(startRowNum)
	out.WriteString(" |   ")
	out.WriteString(ResetColor)
	out.WriteString(sourceLines[startLoc.Row()-1])
	out.WriteByte('\n')

	paddingSpace := endLoc.Column() - startLoc.Column() + 1
	out.WriteString(BoldText)
	out.WriteString(BlueColor)
	out.WriteByte(' ') // This is a just padding space
	for i := 1; i <= len(startRowNum); i++ {
		out.WriteByte(' ')
	}
	out.WriteString(" |   ")
	for i := 1; i < startLoc.Column(); i++ {
		out.WriteByte(' ')
	}
	out.WriteString(ErrColor)
	for i := 1; i < paddingSpace; i++ {
		out.WriteByte('^')
	}
	out.WriteByte(' ')

	for i, msg := range errDetailStr {
		if i == 0 {
			out.WriteString(msg)
			out.WriteByte('\n')
		} else {
			out.WriteString(BoldText)
			out.WriteString(BlueColor)
			out.WriteByte(' ') // This is a just padding space
			for i := 1; i <= len(startRowNum); i++ {
				out.WriteByte(' ')
			}
			out.WriteString(" |   ")
			for i := 1; i < startLoc.Column(); i++ {
				out.WriteByte(' ')
			}
			out.WriteString(ErrColor)
			for i := 1; i <= paddingSpace; i++ {
				out.WriteByte(' ')
			}
			out.WriteString(msg)
			out.WriteByte('\n')
		}
	}
	out.WriteString(ResetColor)

	return out.String()
}

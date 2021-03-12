package newlineHandler

type NewlineHandler struct {
	source []rune
	chr0   rune
	chr1   rune
	pos    int
}

func New(input string) *NewlineHandler {
	nlh := &NewlineHandler{source: []rune(input), pos: 0}

	nlh.nextChar()
	nlh.nextChar()

	return nlh
}

func (nlh *NewlineHandler) nextChar() {
	nlh.chr0 = nlh.chr1
	if nlh.pos >= len(nlh.source) {
		nlh.chr1 = 0
	} else {
		nlh.chr1 = nlh.source[nlh.pos]
	}
	nlh.pos++
}

func (nlh *NewlineHandler) Next() rune {
	var output rune

	switch {
	case nlh.chr0 == '\r' && nlh.chr1 == '\n':
		nlh.nextChar()
		output = nlh.chr0
	case nlh.chr0 == '\r':
		output = '\n'
	default:
		output = nlh.chr0
	}
	nlh.nextChar()

	return output
}

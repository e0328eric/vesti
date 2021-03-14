package location

type Location struct {
	row    int
	column int
}

type Span struct {
	Start Location
	End   Location
}

func New() *Location {
	return &Location{row: 1, column: 1}
}

func (loc *Location) Row() int {
	return loc.row
}

func (loc *Location) Column() int {
	return loc.column
}

func (loc *Location) MoveRight() {
	loc.column++
}

func (loc *Location) MoveNextLine() {
	loc.row++
	loc.column = 1
}

func (loc *Location) ResetLocation() {
	loc.row = 1
	loc.column = 1
}

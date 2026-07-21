package main

import "core:strconv"
import "core:strings"

VESTI_VERSION :: "0.16.1"
VESTI_DUMMY_DIR :: ".vesti-dummy"

Command_Kind :: enum {
	Help,
	Version,
	Init,
	Clear,
	Compile,
	Latex,
	Experimental,
}

Cli_Options :: struct {
	command:       Command_Kind,
	filename:      string,
	project:       string,
	compile_limit: int,
	watch:         bool,
	no_color:      bool,
	exit_err:      bool,
	standalone:    bool,
	emit_tex:      bool,
	engine:        Latex_Engine,
	has_engine:    bool,
	first_script:  string,
	before_script: string,
	step_script:   string,
}

cli_options_default :: proc() -> Cli_Options {
	return Cli_Options{
		compile_limit = 3,
		first_script = "first.lua",
		before_script = "before.lua",
		step_script = "step.lua",
	}
}

VESTI_HELP :: `vesti - a LaTeX transpiler

Usage:
  vesti init PROJECT
  vesti clear
  vesti compile [FILENAME] [options]
  vesti latex FILENAME [options]
  vesti experimental [FILENAME]

Compile options:
  -S, --standalone       do not search for or run first.lua
  -W, --watch            rebuild when source files change
  -N, --no-color         disable ANSI diagnostics
  -E, --exit-err         exit on the first watch-mode error
  -e, --emit-tex         emit TeX without invoking a backend
      --lim N            number of LaTeX/Tectonic passes (default 3)
  -L, --latex            use latex
  -p, --pdflatex         use pdflatex
  -x, --xelatex          use xelatex
  -l, --lualatex         use lualatex
  -T, --tectonic         use the bundled Tectonic bridge
      --first-script P   project entry script (default first.lua)
      --before-script P  pre-build script (default before.lua)
      --step-script P    per-pass script (default step.lua)
`

cli_error :: proc(diagnostic: ^Diagnostic, message: string) -> bool {
	if diagnostic != nil {
		_ = diagnostic_set(diagnostic, .IO, message)
	}
	return false
}

cli_take_value :: proc(args: []string, index: ^int, inline_value: string) -> (string, bool) {
	if len(inline_value) > 0 {
		return inline_value, true
	}
	if index^ + 1 >= len(args) {
		return "", false
	}
	index^ += 1
	return args[index^], true
}

cli_flag_parts :: proc(arg: string) -> (name, value: string) {
	name = arg
	if strings.has_prefix(name, "--") {
		name = name[2:]
	} else if strings.has_prefix(name, "-") {
		name = name[1:]
	}
	if equal := strings.index(name, "="); equal >= 0 {
		value = name[equal+1:]
		name = name[:equal]
	}
	return
}

cli_set_engine :: proc(options: ^Cli_Options, engine: Latex_Engine, diagnostic: ^Diagnostic) -> bool {
	if options.has_engine {
		return cli_error(diagnostic, "only one LaTeX engine flag may be selected")
	}
	options.engine = engine
	options.has_engine = true
	return true
}

cli_parse :: proc(args: []string, diagnostic: ^Diagnostic = nil) -> (Cli_Options, bool) {
	options := cli_options_default()
	if len(args) == 0 {
		options.command = .Help
		return options, true
	}

	switch args[0] {
	case "help", "-h", "--help": options.command = .Help
	case "version", "-v", "--version": options.command = .Version
	case "init":
		options.command = .Init
		if len(args) < 2 {
			return options, cli_error(diagnostic, "project name is required")
		}
		options.project = args[1]
		return options, true
	case "clear": options.command = .Clear
	case "compile": options.command = .Compile
	case "latex": options.command = .Latex
	case "experimental": options.command = .Experimental
	case:
		return options, cli_error(diagnostic, "invalid subcommand")
	}

	if options.command == .Help || options.command == .Version || options.command == .Clear {
		return options, true
	}

	for index := 1; index < len(args); index += 1 {
		arg := args[index]
		if !strings.has_prefix(arg, "-") {
			if len(options.filename) != 0 {
				return options, cli_error(diagnostic, "too many filename arguments")
			}
			options.filename = arg
			continue
		}

		name, inline_value := cli_flag_parts(arg)
		switch name {
		case "h", "help": options.command = .Help
		case "W", "watch": options.watch = true
		case "N", "no-color", "no_color": options.no_color = true
		case "E", "exit-err", "exit_err": options.exit_err = true
		case "S", "standalone": options.standalone = true
		case "e", "emit-tex", "emit_tex": options.emit_tex = true
		case "L", "latex":
			if !cli_set_engine(&options, .latex, diagnostic) do return options, false
		case "p", "pdflatex":
			if !cli_set_engine(&options, .pdflatex, diagnostic) do return options, false
		case "x", "xelatex":
			if !cli_set_engine(&options, .xelatex, diagnostic) do return options, false
		case "l", "lualatex":
			if !cli_set_engine(&options, .lualatex, diagnostic) do return options, false
		case "T", "tectonic":
			if !cli_set_engine(&options, .tectonic, diagnostic) do return options, false
		case "lim":
			value, ok := cli_take_value(args, &index, inline_value)
			if !ok {
				return options, cli_error(diagnostic, "--lim requires a value")
			}
			limit, parsed := strconv.parse_int(value, 10)
			if !parsed || limit < 1 {
				return options, cli_error(diagnostic, "compile limit must be a positive integer")
			}
			options.compile_limit = limit
		case "first-script", "first_script":
			value, ok := cli_take_value(args, &index, inline_value)
			if !ok do return options, cli_error(diagnostic, "--first-script requires a path")
			options.first_script = value
		case "before-script", "before_script":
			value, ok := cli_take_value(args, &index, inline_value)
			if !ok do return options, cli_error(diagnostic, "--before-script requires a path")
			options.before_script = value
		case "step-script", "step_script":
			value, ok := cli_take_value(args, &index, inline_value)
			if !ok do return options, cli_error(diagnostic, "--step-script requires a path")
			options.step_script = value
		case:
			return options, cli_error(diagnostic, "unknown command-line option")
		}
	}

	if options.command == .Latex && len(options.filename) == 0 {
		return options, cli_error(diagnostic, "latex filename is required")
	}
	return options, true
}

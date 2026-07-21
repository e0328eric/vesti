package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

main_fail :: proc(diagnostic: ^Diagnostic, no_color := false) {
	if diagnostic != nil {
		diagnostic_pretty_print(diagnostic, no_color)
	}
	os.exit(1)
}

find_first_script_root :: proc(
	filename: string,
	diagnostic: ^Diagnostic,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	if filepath.is_abs(filename) {
		if os.is_file(filename) {
			return true
		}
		_ = diagnostic_setf(
			diagnostic,
			.IO,
			{},
			false,
			"",
			"`%s` is not found",
			filename,
		)
		return false
	}
	directory, cwd_err := os.get_working_directory(allocator)
	if cwd_err != nil {
		_ = diagnostic_set(diagnostic, .IO, "cannot get the current directory")
		return false
	}
	defer delete(directory, allocator)

	for {
		candidate, join_err := filepath.join({directory, filename}, allocator)
		if join_err == nil {
			found := os.is_file(candidate)
			delete(candidate, allocator)
			if found {
				if os.set_working_directory(directory) != nil {
					_ = diagnostic_set(diagnostic, .IO, "cannot enter the Vesti project directory")
					return false
				}
				return true
			}
		}

		parent := filepath.dir(directory)
		if len(parent) == 0 || parent == directory {
			break
		}
		next, clone_err := strings.clone(parent, allocator)
		if clone_err != nil {
			_ = diagnostic_set(diagnostic, .IO, "out of memory searching for first.lua")
			return false
		}
		delete(directory, allocator)
		directory = next
	}
	_ = diagnostic_setf(
		diagnostic,
		.IO,
		{},
		false,
		"run from a Vesti project or pass --standalone with a .ves file",
		"`%s` is not found",
		filename,
	)
	return false
}

INIT_VESTI_SOURCE :: "docclass article\nstartdoc\nHello, World!"

init_first_source :: proc(ves_filename: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"-- below code imports vesti module\n" +
		"-- vesti.getModule(\"module_name\")\n" +
		"vesti.compile(\"%s\", {{ engine = \"tect\", compile_all = true }})",
		ves_filename,
		allocator = allocator,
	)
}

run_init_command :: proc(project: string, diagnostic: ^Diagnostic, allocator := context.allocator) -> bool {
	ves_filename := fmt.aprintf("%s.ves", project, allocator = allocator)
	defer delete(ves_filename, allocator)
	first_source := init_first_source(ves_filename, allocator)
	defer delete(first_source, allocator)
	if err := os.write_entire_file("first.lua", first_source); err != nil {
		_ = diagnostic_set(diagnostic, .IO, "cannot create first.lua")
		return false
	}
	if err := os.write_entire_file(
		ves_filename,
		INIT_VESTI_SOURCE,
	); err != nil {
		_ = diagnostic_setf(
			diagnostic,
			.IO,
			{},
			false,
			"",
			"cannot create %s",
			ves_filename,
		)
		return false
	}
	return true
}

compiler_watch_stamp :: proc(
	main_filename: string,
	compile_all: bool,
	allocator := context.allocator,
) -> i64 {
	latest: i64
	if compile_all {
		files, ok := discover_vesti_files(".", allocator)
		if !ok {
			return latest
		}
		defer compiler_path_list_deinit(&files, allocator)
		for filename in files {
			modified, err := os.modification_time_by_path(filename)
			if err == nil {
				latest = max(latest, time.to_unix_nanoseconds(modified))
			}
		}
	} else {
		modified, err := os.modification_time_by_path(main_filename)
		if err == nil {
			latest = time.to_unix_nanoseconds(modified)
		}
	}
	return latest
}

wait_for_project_change :: proc(previous: i64, main_filename: string, compile_all: bool) {
	for {
		time.sleep(200 * time.Millisecond)
		current := compiler_watch_stamp(main_filename, compile_all)
		if current > previous {
			return
		}
	}
}

run_compile_command :: proc(
	options: Cli_Options,
	diagnostic: ^Diagnostic,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	config, config_ok := config_load(diagnostic, allocator)
	if !config_ok {
		return false
	}
	engine := config.engine
	if options.has_engine {
		engine = options.engine
	}

	lua_runtime: Lua_Runtime
	if !lua_runtime_init(
		&lua_runtime,
		engine,
		config,
		diagnostic,
		allocator,
		compiler_lua_parse,
		&lua_runtime,
	) {
		return false
	}
	defer lua_runtime_deinit(&lua_runtime)
	lua_runtime.attr.watch = options.watch
	lua_runtime.attr.no_color = options.no_color
	lua_runtime.attr.no_exit_err = !options.exit_err

	if options.standalone {
		lua_runtime.attr.compile_all = false
	} else {
		if len(options.filename) == 0 &&
		   !find_first_script_root(options.first_script, diagnostic, allocator) {
			return false
		}
		lua_runtime.is_first_script = true
		first_ok := lua_runtime_run_file(&lua_runtime, options.first_script, true)
		lua_runtime.is_first_script = false
		if !first_ok {
			return false
		}
		engine = lua_runtime.engine
	}

	main_filename := options.filename
	if len(main_filename) == 0 {
		main_filename = lua_runtime.main_ves
	}
	if len(main_filename) == 0 {
		_ = diagnostic_set(
			diagnostic,
			.IO,
			"no main Vesti file was provided",
			{},
			false,
			"call vesti.compile in first.lua or pass a filename",
		)
		return false
	}

	request := compiler_request_default(main_filename, &engine, diagnostic, allocator)
	request.compile_limit = options.compile_limit
	request.compile_all = lua_runtime.attr.compile_all
	request.emit_tex = options.emit_tex
	request.before_script = options.before_script
	request.step_script = options.step_script
	request.lua_runtime = &lua_runtime

	for {
		stamp := compiler_watch_stamp(main_filename, request.compile_all, allocator)
		diagnostic.lock_print_at_main = false
		if compiler_compile_once(&request) {
			if !lua_runtime.attr.watch {
				return true
			}
			fmt.println("Ctrl+C to quit...")
		} else {
			if !lua_runtime.attr.watch {
				return false
			}
			diagnostic_pretty_print(diagnostic, lua_runtime.attr.no_color)
			diagnostic.lock_print_at_main = true
			if !lua_runtime.attr.no_exit_err do return false
			diagnostic_clear_error(diagnostic)
			diagnostic.lock_print_at_main = false
			fmt.println("Ctrl+C to quit...")
		}
		wait_for_project_change(stamp, main_filename, request.compile_all)
	}
}

run_latex_command :: proc(
	options: Cli_Options,
	diagnostic: ^Diagnostic,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	if filepath.ext(options.filename) != ".tex" {
		_ = diagnostic_set(diagnostic, .IO, "latex input must have the .tex extension")
		return false
	}
	absolute, err := filepath.abs(options.filename, allocator)
	if err != nil || !os.is_file(absolute) {
		if err == nil do delete(absolute, allocator)
		_ = diagnostic_set(diagnostic, .IO, "failed to open the LaTeX input file")
		return false
	}
	defer delete(absolute, allocator)
	directory := filepath.dir(absolute)
	filename := filepath.base(absolute)
	for {
		modified, stat_err := os.modification_time_by_path(absolute)
		stamp: i64
		if stat_err == nil do stamp = time.to_unix_nanoseconds(modified)
		if !run_latex_engine(
			.tectonic,
			filename,
			directory,
			options.compile_limit,
			diagnostic,
			allocator,
		) {
			if !options.watch do return false
			diagnostic_pretty_print(diagnostic, options.no_color)
			diagnostic.lock_print_at_main = true
			diagnostic_clear_error(diagnostic)
			diagnostic.lock_print_at_main = false
		} else if !options.watch {
			return true
		}
		fmt.println("Ctrl+C to quit...")
		for {
			time.sleep(200 * time.Millisecond)
			current, current_err := os.modification_time_by_path(absolute)
			if current_err == nil && time.to_unix_nanoseconds(current) > stamp do break
		}
	}
}

run_experimental_command :: proc(
	filename: string,
	diagnostic: ^Diagnostic,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	if len(filename) == 0 {
		_ = diagnostic_set(diagnostic, .IO, "experimental requires a Vesti filename")
		return false
	}
	bytes, err := os.read_entire_file(filename, allocator)
	if err != nil {
		_ = diagnostic_set(diagnostic, .IO, "failed to open the experimental input file")
		return false
	}
	defer delete(bytes, allocator)
	preprocessor, init_err := preprocessor_init(
		string(bytes),
		filepath.dir(filename),
		diagnostic,
		allocator,
	)
	if init_err != nil do return false
	defer preprocessor_deinit(&preprocessor)
	tokens, ok := preprocessor_process(&preprocessor)
	if !ok do return false
	defer token_list_deinit(&tokens, allocator)
	for token in tokens.items {
		fmt.printf("Token: %v\n", token)
	}
	return true
}

main :: proc() {
	diagnostic := diagnostic_init()
	defer diagnostic_deinit(&diagnostic)
	options, parsed := cli_parse(os.args[1:], &diagnostic)
	if !parsed {
		main_fail(&diagnostic, true)
	}

	switch options.command {
	case .Help:
		fmt.println(VESTI_HELP)
	case .Version:
		fmt.println("vesti " + VESTI_VERSION)
	case .Init:
		if !run_init_command(options.project, &diagnostic) do main_fail(&diagnostic, true)
	case .Clear:
		if os.remove_all(VESTI_DUMMY_DIR) != nil {
			_ = diagnostic_set(&diagnostic, .IO, "cannot remove .vesti-dummy")
			main_fail(&diagnostic, true)
		}
		fmt.println("[successfully removed " + VESTI_DUMMY_DIR + "]")
	case .Compile:
		if !run_compile_command(options, &diagnostic) {
			if !diagnostic.lock_print_at_main do main_fail(&diagnostic, options.no_color)
			os.exit(1)
		}
	case .Latex:
		if !run_latex_command(options, &diagnostic) {
			if !diagnostic.lock_print_at_main do main_fail(&diagnostic, options.no_color)
			os.exit(1)
		}
	case .Experimental:
		if !run_experimental_command(options.filename, &diagnostic) do main_fail(&diagnostic, true)
	}
}

package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import lua "vendor:lua/5.4"
import rt "base:runtime"

Compile_Attribute :: struct {
	compile_all:           bool,
	watch:                 bool,
	no_color:              bool,
	no_exit_err:           bool,
	engine_already_changed: bool,
}

Lua_Parse_Proc :: #type proc(
	source: string,
	output: ^strings.Builder,
	user_data: rawptr,
) -> bool

Lua_Runtime :: struct {
	state:           ^lua.State,
	allocator:       mem.Allocator,
	diagnostic:      ^Diagnostic,
	engine:          Latex_Engine,
	make_log:        bool,
	line_limit:      int,
	is_first_script: bool,
	main_ves:        string,
	attr:            Compile_Attribute,
	output:          strings.Builder,
	parse_proc:      Lua_Parse_Proc,
	parse_user_data: rawptr,
}

lua_push_string :: proc "c" (state: ^lua.State, value: string) {
	if len(value) == 0 {
		_ = lua.pushstring(state, "")
		return
	}
	_ = lua.pushlstring(state, cstring(raw_data(value)), c.size_t(len(value)))
}

lua_get_string :: proc "c" (state: ^lua.State, index: c.int) -> (string, bool) {
	length: c.size_t
	value := lua.tolstring(state, index, &length)
	if value == nil {
		return "", false
	}
	return string(value)[:int(length)], true
}

lua_raise :: proc "c" (state: ^lua.State, message: string) -> c.int {
	lua_push_string(state, message)
	return c.int(lua.error(state))
}

lua_self :: proc "c" (state: ^lua.State) -> ^Lua_Runtime {
	return (^Lua_Runtime)(lua.touserdata(state, lua.REGISTRYINDEX-1))
}

lua_register_method :: proc "c" (
	state: ^lua.State,
	runtime: ^Lua_Runtime,
	name: cstring,
	callback: lua.CFunction,
) {
	lua.pushlightuserdata(state, runtime)
	lua.pushcclosure(state, callback, 1)
	lua.setfield(state, -2, name)
}

lua_runtime_init :: proc(
	runtime: ^Lua_Runtime,
	engine: Latex_Engine,
	config: Config,
	diagnostic: ^Diagnostic,
	allocator: mem.Allocator = context.allocator,
	parse_proc: Lua_Parse_Proc = nil,
	parse_user_data: rawptr = nil,
) -> bool {
	assert(runtime != nil)
	runtime^ = Lua_Runtime{
		allocator       = allocator,
		diagnostic      = diagnostic,
		engine          = engine,
		make_log        = config.lua.make_log,
		line_limit      = config.lua.line_limit,
		attr            = {compile_all = true},
		output          = strings.builder_make(allocator = allocator),
		parse_proc      = parse_proc,
		parse_user_data = parse_user_data,
	}
	runtime.state = lua.L_newstate()
	if runtime.state == nil {
		strings.builder_destroy(&runtime.output)
		if diagnostic != nil {
			_ = diagnostic_set(diagnostic, .Lua, "cannot initialize Lua 5.4")
		}
		return false
	}

	lua.L_openlibs(runtime.state)
	lua.newtable(runtime.state)
	lua_register_method(runtime.state, runtime, "compile", lua_compile_callback)
	lua_register_method(runtime.state, runtime, "download", lua_download_callback)
	lua_register_method(runtime.state, runtime, "getCurrentDir", lua_get_current_dir_callback)
	lua_register_method(runtime.state, runtime, "getEngineType", lua_get_engine_callback)
	lua_register_method(runtime.state, runtime, "getModule", lua_get_module_callback)
	lua_register_method(runtime.state, runtime, "joinpath", lua_joinpath_callback)
	lua_register_method(runtime.state, runtime, "mkdir", lua_mkdir_callback)
	lua_register_method(runtime.state, runtime, "parse", lua_parse_callback)
	lua_register_method(runtime.state, runtime, "ping", lua_ping_callback)
	lua_register_method(runtime.state, runtime, "print", lua_print_callback)
	lua_register_method(runtime.state, runtime, "setCurrentDir", lua_set_current_dir_callback)
	lua_register_method(runtime.state, runtime, "unzip", lua_unzip_callback)
	lua_register_method(runtime.state, runtime, "vestiDummyDir", lua_dummy_dir_callback)
	lua.setglobal(runtime.state, "vesti")
	return true
}

lua_runtime_deinit :: proc(runtime: ^Lua_Runtime) {
	if runtime == nil {
		return
	}
	if runtime.state != nil {
		lua.close(runtime.state)
	}
	if len(runtime.main_ves) > 0 {
		delete(runtime.main_ves, runtime.allocator)
	}
	strings.builder_destroy(&runtime.output)
	runtime^ = {}
}

lua_error_source_note :: proc(runtime: ^Lua_Runtime, code, filename: string) -> string {
	trimmed := strings.trim(code, " \t\r\n")
	should_log := runtime.make_log ||
	              strings.count(trimmed, "\n") >= runtime.line_limit
	if should_log {
		if os.make_directory_all(VESTI_DUMMY_DIR) == nil {
			log_path, path_err := filepath.join(
				{VESTI_DUMMY_DIR, "luacode.lua"},
				runtime.allocator,
			)
			if path_err == nil {
				write_err := os.write_entire_file(log_path, trimmed)
				if write_err == nil {
					note := fmt.aprintf(
						"Lua source from %s was stored in %s",
						filename,
						log_path,
						allocator = runtime.allocator,
					)
					delete(log_path, runtime.allocator)
					return note
				}
				delete(log_path, runtime.allocator)
			}
		}
	}

	note := strings.builder_make(allocator = runtime.allocator)
	defer strings.builder_destroy(&note)
	_ = fmt.sbprintf(&note, "Lua source from %s:\n", filename)
	remaining := trimmed
	line_number := 1
	for line in strings.split_lines_iterator(&remaining) {
		_ = fmt.sbprintf(&note, "%d | %s\n", line_number, line)
		line_number += 1
	}
	copy, clone_err := strings.clone(strings.to_string(note), runtime.allocator)
	if clone_err != nil {
		return ""
	}
	return copy
}

lua_runtime_eval :: proc(runtime: ^Lua_Runtime, code: string, filename := "<luacode>") -> bool {
	if runtime == nil || runtime.state == nil {
		return false
	}
	c_code, alloc_err := strings.clone_to_cstring(code, runtime.allocator)
	if alloc_err != nil {
		if runtime.diagnostic != nil {
			_ = diagnostic_set(runtime.diagnostic, .Lua, "out of memory preparing Lua code")
		}
		return false
	}
	defer delete(string(c_code), runtime.allocator)

	status := lua.L_dostring(runtime.state, c_code)
	if lua.Status(status) != .OK {
		message, ok := lua_get_string(runtime.state, -1)
		if !ok {
			message = "unknown Lua error"
		}
		note := lua_error_source_note(runtime, code, filename)
		defer if len(note) > 0 do delete(note, runtime.allocator)
		if runtime.diagnostic != nil && runtime.diagnostic.kind == .None {
			_ = diagnostic_setf(
				runtime.diagnostic,
				.Lua,
				{},
				false,
				note,
				"lua exception occurred: %s",
				message,
			)
		}
		lua.pop(runtime.state, 1)
		return false
	}
	return true
}

lua_runtime_run_file :: proc(
	runtime: ^Lua_Runtime,
	filename: string,
	required := false,
) -> bool {
	if !os.is_file(filename) {
		if !required {
			return true
		}
		if runtime.diagnostic != nil {
			_ = diagnostic_setf(
				runtime.diagnostic,
				.IO,
				{},
				false,
				"",
				"cannot open Lua script %s",
				filename,
			)
		}
		return false
	}
	contents, err := os.read_entire_file(filename, runtime.allocator)
	if err != nil {
		if runtime.diagnostic != nil {
			_ = diagnostic_setf(
				runtime.diagnostic,
				.IO,
				{},
				false,
				"",
				"cannot read Lua script %s",
				filename,
			)
		}
		return false
	}
	defer delete(contents, runtime.allocator)
	return lua_runtime_eval(runtime, string(contents), filename)
}

lua_codegen_evaluate :: proc(
	code: string,
	output: ^strings.Builder,
	user_data: rawptr,
) -> bool {
	runtime := (^Lua_Runtime)(user_data)
	if runtime == nil {
		return false
	}
	strings.builder_reset(&runtime.output)
	if !lua_runtime_eval(runtime, code) {
		return false
	}
	_ = strings.write_string(output, strings.to_string(runtime.output))
	strings.builder_reset(&runtime.output)
	return true
}

lua_optional_bool :: proc "c" (
	state: ^lua.State,
	table_index: c.int,
	key: cstring,
	current: bool,
) -> (bool, bool) {
	type := lua.Type(lua.getfield(state, table_index, key))
	defer lua.pop(state, 1)
	#partial switch type {
	case .NIL:     return current, true
	case .BOOLEAN: return bool(lua.toboolean(state, -1)), true
	case:          return current, false
	}
}

lua_compile_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	runtime := lua_self(state)
	if runtime == nil {
		return lua_raise(state, "missing Vesti Lua context")
	}
	if !runtime.is_first_script {
		return lua_raise(state, "cannot use vesti.compile outside of first.lua")
	}
	nargs := lua.gettop(state)
	if nargs < 1 || nargs > 2 {
		return lua_raise(state, "usage: vesti.compile(<main_ves>, {config}?)")
	}
	main_ves, ok := lua_get_string(state, 1)
	if !ok || len(main_ves) == 0 {
		return lua_raise(state, "the first vesti.compile argument must be a filename")
	}

	attr := runtime.attr
	engine := runtime.engine
	if nargs == 2 {
		if !lua.istable(state, 2) {
			return lua_raise(state, "the second vesti.compile argument must be a table")
		}
		if attr.compile_all, ok = lua_optional_bool(state, 2, "compile_all", attr.compile_all); !ok {
			return lua_raise(state, "compile_all must be a boolean")
		}
		if attr.watch, ok = lua_optional_bool(state, 2, "watch", attr.watch); !ok {
			return lua_raise(state, "watch must be a boolean")
		}
		if attr.no_color, ok = lua_optional_bool(state, 2, "no_color", attr.no_color); !ok {
			return lua_raise(state, "no_color must be a boolean")
		}
		if attr.no_exit_err, ok = lua_optional_bool(state, 2, "no_exit_err", attr.no_exit_err); !ok {
			return lua_raise(state, "no_exit_err must be a boolean")
		}

		engine_type := lua.Type(lua.getfield(state, 2, "engine"))
		#partial switch engine_type {
		case .NIL:
		case .STRING:
			engine_name, _ := lua_get_string(state, -1)
			parsed: bool
			engine, parsed = latex_engine_parse(engine_name)
			if !parsed {
				lua.pop(state, 1)
				return lua_raise(state, "engine must be latex, pdf, xe, lua, or tect")
			}
			attr.engine_already_changed = true
		case:
			lua.pop(state, 1)
			return lua_raise(state, "engine must be a string")
		}
		lua.pop(state, 1)
	}

	copy, clone_err := strings.clone(main_ves, runtime.allocator)
	if clone_err != nil {
		return lua_raise(state, "out of memory recording the main Vesti file")
	}
	if len(runtime.main_ves) > 0 {
		delete(runtime.main_ves, runtime.allocator)
	}
	runtime.main_ves = copy
	runtime.attr = attr
	runtime.engine = engine
	return 0
}

lua_dummy_dir_callback :: proc "c" (state: ^lua.State) -> c.int {
	lua_push_string(state, VESTI_DUMMY_DIR)
	return 1
}

lua_get_current_dir_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	runtime := lua_self(state)
	if runtime == nil do return lua_raise(state, "missing Vesti Lua context")
	directory, err := os.get_working_directory(runtime.allocator)
	if err != nil do return lua_raise(state, "cannot get the current directory")
	lua_push_string(state, directory)
	delete(directory, runtime.allocator)
	return 1
}

lua_set_current_dir_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	if lua.gettop(state) != 1 do return lua_raise(state, "usage: vesti.setCurrentDir(<directory>)")
	directory, ok := lua_get_string(state, 1)
	if !ok do return lua_raise(state, "directory must be a string")
	if err := os.set_working_directory(directory); err != nil {
		return lua_raise(state, "failed to change the current directory")
	}
	return 0
}

lua_get_engine_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	runtime := lua_self(state)
	if runtime == nil do return lua_raise(state, "missing Vesti Lua context")
	lua_push_string(state, latex_engine_string(runtime.engine))
	return 1
}

lua_get_module_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	runtime := lua_self(state)
	if runtime == nil do return lua_raise(state, "missing Vesti Lua context")
	if lua.gettop(state) != 1 do return lua_raise(state, "usage: vesti.getModule(<module>)")
	name, ok := lua_get_string(state, 1)
	if !ok do return lua_raise(state, "module name must be a string")
	if !download_module(name, diagnostic = runtime.diagnostic, allocator = runtime.allocator) {
		return lua_raise(state, "cannot get the requested Vesti module")
	}
	return 0
}

lua_mkdir_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	if lua.gettop(state) != 1 do return lua_raise(state, "usage: vesti.mkdir(<directory>)")
	directory, ok := lua_get_string(state, 1)
	if !ok do return lua_raise(state, "directory must be a string")
	if err := os.make_directory_all(directory); err != nil {
		return lua_raise(state, "failed to make the directory")
	}
	return 0
}

lua_joinpath_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	runtime := lua_self(state)
	if runtime == nil do return lua_raise(state, "missing Vesti Lua context")
	nargs := int(lua.gettop(state))
	if nargs == 0 do return lua_raise(state, "usage: vesti.joinpath(...)")
	parts := make([dynamic]string, 0, nargs, runtime.allocator)
	for index in 1 ..= nargs {
		part, ok := lua_get_string(state, c.int(index))
		if !ok {
			delete(parts)
			return lua_raise(state, "path components must be strings")
		}
		append(&parts, part)
	}
	joined, err := filepath.join(parts[:], runtime.allocator)
	delete(parts)
	if err != nil do return lua_raise(state, "failed to join path components")
	lua_push_string(state, joined)
	delete(joined, runtime.allocator)
	return 1
}

lua_print_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	runtime := lua_self(state)
	if runtime == nil do return lua_raise(state, "missing Vesti Lua context")
	nargs := int(lua.gettop(state))
	if nargs == 0 do return lua_raise(state, "usage: vesti.print(..., {sep=..., nl=...}?)")
	sep := " "
	newlines := 1
	if lua.istable(state, c.int(nargs)) {
		sep_type := lua.Type(lua.getfield(state, c.int(nargs), "sep"))
		if sep_type == .STRING {
			sep, _ = lua_get_string(state, -1)
		} else if sep_type != .NIL {
			lua.pop(state, 1)
			return lua_raise(state, "sep must be a string")
		}
		lua.pop(state, 1)

		nl_type := lua.Type(lua.getfield(state, c.int(nargs), "nl"))
		if nl_type == .NUMBER {
			is_number: b32
			value := lua.tointeger(state, -1, &is_number)
			if !is_number || value < 0 {
				lua.pop(state, 1)
				return lua_raise(state, "nl must be a nonnegative integer")
			}
			newlines = min(int(value), 2)
		} else if nl_type != .NIL {
			lua.pop(state, 1)
			return lua_raise(state, "nl must be a nonnegative integer")
		}
		lua.pop(state, 1)
		nargs -= 1
	}

	for index in 1 ..= nargs {
		value, ok := lua_get_string(state, c.int(index))
		if !ok do return lua_raise(state, "values passed to vesti.print must be strings or numbers")
		if index > 1 do _ = strings.write_string(&runtime.output, sep)
		_ = strings.write_string(&runtime.output, value)
	}
	for _ in 0 ..< newlines {
		_ = strings.write_byte(&runtime.output, '\n')
	}
	return 0
}

lua_parse_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	runtime := lua_self(state)
	if runtime == nil do return lua_raise(state, "missing Vesti Lua context")
	if lua.gettop(state) != 1 do return lua_raise(state, "usage: vesti.parse(<Vesti source>)")
	source, ok := lua_get_string(state, 1)
	if !ok do return lua_raise(state, "Vesti source must be a string")
	if runtime.parse_proc == nil do return lua_raise(state, "vesti.parse is unavailable in this context")
	output := strings.builder_make(allocator = runtime.allocator)
	if !runtime.parse_proc(source, &output, runtime.parse_user_data) {
		strings.builder_destroy(&output)
		return lua_raise(state, "failed to parse Vesti source")
	}
	lua_push_string(state, strings.to_string(output))
	strings.builder_destroy(&output)
	return 1
}

process_exited_successfully :: proc(state: os.Process_State, err: os.Error) -> bool {
	return err == nil && state.exited && state.exit_code == 0
}

lua_process_success :: proc(command: []string, allocator: mem.Allocator) -> bool {
	state, stdout, stderr, err := os.process_exec({command = command}, allocator)
	defer delete(stdout, allocator)
	defer delete(stderr, allocator)
	return process_exited_successfully(state, err)
}

lua_download_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	runtime := lua_self(state)
	if runtime == nil do return lua_raise(state, "missing Vesti Lua context")
	if lua.gettop(state) != 2 do return lua_raise(state, "usage: vesti.download(<url>, <filename>)")
	url, url_ok := lua_get_string(state, 1)
	filename, file_ok := lua_get_string(state, 2)
	if !url_ok || !file_ok do return lua_raise(state, "url and filename must be strings")
	command := [?]string{"curl", "-L", "--fail", "--silent", "--show-error", "-o", filename, url}
	if !lua_process_success(command[:], runtime.allocator) {
		return lua_raise(state, "download failed")
	}
	return 0
}

lua_ping_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	runtime := lua_self(state)
	if runtime == nil do return lua_raise(state, "missing Vesti Lua context")
	if lua.gettop(state) != 1 do return lua_raise(state, "usage: vesti.ping(<url>)")
	url, ok := lua_get_string(state, 1)
	if !ok do return lua_raise(state, "url must be a string")
	command := [?]string{"curl", "-L", "--fail", "--silent", "--head", url}
	lua.pushboolean(state, b32(lua_process_success(command[:], runtime.allocator)))
	return 1
}

lua_unzip_callback :: proc "c" (state: ^lua.State) -> c.int {
	context = rt.default_context()
	runtime := lua_self(state)
	if runtime == nil do return lua_raise(state, "missing Vesti Lua context")
	if lua.gettop(state) != 2 do return lua_raise(state, "usage: vesti.unzip(<archive>, <directory>)")
	filename, file_ok := lua_get_string(state, 1)
	directory, dir_ok := lua_get_string(state, 2)
	if !file_ok || !dir_ok do return lua_raise(state, "archive and directory must be strings")
	command := [?]string{"tar", "-xf", filename, "-C", directory}
	ok := lua_process_success(command[:], runtime.allocator)
	lua.pushboolean(state, b32(ok))
	return 1
}

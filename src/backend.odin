package main

import "core:dynlib"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"

tectonic_library_name :: proc() -> string {
	when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
		return "vesti_tectonic_x86_64.dll"
	} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		return "libvesti_tectonic_x86_64_gnu.so"
	} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
		return "libvesti_tectonic.dylib"
	} else {
		return ""
	}
}

Tectonic_Compile_Proc :: #type proc "c" (
	latex_filename: rawptr,
	latex_filename_len: uintptr,
	filesystem_root: rawptr,
	filesystem_root_len: uintptr,
	compile_limit: uintptr,
) -> bool

run_tectonic :: proc(
	latex_filename: string,
	filesystem_root: string,
	compile_limit: int,
	diagnostic: ^Diagnostic,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	library_name := tectonic_library_name()
	if len(library_name) == 0 {
		_ = diagnostic_set(
			diagnostic,
			.Backend,
			fmt.tprintf("no bundled Tectonic bridge supports %v/%v", ODIN_OS, ODIN_ARCH),
		)
		return false
	}
	executable_dir, executable_err := os.get_executable_directory(allocator)
	if executable_err != nil {
		_ = diagnostic_set(diagnostic, .Backend, "cannot determine the vesti executable directory")
		return false
	}
	defer delete(executable_dir, allocator)

	library_path, path_err := filepath.join(
		{executable_dir, library_name},
		allocator,
	)
	if path_err != nil {
		_ = diagnostic_set(diagnostic, .Backend, "cannot construct the Tectonic library path")
		return false
	}
	defer delete(library_path, allocator)
	if !os.is_file(library_path) {
		fallback, fallback_err := filepath.join(
			{"vesti-tectonic", "bin", library_name},
			allocator,
		)
		if fallback_err == nil {
			if os.is_file(fallback) {
				delete(library_path, allocator)
				library_path = fallback
			} else {
				delete(fallback, allocator)
			}
		}
	}

	library, loaded := dynlib.load_library(library_path, allocator = allocator)
	if !loaded {
		note := fmt.aprintf(
			"the bridge library must be beside the vesti executable (%s)",
			library_path,
			allocator = allocator,
		)
		defer delete(note, allocator)
		_ = diagnostic_set(
			diagnostic,
			.Backend,
			"cannot load the Tectonic bridge",
			{},
			false,
			note,
		)
		return false
	}
	defer {
		_ = dynlib.unload_library(library)
	}

	symbol, found := dynlib.symbol_address(
		library,
		"compile_latex_with_tectonic",
		allocator,
	)
	if !found {
		_ = diagnostic_set(
			diagnostic,
			.Backend,
			"the Tectonic bridge is missing compile_latex_with_tectonic",
		)
		return false
	}
	compile := cast(Tectonic_Compile_Proc)symbol
	if !compile(
		raw_data(latex_filename),
		uintptr(len(latex_filename)),
		raw_data(filesystem_root),
		uintptr(len(filesystem_root)),
		uintptr(compile_limit),
	) {
		_ = diagnostic_set(
			diagnostic,
			.Backend,
			"Tectonic failed while processing the generated TeX file",
			{},
			false,
			"see the Tectonic log in the build directory",
		)
		return false
	}
	return true
}

run_latex_engine :: proc(
	engine: Latex_Engine,
	main_tex_file: string,
	working_directory: string,
	compile_limit: int,
	diagnostic: ^Diagnostic,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	if engine == .tectonic {
		joined, join_err := filepath.join({working_directory, main_tex_file}, allocator)
		if join_err != nil {
			_ = diagnostic_set(diagnostic, .Backend, "cannot construct generated TeX path")
			return false
		}
		defer delete(joined, allocator)
		absolute_input, input_err := filepath.abs(joined, allocator)
		if input_err != nil {
			_ = diagnostic_set(diagnostic, .Backend, "cannot resolve generated TeX path")
			return false
		}
		defer delete(absolute_input, allocator)
		absolute_root, root_err := filepath.abs(working_directory, allocator)
		if root_err != nil {
			_ = diagnostic_set(diagnostic, .Backend, "cannot resolve the TeX working directory")
			return false
		}
		defer delete(absolute_root, allocator)
		// The bridge currently uses one string both as the physical input path
		// and as TeX's logical job name. Passing an absolute Windows path leaks
		// backslashes such as `\tmp` into auxiliary data. Run the in-process
		// bridge from the output directory and give it only the input basename.
		previous_directory, previous_err := os.get_working_directory(allocator)
		if previous_err != nil {
			_ = diagnostic_set(diagnostic, .Backend, "cannot determine the current working directory")
			return false
		}
		defer delete(previous_directory, allocator)
		if directory_err := os.set_working_directory(absolute_root); directory_err != nil {
			_ = diagnostic_set(diagnostic, .Backend, "cannot enter the TeX working directory")
			return false
		}
		defer {
			_ = os.set_working_directory(previous_directory)
		}
		tectonic_root, root_separator_err := os.replace_path_separators(
			absolute_root,
			'/',
			allocator,
		)
		if root_separator_err != nil {
			_ = diagnostic_set(diagnostic, .Backend, "cannot normalize the TeX working directory")
			return false
		}
		defer delete(tectonic_root, allocator)
		return run_tectonic(
			filepath.base(absolute_input),
			tectonic_root,
			compile_limit,
			diagnostic,
			allocator,
		)
	}

	for pass in 1 ..= compile_limit {
		fmt.printf("[compile number %d, engine: %s]\n", pass, latex_engine_string(engine))
		state, stdout, stderr, process_err := os.process_exec(
			{
				working_dir = working_directory,
				command = {latex_engine_string(engine), "-halt-on-error", main_tex_file},
			},
			allocator,
		)
		defer delete(stdout, allocator)
		defer delete(stderr, allocator)
		stdout_path, stdout_path_err := filepath.join(
			{working_directory, "stdout.txt"},
			context.temp_allocator,
		)
		if stdout_path_err == nil {
			_ = os.write_entire_file(stdout_path, stdout)
		}
		stderr_path, stderr_path_err := filepath.join(
			{working_directory, "stderr.txt"},
			context.temp_allocator,
		)
		if stderr_path_err == nil {
			_ = os.write_entire_file(stderr_path, stderr)
		}
		if !process_exited_successfully(state, process_err) {
			note := string(stdout)
			if len(note) == 0 {
				note = string(stderr)
			}
			_ = diagnostic_setf(
				diagnostic,
				.Backend,
				{},
				false,
				note,
				"%s failed while processing %s",
				latex_engine_string(engine),
				main_tex_file,
			)
			return false
		}
		fmt.println("[compiled]")
	}
	return true
}

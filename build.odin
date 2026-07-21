package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""
GENERATOR_EXE :: "build/unicode_gen" + EXE_SUFFIX
APP_EXE :: "build/vesti" + EXE_SUFFIX
GENERATED_TABLES :: "src/uucode/generated_tables.odin"

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

Install_Path_Style :: enum {
	Windows,
	Posix,
}

Install_Path_Environment :: struct {
	user_profile: string,
	app_data:     string,
	home:         string,
}

Install_Path_Error :: enum {
	None,
	Empty_Path,
	Missing_User_Profile,
	Missing_App_Data,
	Missing_Home,
	Unsupported_Home_Syntax,
	Allocation_Failure,
}

install_has_windows_marker :: proc(path, marker: string) -> bool {
	if len(path) < len(marker) || !strings.equal_fold(path[:len(marker)], marker) {
		return false
	}
	return len(path) == len(marker) || path[len(marker)] == '/' || path[len(marker)] == '\\'
}

install_expand_path :: proc(
	path: string,
	style: Install_Path_Style,
	environment: Install_Path_Environment,
	allocator := context.allocator,
) -> (expanded: string, err: Install_Path_Error) {
	if len(path) == 0 {
		return "", .Empty_Path
	}

	if style == .Windows {
		markers := [?]struct {
			text:          string,
			value:         string,
			missing_error: Install_Path_Error,
		}{
			{"%USERPROFILE%", environment.user_profile, .Missing_User_Profile},
			{"%APPDATA%", environment.app_data, .Missing_App_Data},
		}
		for marker in markers {
			if install_has_windows_marker(path, marker.text) {
				if len(marker.value) == 0 {
					return "", marker.missing_error
				}
				value, allocation_error := strings.concatenate(
					{marker.value, path[len(marker.text):]},
					allocator,
				)
				if allocation_error != nil {
					return "", .Allocation_Failure
				}
				return value, .None
			}
		}
	} else if path[0] == '~' {
		if len(path) != 1 && path[1] != '/' {
			return "", .Unsupported_Home_Syntax
		}
		if len(environment.home) == 0 {
			return "", .Missing_Home
		}
		value, allocation_error := strings.concatenate(
			{environment.home, path[1:]},
			allocator,
		)
		if allocation_error != nil {
			return "", .Allocation_Failure
		}
		return value, .None
	}

	value, allocation_error := strings.clone(path, allocator)
	if allocation_error != nil {
		return "", .Allocation_Failure
	}
	return value, .None
}

install_expand_native_path :: proc(
	path: string,
	allocator := context.allocator,
) -> (expanded: string, err: Install_Path_Error) {
	environment: Install_Path_Environment
	when ODIN_OS == .Windows {
		environment.user_profile, _ = os.lookup_env("USERPROFILE", context.temp_allocator)
		environment.app_data, _ = os.lookup_env("APPDATA", context.temp_allocator)
		return install_expand_path(path, .Windows, environment, allocator)
	} else {
		environment.home, _ = os.lookup_env("HOME", context.temp_allocator)
		return install_expand_path(path, .Posix, environment, allocator)
	}
}

install_path_error_message :: proc(err: Install_Path_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Empty_Path:
		return "the install directory cannot be empty"
	case .Missing_User_Profile:
		return "USERPROFILE is unset or empty"
	case .Missing_App_Data:
		return "APPDATA is unset or empty"
	case .Missing_Home:
		return "HOME is unset or empty"
	case .Unsupported_Home_Syntax:
		return "only ~ and ~/... home paths are supported"
	case .Allocation_Failure:
		return "not enough memory to expand the install directory"
	}
	return "invalid install directory"
}

UNICODE_INPUTS :: [?]string{
	"data/UnicodeData.txt",
	"data/DerivedCoreProperties.txt",
	"data/DerivedEastAsianWidth.txt",
	"data/GraphemeBreakProperty.txt",
}

INTEGRATION_TEST_FILES :: [?]string{
	"tests/codegen_test.odin",
	"tests/compiler_paths_test.odin",
	"tests/config_test.odin",
	"tests/data_formats_test.odin",
	"tests/defkind_test.odin",
	"tests/integration_qa_test.odin",
	"tests/lexer_test.odin",
	"tests/lua_runtime_test.odin",
	"tests/parser_test.odin",
	"tests/preprocessor_test.odin",
}

odin_command :: proc() -> string {
	value := os.get_env("ODIN", context.temp_allocator)
	if len(value) != 0 {
		return value
	}
	when ODIN_OS == .Windows {
		if profile, found := os.lookup_env("USERPROFILE", context.temp_allocator); found {
			candidate, err := filepath.join(
				{profile, ".local", "Odin", "odin.exe"},
				context.temp_allocator,
			)
			if err == nil && os.is_file(candidate) {
				return candidate
			}
		}
	}
	return "odin"
}

run_command :: proc(command: []string) -> bool {
	fmt.print("+ ")
	for arg, index in command {
		if index != 0 {
			fmt.print(" ")
		}
		fmt.print(arg)
	}
	fmt.println()

	process, start_err := os.process_start({
		command = command,
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
	})
	if start_err != nil {
		fmt.eprintfln("build: cannot start %s: %v", command[0], start_err)
		return false
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintfln("build: waiting for %s failed: %v", command[0], wait_err)
		return false
	}
	return state.exited && state.exit_code == 0
}

needs_rebuild :: proc(output: string, inputs: []string) -> bool {
	output_time, output_err := os.modification_time_by_path(output)
	if output_err != nil {
		return true
	}
	output_ns := time.to_unix_nanoseconds(output_time)
	for input in inputs {
		input_time, input_err := os.modification_time_by_path(input)
		if input_err != nil {
			fmt.eprintfln("build: cannot stat required input %s: %v", input, input_err)
			return true
		}
		if time.to_unix_nanoseconds(input_time) > output_ns {
			return true
		}
	}
	return false
}

ensure_build_directory :: proc() -> bool {
	if err := os.make_directory_all("build"); err != nil && err != .Exist {
		fmt.eprintfln("build: cannot create build directory: %v", err)
		return false
	}
	if !os.is_dir("build") {
		fmt.eprintln("build: build exists but is not a directory")
		return false
	}
	return true
}

install_runtime_libraries :: proc() -> bool {
	if !ensure_build_directory() {
		return false
	}
	library_name := tectonic_library_name()
	if len(library_name) == 0 {
		fmt.eprintfln(
			"build: no bundled Tectonic bridge supports %v/%v",
			ODIN_OS,
			ODIN_ARCH,
		)
		return false
	}
	source := fmt.tprintf("vesti-tectonic/bin/%s", library_name)
	destination := fmt.tprintf("build/%s", library_name)
	if !os.is_file(source) {
		fmt.eprintfln("build: bundled Tectonic bridge is missing: %s", source)
		return false
	}
	if err := os.copy_file(destination, source); err != nil {
		fmt.eprintfln("build: cannot install Tectonic bridge: %v", err)
		return false
	}

	when ODIN_OS == .Windows {
		profile, found := os.lookup_env("USERPROFILE", context.temp_allocator)
		if !found {
			fmt.eprintln("build: USERPROFILE is required to locate Odin's lua54.dll")
			return false
		}
		lua_source, join_err := filepath.join(
			{profile, ".local", "Odin", "vendor", "lua", "5.4", "windows", "lua54.dll"},
			context.temp_allocator,
		)
		if join_err != nil || !os.is_file(lua_source) {
			fmt.eprintfln("build: Odin Lua runtime is missing: %s", lua_source)
			return false
		}
		if err := os.copy_file("build/lua54.dll", lua_source); err != nil {
			fmt.eprintfln("build: cannot install lua54.dll: %v", err)
			return false
		}
	}
	return true
}

validate_tectonic_library :: proc(path: string) -> bool {
	absolute_path, path_error := filepath.abs(path, context.temp_allocator)
	if path_error != nil {
		fmt.eprintfln("build: cannot resolve Tectonic bridge %s: %v", path, path_error)
		return false
	}
	library, loaded := dynlib.load_library(absolute_path, allocator = context.temp_allocator)
	if !loaded {
		fmt.eprintfln(
			"build: bundled Tectonic bridge cannot load on this system: %s",
			absolute_path,
		)
		when ODIN_OS == .Linux {
			fmt.eprintln("build: the bundled Linux bridge requires an x86-64 GNU-compatible userspace")
		}
		return false
	}
	defer {
		_ = dynlib.unload_library(library)
	}
	_, found := dynlib.symbol_address(
		library,
		"compile_latex_with_tectonic",
		context.temp_allocator,
	)
	if !found {
		fmt.eprintfln("build: Tectonic bridge is missing its compile entry point: %s", absolute_path)
		return false
	}
	return true
}

ensure_unicode :: proc(force: bool = false) -> bool {
	if !ensure_build_directory() {
		return false
	}

	generator_sources := [?]string{"tools/unicode_gen/main.odin"}
	if force || needs_rebuild(GENERATOR_EXE, generator_sources[:]) {
		command := [?]string{
			odin_command(),
			"build",
			"tools/unicode_gen",
			fmt.tprintf("-out:%s", GENERATOR_EXE),
		}
		if !run_command(command[:]) {
			return false
		}
	}

	generated_inputs := [1 + len(UNICODE_INPUTS)]string{}
	generated_inputs[0] = GENERATOR_EXE
	for input, index in UNICODE_INPUTS {
		generated_inputs[index+1] = input
	}
	if force || needs_rebuild(GENERATED_TABLES, generated_inputs[:]) {
		command := [2 + len(UNICODE_INPUTS)]string{}
		command[0] = GENERATOR_EXE
		for input, index in UNICODE_INPUTS {
			command[index+1] = input
		}
		command[len(command)-1] = GENERATED_TABLES
		if !run_command(command[:]) {
			return false
		}
	} else {
		fmt.println("unicode tables are up to date")
	}
	return true
}

build_app :: proc() -> bool {
	if !ensure_unicode() {
		return false
	}
	command := [?]string{odin_command(), "build", "src", fmt.tprintf("-out:%s", APP_EXE)}
	if !run_command(command[:]) {
		return false
	}
	return install_runtime_libraries()
}

install_paths_are_same :: proc(source, destination: string) -> bool {
	if !os.exists(destination) {
		return false
	}
	source_absolute, source_error := filepath.abs(source, context.temp_allocator)
	destination_absolute, destination_error := filepath.abs(destination, context.temp_allocator)
	if source_error == nil && destination_error == nil {
		return os.are_paths_identical(source_absolute, destination_absolute)
	}
	return os.are_paths_identical(source, destination)
}

install_copy_artifact :: proc(source, directory: string) -> bool {
	if !os.is_file(source) {
		fmt.eprintfln("build: install artifact is missing: %s", source)
		return false
	}
	destination, join_error := filepath.join(
		{directory, filepath.base(source)},
		context.temp_allocator,
	)
	if join_error != nil {
		fmt.eprintfln("build: cannot form install path for %s: %v", source, join_error)
		return false
	}
	if install_paths_are_same(source, destination) {
		fmt.printfln("already installed: %s", destination)
		return true
	}

	temporary_file, temporary_error := os.create_temp_file(
		directory,
		".vesti-install-*",
	)
	if temporary_error != nil {
		fmt.eprintfln("build: cannot create a temporary install file in %s: %v", directory, temporary_error)
		return false
	}
	temporary_info, info_error := os.fstat(temporary_file, context.allocator)
	if info_error != nil {
		_ = os.close(temporary_file)
		fmt.eprintfln("build: cannot inspect temporary install file: %v", info_error)
		return false
	}
	defer os.file_info_delete(temporary_info, context.allocator)
	temporary_path := temporary_info.fullpath
	defer if os.exists(temporary_path) {
		_ = os.remove(temporary_path)
	}
	if close_error := os.close(temporary_file); close_error != nil {
		fmt.eprintfln("build: cannot close temporary install file: %v", close_error)
		return false
	}

	if copy_error := os.copy_file(temporary_path, source); copy_error != nil {
		fmt.eprintfln(
			"build: cannot install %s as %s: %s",
			source,
			destination,
			os.error_string(copy_error),
		)
		return false
	}

	when ODIN_OS != .Windows {
		info, stat_error := os.stat(source, context.temp_allocator)
		if stat_error != nil {
			fmt.eprintfln("build: cannot read permissions for %s: %v", source, stat_error)
			return false
		}
		if mode_error := os.change_mode(temporary_path, info.mode); mode_error != nil {
			fmt.eprintfln("build: cannot set permissions on %s: %v", temporary_path, mode_error)
			return false
		}
	}
	if rename_error := os.rename(temporary_path, destination); rename_error != nil {
		fmt.eprintfln("build: cannot replace %s: %v", destination, rename_error)
		return false
	}

	fmt.printfln("installed: %s", destination)
	return true
}

install_app :: proc(path: string) -> bool {
	if !build_app() {
		return false
	}

	expanded, expansion_error := install_expand_native_path(path)
	if expansion_error != .None {
		fmt.eprintfln("build: %s", install_path_error_message(expansion_error))
		return false
	}
	defer delete(expanded)

	directory, clean_error := filepath.clean(expanded)
	if clean_error != nil {
		fmt.eprintfln("build: cannot normalize install directory %q: %v", expanded, clean_error)
		return false
	}
	defer delete(directory)

	if make_error := os.make_directory_all(directory); make_error != nil && make_error != .Exist {
		fmt.eprintfln("build: cannot create install directory %s: %v", directory, make_error)
		return false
	}
	if !os.is_dir(directory) {
		fmt.eprintfln("build: install destination is not a directory: %s", directory)
		return false
	}

	library_source := fmt.tprintf("build/%s", tectonic_library_name())
	if !os.is_file(APP_EXE) || !os.is_file(library_source) {
		fmt.eprintln("build: one or more staged install artifacts are missing")
		return false
	}
	when ODIN_OS == .Windows {
		if !os.is_file("build/lua54.dll") {
			fmt.eprintln("build: staged Lua runtime is missing: build/lua54.dll")
			return false
		}
	}
	if !validate_tectonic_library(library_source) {
		return false
	}

	if !install_copy_artifact(APP_EXE, directory) {
		return false
	}
	if !install_copy_artifact(library_source, directory) {
		return false
	}
	when ODIN_OS == .Windows {
		if !install_copy_artifact("build/lua54.dll", directory) {
			return false
		}
	}
	return true
}

test_all :: proc() -> bool {
	if !ensure_unicode() {
		return false
	}
	if !install_runtime_libraries() {
		return false
	}
	staged_library := fmt.tprintf("build/%s", tectonic_library_name())
	if !validate_tectonic_library(staged_library) {
		return false
	}
	build_driver_command := [?]string{
		odin_command(),
		"test",
		"build.odin",
		"-file",
		"-out:build/build_driver_tests" + EXE_SUFFIX,
	}
	if !run_command(build_driver_command[:]) {
		return false
	}
	uucode_command := [?]string{
		odin_command(),
		"test",
		"src/uucode",
		"-out:build/uucode_tests" + EXE_SUFFIX,
	}
	if !run_command(uucode_command[:]) {
		return false
	}
	app_command := [?]string{
		odin_command(),
		"test",
		"src",
		"-out:build/source_tests" + EXE_SUFFIX,
	}
	if !run_command(app_command[:]) {
		return false
	}
	// Keep test source files in separate processes. Several test groups use
	// process-global state, and Odin's runner reuses per-thread allocators when
	// all 75 tests share one binary.
	for test_file, index in INTEGRATION_TEST_FILES {
		external_command := [?]string{
			odin_command(),
			"test",
			test_file,
			"-file",
			fmt.tprintf("-out:build/integration_%02d%s", index, EXE_SUFFIX),
		}
		if !run_command(external_command[:]) {
			return false
		}
	}
	return true
}

run_app :: proc(args: []string) -> bool {
	if !build_app() {
		return false
	}
	command: [dynamic]string
	defer delete(command)
	append(&command, APP_EXE)
	if len(args) != 0 {
		append(&command, ..args)
	}
	return run_command(command[:])
}

print_help :: proc() {
	fmt.println("usage: odin run build.odin -file -- <command> [args]")
	fmt.println()
	fmt.println("commands:")
	fmt.println("  build          regenerate Unicode data if needed, then build Vesti")
	fmt.println("  test           regenerate Unicode data if needed, then run all tests")
	fmt.println("  run [args...]  regenerate Unicode data if needed, then run Vesti")
	fmt.println("  install <dir>  build Vesti and install it with its runtime libraries")
	fmt.println("  unicode        regenerate Unicode tables only when inputs changed")
	fmt.println("  unicode/regen  force rebuilding the generator and Unicode tables")
	fmt.println("  clean          remove only the build directory")
}

install_expansion_expect :: proc(
	t: ^testing.T,
	path: string,
	style: Install_Path_Style,
	environment: Install_Path_Environment,
	expected: string,
	expected_error: Install_Path_Error = .None,
) {
	actual, err := install_expand_path(path, style, environment)
	defer if len(actual) != 0 {
		delete(actual)
	}
	if !testing.expect_value(t, err, expected_error) {
		return
	}
	if err == .None {
		testing.expect_value(t, actual, expected)
	} else {
		testing.expect_value(t, actual, "")
	}
}

@test
install_windows_path_expansion_test :: proc(t: ^testing.T) {
	environment := Install_Path_Environment {
		user_profile = `C:\Users\Example User`,
		app_data = `C:\Users\Example User\AppData\Roaming`,
	}
	install_expansion_expect(
		t,
		`%USERPROFILE%`,
		.Windows,
		environment,
		`C:\Users\Example User`,
	)
	install_expansion_expect(
		t,
		`%userprofile%\bin`,
		.Windows,
		environment,
		`C:\Users\Example User\bin`,
	)
	install_expansion_expect(
		t,
		`%APPDATA%/Vesti/bin`,
		.Windows,
		environment,
		`C:\Users\Example User\AppData\Roaming/Vesti/bin`,
	)
	install_expansion_expect(t, `tools\bin`, .Windows, environment, `tools\bin`)
	install_expansion_expect(t, `prefix\%APPDATA%`, .Windows, environment, `prefix\%APPDATA%`)
	install_expansion_expect(t, `%APPDATA%extra`, .Windows, environment, `%APPDATA%extra`)
	install_expansion_expect(
		t,
		`%USERPROFILE%\bin`,
		.Windows,
		{},
		"",
		.Missing_User_Profile,
	)
	install_expansion_expect(
		t,
		`%APPDATA%\bin`,
		.Windows,
		{},
		"",
		.Missing_App_Data,
	)
	install_expansion_expect(t, "", .Windows, environment, "", .Empty_Path)
}

@test
install_posix_path_expansion_test :: proc(t: ^testing.T) {
	environment := Install_Path_Environment {home = "/home/example user"}
	install_expansion_expect(t, "~", .Posix, environment, "/home/example user")
	install_expansion_expect(t, "~/bin", .Posix, environment, "/home/example user/bin")
	install_expansion_expect(t, "./tools/bin", .Posix, environment, "./tools/bin")
	install_expansion_expect(t, "work/~/bin", .Posix, environment, "work/~/bin")
	install_expansion_expect(t, "~other/bin", .Posix, environment, "", .Unsupported_Home_Syntax)
	install_expansion_expect(t, "~/bin", .Posix, {}, "", .Missing_Home)
}

install_test_file_equals :: proc(t: ^testing.T, path, expected: string) -> bool {
	contents, err := os.read_entire_file(path, context.allocator)
	if !testing.expect_value(t, err, nil) {
		return false
	}
	defer delete(contents)
	return testing.expect_value(t, string(contents), expected)
}

@test
install_artifact_copy_test :: proc(t: ^testing.T) {
	if !testing.expect_value(t, ensure_build_directory(), true) {
		return
	}
	root, root_error := os.make_directory_temp(
		"build",
		"install-copy-test-*",
		context.allocator,
	)
	if !testing.expect_value(t, root_error, nil) {
		return
	}
	defer {
		_ = os.remove_all(root)
		delete(root)
	}

	destination_directory, destination_join_error := filepath.join(
		{root, "destination"},
		context.temp_allocator,
	)
	if !testing.expect_value(t, destination_join_error, nil) {
		return
	}
	hard_link_directory, hard_directory_join_error := filepath.join(
		{root, "hard-link"},
		context.temp_allocator,
	)
	if !testing.expect_value(t, hard_directory_join_error, nil) {
		return
	}
	if !testing.expect_value(t, os.make_directory_all(destination_directory), nil) {
		return
	}
	if !testing.expect_value(t, os.make_directory_all(hard_link_directory), nil) {
		return
	}

	source, source_join_error := filepath.join({root, "artifact.bin"}, context.temp_allocator)
	if !testing.expect_value(t, source_join_error, nil) {
		return
	}
	destination, artifact_join_error := filepath.join(
		{destination_directory, "artifact.bin"},
		context.temp_allocator,
	)
	if !testing.expect_value(t, artifact_join_error, nil) {
		return
	}
	hard_link, hard_link_join_error := filepath.join(
		{hard_link_directory, "artifact.bin"},
		context.temp_allocator,
	)
	if !testing.expect_value(t, hard_link_join_error, nil) {
		return
	}
	sentinel, sentinel_join_error := filepath.join(
		{destination_directory, "keep.txt"},
		context.temp_allocator,
	)
	if !testing.expect_value(t, sentinel_join_error, nil) {
		return
	}
	if !testing.expect_value(t, os.write_entire_file(source, "first version"), nil) {
		return
	}
	if !testing.expect_value(t, os.write_entire_file(sentinel, "keep me"), nil) {
		return
	}
	if !testing.expect_value(t, install_copy_artifact(source, destination_directory), true) {
		return
	}
	if !install_test_file_equals(t, destination, "first version") {
		return
	}

	if !testing.expect_value(t, os.write_entire_file(source, "second version"), nil) {
		return
	}
	if !testing.expect_value(t, install_copy_artifact(source, destination_directory), true) {
		return
	}
	if !install_test_file_equals(t, destination, "second version") {
		return
	}
	if !install_test_file_equals(t, sentinel, "keep me") {
		return
	}
	if !testing.expect_value(t, install_copy_artifact(destination, destination_directory), true) {
		return
	}
	if !install_test_file_equals(t, destination, "second version") {
		return
	}

	when ODIN_OS != .Windows {
		mode := os.Permissions_Read_All + {.Write_User, .Execute_User}
		if !testing.expect_value(t, os.change_mode(source, mode), nil) {
			return
		}
		if !testing.expect_value(t, install_copy_artifact(source, destination_directory), true) {
			return
		}
		info, stat_error := os.stat(destination, context.temp_allocator)
		if !testing.expect_value(t, stat_error, nil) {
			return
		}
		testing.expect(t, .Execute_User in info.mode)
	}

	if !testing.expect_value(t, os.link(source, hard_link), nil) {
		return
	}
	if !testing.expect_value(t, install_copy_artifact(source, hard_link_directory), true) {
		return
	}
	install_test_file_equals(t, source, "second version")
	install_test_file_equals(t, hard_link, "second version")
}

@test
install_same_file_detection_test :: proc(t: ^testing.T) {
	executable, err := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer delete(executable)
	testing.expect_value(t, install_paths_are_same(executable, executable), true)
}

@test
integration_test_file_list_is_complete_test :: proc(t: ^testing.T) {
	infos, err := os.read_all_directory_by_path("tests", context.allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer os.file_info_slice_delete(infos, context.allocator)

	discovered := 0
	for info in infos {
		if info.type != .Regular || !strings.has_suffix(info.name, "_test.odin") {
			continue
		}
		discovered += 1
		path := fmt.tprintf("tests/%s", info.name)
		found := false
		for listed in INTEGRATION_TEST_FILES {
			if path == listed {
				found = true
				break
			}
		}
		testing.expectf(t, found, "build driver does not run %s", path)
	}
	testing.expect_value(t, discovered, len(INTEGRATION_TEST_FILES))
	for listed in INTEGRATION_TEST_FILES {
		testing.expectf(t, os.is_file(listed), "listed test file is missing: %s", listed)
	}
}

main :: proc() {
	if len(os.args) < 2 {
		print_help()
		os.exit(2)
	}

	ok := false
	switch os.args[1] {
	case "build":
		ok = build_app()
	case "test":
		ok = test_all()
	case "run":
		ok = run_app(os.args[2:])
	case "install":
		if len(os.args) < 3 {
			fmt.eprintln("build: install expects a destination directory")
			ok = false
		} else {
			// Odin's Windows `run` command can split a quoted forwarded argument.
			// Rejoining the remaining words keeps paths with spaces usable through
			// the documented build-driver invocation as well as a built executable.
			install_path, join_error := strings.join(os.args[2:], " ")
			if join_error != nil {
				fmt.eprintfln("build: cannot read install directory: %v", join_error)
				ok = false
			} else {
				defer delete(install_path)
				ok = install_app(install_path)
			}
		}
	case "unicode":
		ok = ensure_unicode()
	case "regen", "unicode/regen":
		ok = ensure_unicode(true)
	case "clean":
		if err := os.remove_all("build"); err != nil {
			fmt.eprintfln("build: cannot remove build directory: %v", err)
			ok = false
		} else {
			fmt.println("removed build directory; generated Unicode source was preserved")
			ok = true
		}
	case "help", "--help", "-h":
		print_help()
		ok = true
	case:
		fmt.eprintfln("build: unknown command %q", os.args[1])
		print_help()
		ok = false
	}

	if !ok {
		os.exit(1)
	}
}

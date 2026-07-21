package defkind_test

import "core:os"
import "core:strings"
import "core:testing"

import vesti "../src"

@test
lua_project_api_and_codegen_output_test :: proc(t: ^testing.T) {
	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)

	runtime: vesti.Lua_Runtime
	initialized := vesti.lua_runtime_init(
		&runtime,
		.pdflatex,
		vesti.config_default(),
		&diagnostic,
	)
	testing.expect_value(t, initialized, true)
	if !initialized do return
	defer vesti.lua_runtime_deinit(&runtime)

	runtime.is_first_script = true
	ok := vesti.lua_runtime_eval(
		&runtime,
		`vesti.compile("book.ves", {engine="tect", compile_all=false})`,
		"first.lua",
	)
	runtime.is_first_script = false
	testing.expect_value(t, ok, true)
	testing.expect_value(t, runtime.main_ves, "book.ves")
	testing.expect_value(t, runtime.engine, vesti.Latex_Engine.tectonic)
	testing.expect_value(t, runtime.attr.compile_all, false)
	testing.expect_value(t, runtime.attr.engine_already_changed, true)

	output := strings.builder_make()
	defer strings.builder_destroy(&output)
	evaluated := vesti.lua_codegen_evaluate(
		`vesti.print("left", 7, {sep=":", nl=0})`,
		&output,
		&runtime,
	)
	testing.expect_value(t, evaluated, true)
	testing.expect_value(t, strings.to_string(output), "left:7")

	vesti.diagnostic_clear_error(&diagnostic)
	bad_code := "this is not valid Lua"
	bad_ok := vesti.lua_runtime_eval(&runtime, bad_code, "broken.lua")
	testing.expect_value(t, bad_ok, false)
	testing.expect_value(t, diagnostic.kind, vesti.Diagnostic_Kind.Lua)
	testing.expect(t, strings.contains(diagnostic.note, "Lua source from broken.lua"))
	testing.expect(t, strings.contains(diagnostic.note, bad_code))

	// Windows reports Process_State.success=true even for nonzero exit codes.
	// The Vesti wrappers must key success off exit_code on every platform.
	failed_process := os.Process_State{exited = true, exit_code = 7, success = true}
	testing.expect(t, !vesti.process_exited_successfully(failed_process, nil))
}

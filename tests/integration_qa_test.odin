package defkind_test

import vesti "../src"

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

qa_join :: proc(t: ^testing.T, parts: []string) -> (string, bool) {
	path, err := filepath.join(parts)
	if !testing.expect_value(t, err, nil) {
		return "", false
	}
	return path, true
}

qa_write_file :: proc(t: ^testing.T, path, contents: string) -> bool {
	directory := filepath.dir(path)
	if !testing.expect_value(t, os.make_directory_all(directory), nil) {
		return false
	}
	return testing.expect_value(t, os.write_entire_file(path, contents), nil)
}

@test
qa_json_config_contract_test :: proc(t: ^testing.T) {
	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)

	config, ok := vesti.config_parse_json(
		`{"engine":"pdf","lua":{"make_log":true}}`,
		&diagnostic,
	)
	if testing.expect_value(t, ok, true) {
		testing.expect_value(t, config.engine, vesti.Latex_Engine.pdflatex)
		testing.expect_value(t, config.lua.make_log, true)
		testing.expect_value(t, config.lua.line_limit, 45)
	}

	invalid, invalid_ok := vesti.config_parse_json(
		`{"engine":"pdf","lua":{"make_log":false,"line_limit":-1}}`,
		&diagnostic,
	)
	testing.expect_value(t, invalid_ok, false)
	testing.expect_value(t, invalid, vesti.config_default())
	testing.expect_value(t, diagnostic.kind, vesti.Diagnostic_Kind.IO)
	testing.expect_value(t, diagnostic.message, "invalid lua.line_limit in config.json")

	_, wrong_type_ok := vesti.config_parse_json(
		`{"lua":{"line_limit":"45"}}`,
		&diagnostic,
	)
	testing.expect_value(t, wrong_type_ok, false)
	testing.expect_value(t, diagnostic.kind, vesti.Diagnostic_Kind.IO)
}

@test
qa_module_json_strictness_test :: proc(t: ^testing.T) {
	valid, valid_err := vesti.vesti_module_parse_json(
		`{"name":"sample","version":null,"exports":[` +
			`{"name":"chapter.ves","location":null}],"extra":true}`,
	)
	defer vesti.vesti_module_deinit(&valid)
	if testing.expect_value(t, valid_err, vesti.Vesti_Module_JSON_Error.None) {
		testing.expect_value(t, valid.name, "sample")
		_, has_version := valid.version.?
		testing.expect_value(t, has_version, false)
		if testing.expect_value(t, len(valid.exports), 1) {
			testing.expect_value(t, valid.exports[0].name, "chapter.ves")
			_, has_location := valid.exports[0].location.?
			testing.expect_value(t, has_location, false)
		}
	}

	cases := [?]struct {
		contents: string,
		expected: vesti.Vesti_Module_JSON_Error,
	}{
		{`[]`, .Root_Not_Object},
		{`{"name":`, .Invalid_JSON},
		{`{"name":7,"version":"1","exports":[]}`, .Name_Not_String},
		{`{"name":"m","version":false,"exports":[]}`, .Version_Not_String_Or_Null},
		{`{"name":"m","version":"1","exports":{}}`, .Exports_Not_Array},
		{`{"name":"m","version":"1","exports":[false]}`, .Export_Not_Object},
		{`{"name":"m","version":"1","exports":[{"name":7}]}`, .Export_Name_Not_String},
		{
			`{"name":"m","version":"1","exports":[{"name":"x","location":7}]}`,
			.Export_Location_Not_String_Or_Null,
		},
		{
			`{"name":"m","version":"1","exports":[{"name":"x"}]} true`,
			.Trailing_Content,
		},
		{
			`{"name":"m","version":"1","exports":[{"name":"x"}],}`,
			.Invalid_JSON,
		},
	}
	for test_case in cases {
		module, parse_err := vesti.vesti_module_parse_json(test_case.contents)
		testing.expect_value(t, parse_err, test_case.expected)
		vesti.vesti_module_deinit(&module)
	}
}

qa_config_environment_name :: proc() -> string {
	when ODIN_OS == .Windows {
		return "APPDATA"
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		return "HOME"
	} else {
		return ""
	}
}

@test
qa_serialized_config_and_manifest_copy_exports_test :: proc(t: ^testing.T) {
	environment_name := qa_config_environment_name()
	if len(environment_name) == 0 {
		return
	}

	root, root_err := os.make_directory_temp("", "vesti-module-qa-*", context.allocator)
	if !testing.expect_value(t, root_err, nil) {
		return
	}
	defer {
		_ = os.remove_all(root)
		delete(root)
	}

	old_environment, had_old_environment := os.lookup_env(environment_name, context.allocator)
	if !testing.expect_value(t, os.set_env(environment_name, root), nil) {
		if had_old_environment do delete(old_environment)
		return
	}
	defer {
		if had_old_environment {
			_ = os.set_env(environment_name, old_environment)
			delete(old_environment)
		} else {
			_ = os.unset_env(environment_name)
		}
	}

	config_directory, config_ok := vesti.config_directory()
	if !testing.expect_value(t, config_ok, true) {
		return
	}
	defer delete(config_directory)
	config_path, config_path_ok := qa_join(t, {config_directory, "config.msgpack"})
	if !config_path_ok do return
	defer delete(config_path)
	if !qa_write_file(
		t,
		config_path,
		"\x82\xa6engine\xa3lua\xa3lua\x82\xa8make_log\xc3\xaaline_limit\x51",
	) {
		return
	}
	config_diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&config_diagnostic)
	loaded_config, loaded_config_ok := vesti.config_load(&config_diagnostic)
	if testing.expect_value(t, loaded_config_ok, true) {
		testing.expect_value(t, loaded_config.engine, vesti.Latex_Engine.lualatex)
		testing.expect_value(t, loaded_config.lua.make_log, true)
		testing.expect_value(t, loaded_config.lua.line_limit, 81)
	}
	testing.expect_value(t, config_diagnostic.kind, vesti.Diagnostic_Kind.None)

	module_directory, module_ok := qa_join(t, {config_directory, "qa-module"})
	if !module_ok do return
	defer delete(module_directory)
	if !testing.expect_value(t, os.make_directory_all(module_directory), nil) do return

	alpha_source, alpha_source_ok := qa_join(t, {module_directory, "alpha.ves"})
	if !alpha_source_ok do return
	defer delete(alpha_source)
	beta_source, beta_source_ok := qa_join(t, {module_directory, "beta.ves"})
	if !beta_source_ok do return
	defer delete(beta_source)
	if !qa_write_file(t, alpha_source, "alpha export\n") do return
	if !qa_write_file(t, beta_source, "beta export\n") do return

	alpha_destination, alpha_destination_ok := qa_join(t, {root, "exports-alpha"})
	if !alpha_destination_ok do return
	defer delete(alpha_destination)
	beta_destination, beta_destination_ok := qa_join(t, {root, "exports-beta"})
	if !beta_destination_ok do return
	defer delete(beta_destination)
	alpha_json_path, alpha_json_error := os.replace_path_separators(
		alpha_destination,
		'/',
		context.allocator,
	)
	if !testing.expect_value(t, alpha_json_error, nil) do return
	defer delete(alpha_json_path)
	beta_json_path, beta_json_error := os.replace_path_separators(
		beta_destination,
		'/',
		context.allocator,
	)
	if !testing.expect_value(t, beta_json_error, nil) do return
	defer delete(beta_json_path)

	manifest := strings.builder_make()
	defer strings.builder_destroy(&manifest)
	_ = strings.write_string(
		&manifest,
		"name = \"qa-module\"\nversion = \"1.0.0\"\n\n[[exports]]\nname = \"alpha.ves\"\nlocation = \"",
	)
	_ = strings.write_string(&manifest, alpha_json_path)
	_ = strings.write_string(
		&manifest,
		"\"\n\n[[exports]]\nname = \"beta.ves\"\nlocation = \"",
	)
	_ = strings.write_string(&manifest, beta_json_path)
	_ = strings.write_string(&manifest, "\"\n")
	manifest_path, manifest_ok := qa_join(t, {module_directory, "vesti.toml"})
	if !manifest_ok do return
	defer delete(manifest_path)
	if !qa_write_file(t, manifest_path, strings.to_string(manifest)) do return

	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)
	copied := vesti.download_module("/qa-module", diagnostic = &diagnostic)
	if !copied {
		fmt.eprintfln("module QA diagnostic: %s (note: %s)", diagnostic.message, diagnostic.note)
	}
	if !testing.expect_value(
		t,
		copied,
		true,
	) {
		return
	}
	testing.expect_value(t, diagnostic.kind, vesti.Diagnostic_Kind.None)

	alpha_copy, alpha_copy_ok := qa_join(t, {alpha_destination, "alpha.ves"})
	if !alpha_copy_ok do return
	defer delete(alpha_copy)
	beta_copy, beta_copy_ok := qa_join(t, {beta_destination, "beta.ves"})
	if !beta_copy_ok do return
	defer delete(beta_copy)
	alpha_contents, alpha_read_error := os.read_entire_file(alpha_copy, context.allocator)
	if !testing.expect_value(t, alpha_read_error, nil) do return
	defer delete(alpha_contents)
	beta_contents, beta_read_error := os.read_entire_file(beta_copy, context.allocator)
	if !testing.expect_value(t, beta_read_error, nil) do return
	defer delete(beta_contents)
	testing.expect_value(t, string(alpha_contents), "alpha export\n")
	testing.expect_value(t, string(beta_contents), "beta export\n")

	if !qa_write_file(
		t,
		manifest_path,
		"name = \"qa-module\"\n[[exports]]\nname = \"missing.ves\"\n",
	) {
		return
	}
	vesti.diagnostic_clear_error(&diagnostic)
	missing_copy := vesti.download_module("qa-module", diagnostic = &diagnostic)
	testing.expect_value(t, missing_copy, false)
	testing.expect(
		t,
		strings.contains(diagnostic.message, "missing.ves") &&
		strings.contains(diagnostic.message, "cannot copy from"),
	)
	testing.expect_value(
		t,
		diagnostic.note,
		"verify that every manifest export exactly matches an installed filename",
	)
}

@test
qa_lua_project_api_and_vesti_parse_test :: proc(t: ^testing.T) {
	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)
	runtime: vesti.Lua_Runtime
	initialized := vesti.lua_runtime_init(
		&runtime,
		.pdflatex,
		vesti.config_default(),
		&diagnostic,
		parse_proc = vesti.compiler_lua_parse,
		parse_user_data = rawptr(&runtime),
	)
	if !testing.expect_value(t, initialized, true) do return
	defer vesti.lua_runtime_deinit(&runtime)

	runtime.is_first_script = true
	compiled := vesti.lua_runtime_eval(
		&runtime,
		`vesti.compile("paper.ves", {` +
		`engine="xe", compile_all=false, watch=true, no_color=true, no_exit_err=true})`,
		"first.lua",
	)
	runtime.is_first_script = false
	if !testing.expect_value(t, compiled, true) do return
	testing.expect_value(t, runtime.main_ves, "paper.ves")
	testing.expect_value(t, runtime.engine, vesti.Latex_Engine.xelatex)
	testing.expect_value(t, runtime.attr.compile_all, false)
	testing.expect_value(t, runtime.attr.watch, true)
	testing.expect_value(t, runtime.attr.no_color, true)
	testing.expect_value(t, runtime.attr.no_exit_err, true)

	output := strings.builder_make()
	defer strings.builder_destroy(&output)
	parsed := vesti.lua_codegen_evaluate(
		`vesti.print(vesti.getEngineType(), vesti.vestiDummyDir(), ` +
		`vesti.parse("startdoc $x$"), {sep="|", nl=0})`,
		&output,
		rawptr(&runtime),
	)
	if testing.expect_value(t, parsed, true) {
		testing.expect_value(
			t,
			strings.to_string(output),
			"xelatex|.vesti-dummy|\n\\begin{document} $x$\n\\end{document}\n",
		)
	}

	vesti.diagnostic_clear_error(&diagnostic)
	compile_outside_first := vesti.lua_runtime_eval(
		&runtime,
		`vesti.compile("forbidden.ves")`,
		"before.lua",
	)
	testing.expect_value(t, compile_outside_first, false)
	testing.expect_value(t, diagnostic.kind, vesti.Diagnostic_Kind.Lua)
}

@test
qa_compiler_emit_tex_matches_zig_golden_test :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "vesti-compiler-qa-*", context.allocator)
	if !testing.expect_value(t, root_error, nil) do return
	defer {
		_ = os.remove_all(root)
		delete(root)
	}

	input_path, input_ok := qa_join(t, {root, "main.ves"})
	if !input_ok do return
	defer delete(input_path)
	output_directory, output_directory_ok := qa_join(t, {root, "output"})
	if !output_directory_ok do return
	defer delete(output_directory)
	if !qa_write_file(
		t,
		input_path,
		"docclass article (a4paper)startdoc useenv center {Hello}\n",
	) {
		return
	}

	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)
	engine := vesti.Latex_Engine.tectonic
	request := vesti.compiler_request_default(input_path, &engine, &diagnostic)
	request.emit_tex = true
	request.compile_all = false
	request.dummy_directory = output_directory
	if !testing.expect_value(t, vesti.compiler_compile_once(&request), true) do return
	testing.expect_value(t, diagnostic.kind, vesti.Diagnostic_Kind.None)

	tex_path, tex_path_ok := qa_join(t, {output_directory, "main.tex"})
	if !tex_path_ok do return
	defer delete(tex_path)
	contents, read_error := os.read_entire_file(tex_path, context.allocator)
	if !testing.expect_value(t, read_error, nil) do return
	defer delete(contents)
	expected := "%\n" +
		"%    this file was generated by vesti 0.16.1\n" +
		"%    compile this file using tectonic engine\n" +
		"%    =========================================\n" +
		"%    vesti: https://github.com/e0328eric/vesti\n" +
		"%\n" +
		"\\documentclass[a4paper]{article}\n" +
		"\\usepackage{amstext}\n" +
		"\n\\begin{document} \\begin{center}Hello\\end{center}\n" +
		"\n\\end{document}\n"
	testing.expect_value(t, string(contents), expected)
}

@test
qa_cli_compile_contract_test :: proc(t: ^testing.T) {
	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)
	args := []string{
		"compile",
		"paper.ves",
		"--emit-tex",
		"--lim=5",
		"--standalone",
		"--before-script",
		"pre.lua",
		"-x",
	}
	options, ok := vesti.cli_parse(args, &diagnostic)
	if testing.expect_value(t, ok, true) {
		testing.expect_value(t, options.command, vesti.Command_Kind.Compile)
		testing.expect_value(t, options.filename, "paper.ves")
		testing.expect_value(t, options.emit_tex, true)
		testing.expect_value(t, options.compile_limit, 5)
		testing.expect_value(t, options.standalone, true)
		testing.expect_value(t, options.before_script, "pre.lua")
		testing.expect_value(t, options.engine, vesti.Latex_Engine.xelatex)
		testing.expect_value(t, options.has_engine, true)
	}

	_, duplicate_engine_ok := vesti.cli_parse(
		[]string{"compile", "paper.ves", "-p", "-T"},
		&diagnostic,
	)
	testing.expect_value(t, duplicate_engine_ok, false)
	testing.expect_value(t, diagnostic.message, "only one LaTeX engine flag may be selected")
}

@test
qa_init_scaffold_matches_zig_test :: proc(t: ^testing.T) {
	first_source := vesti.init_first_source("sample.ves")
	defer delete(first_source)
	testing.expect_value(
		t,
		first_source,
		"-- below code imports vesti module\n" +
		"-- vesti.getModule(\"module_name\")\n" +
		"vesti.compile(\"sample.ves\", { engine = \"tect\", compile_all = true })",
	)
	testing.expect_value(
		t,
		vesti.INIT_VESTI_SOURCE,
		"docclass article\nstartdoc\nHello, World!",
	)
}

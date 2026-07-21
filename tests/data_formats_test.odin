package defkind_test

import vesti "../src"

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@test
config_all_formats_have_identical_schema_test :: proc(t: ^testing.T) {
	cases := [?]struct {
		format:   vesti.Data_Format,
		name:     string,
		contents: string,
	}{
		{
			.JSON,
			"config.json",
			`{"engine":"xelatex","lua":{"make_log":true,"line_limit":72}}`,
		},
		{
			.YAML,
			"config.yaml",
			"engine: xelatex\nlua:\n  make_log: true\n  line_limit: 72\n",
		},
		{
			.TOML,
			"config.toml",
			"engine = \"xelatex\"\n[lua]\nmake_log = true\nline_limit = 72\n",
		},
		{
			.MessagePack,
			"config.msgpack",
			"\x82\xa6engine\xa7xelatex\xa3lua\x82\xa8make_log\xc3\xaaline_limit\x48",
		},
	}

	for test_case in cases {
		config, ok := vesti.config_parse(
			test_case.contents,
			test_case.format,
			test_case.name,
		)
		if testing.expect_value(t, ok, true) {
			testing.expect_value(t, config.engine, vesti.Latex_Engine.xelatex)
			testing.expect_value(t, config.lua.make_log, true)
			testing.expect_value(t, config.lua.line_limit, 72)
		}
	}
}

@test
config_all_formats_preserve_defaults_and_strict_types_test :: proc(t: ^testing.T) {
	empty_cases := [?]struct {
		format:   vesti.Data_Format,
		contents: string,
	}{
		{.JSON, `{}`},
		{.YAML, `{}`},
		{.TOML, ""},
		{.MessagePack, "\x80"},
	}
	for test_case in empty_cases {
		config, ok := vesti.config_parse(
			test_case.contents,
			test_case.format,
			"config-test",
		)
		testing.expect_value(t, ok, true)
		testing.expect_value(t, config, vesti.config_default())
	}

	invalid_cases := [?]struct {
		format:   vesti.Data_Format,
		contents: string,
	}{
		{.JSON, `{"lua":{"line_limit":"72"}}`},
		{.YAML, "lua:\n  line_limit: \"72\"\n"},
		{.TOML, "[lua]\nline_limit = \"72\"\n"},
		{.MessagePack, "\x81\xa3lua\x81\xaaline_limit\xa2\x37\x32"},
	}
	for test_case in invalid_cases {
		config, ok := vesti.config_parse(
			test_case.contents,
			test_case.format,
			"config-test",
		)
		testing.expect_value(t, ok, false)
		testing.expect_value(t, config, vesti.config_default())
	}
}

@test
module_manifest_all_formats_parity_test :: proc(t: ^testing.T) {
	cases := [?]struct {
		format:   vesti.Data_Format,
		contents: string,
	}{
		{
			.JSON,
			`{"name":"sample","version":null,"exports":[{"name":"chapter.ves","location":null}]}`,
		},
		{
			.YAML,
			"name: sample\nversion: null\nexports:\n  - name: chapter.ves\n    location: null\n",
		},
		{
			.TOML,
			"name = \"sample\"\n[[exports]]\nname = \"chapter.ves\"\n",
		},
		{
			.MessagePack,
			"\x83\xa4name\xa6sample\xa7version\xc0\xa7exports\x91\x82\xa4name\xabchapter.ves\xa8location\xc0",
		},
	}

	for test_case in cases {
		manifest, parse_err := vesti.vesti_module_parse(
			test_case.contents,
			test_case.format,
		)
		if testing.expect_value(t, parse_err, vesti.Vesti_Module_JSON_Error.None) {
			testing.expect_value(t, manifest.name, "sample")
			_, has_version := manifest.version.?
			testing.expect_value(t, has_version, false)
			if testing.expect_value(t, len(manifest.exports), 1) {
				testing.expect_value(t, manifest.exports[0].name, "chapter.ves")
				_, has_location := manifest.exports[0].location.?
				testing.expect_value(t, has_location, false)
			}
		}
		vesti.vesti_module_deinit(&manifest)
	}
}

@test
format_parsers_reject_duplicates_and_trailing_data_test :: proc(t: ^testing.T) {
	cases := [?]struct {
		format:   vesti.Data_Format,
		contents: string,
	}{
		{.JSON, `{"engine":"tectonic","engine":"latex"}`},
		{.YAML, "engine: tectonic\nengine: latex\n"},
		{.TOML, "engine = \"tectonic\"\nengine = \"latex\"\n"},
		{.MessagePack, "\x82\xa6engine\xa8tectonic\xa6engine\xa5latex"},
		{.MessagePack, "\x80\xc0"},
	}
	for test_case in cases {
		_, ok := vesti.config_parse(
			test_case.contents,
			test_case.format,
			"config-test",
		)
		testing.expect_value(t, ok, false)
	}
}

@test
messagepack_rejects_truncation_non_string_keys_and_invalid_utf8_test :: proc(t: ^testing.T) {
	cases := [?]string{
		"\xdb\x00\x00\x00\x04abc", // truncated str32
		"\x81\x01\x02",             // map key must be a string
		"\x81\xa6engine\xa1\xff",   // invalid UTF-8 string
		"\xc1",                       // reserved tag
	}
	for contents in cases {
		_, parse_err := vesti.data_parse_messagepack(contents)
		testing.expect(t, parse_err != .None)
	}
}

@test
data_file_discovery_accepts_alias_and_rejects_ambiguity_test :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "vesti-format-discovery-*", context.allocator)
	if !testing.expect_value(t, root_err, nil) do return
	defer {
		_ = os.remove_all(root)
		delete(root)
	}

	yml_path, yml_err := filepath.join({root, "config.yml"})
	if !testing.expect_value(t, yml_err, nil) do return
	defer delete(yml_path)
	if !testing.expect_value(t, os.write_entire_file(yml_path, "engine: tectonic\n"), nil) {
		return
	}

	file, find_err := vesti.data_find_file(root, "config")
	if testing.expect_value(t, find_err, vesti.Data_File_Error.None) {
		testing.expect_value(t, file.format, vesti.Data_Format.YAML)
		delete(file.path)
	}

	json_path, json_err := filepath.join({root, "config.json"})
	if !testing.expect_value(t, json_err, nil) do return
	defer delete(json_path)
	if !testing.expect_value(t, os.write_entire_file(json_path, `{}`), nil) do return

	_, ambiguous_err := vesti.data_find_file(root, "config")
	testing.expect_value(t, ambiguous_err, vesti.Data_File_Error.Ambiguous)
}

@test
module_manifest_owns_decoded_strings_test :: proc(t: ^testing.T) {
	source, clone_err := strings.clone(
		"name: copied\nexports:\n  - name: owned.ves\n",
	)
	if !testing.expect_value(t, clone_err, nil) do return
	manifest, parse_err := vesti.vesti_module_parse_yaml(source)
	delete(source)
	defer vesti.vesti_module_deinit(&manifest)
	if testing.expect_value(t, parse_err, vesti.Vesti_Module_JSON_Error.None) {
		testing.expect_value(t, manifest.name, "copied")
		if testing.expect_value(t, len(manifest.exports), 1) {
			testing.expect_value(t, manifest.exports[0].name, "owned.ves")
		}
	}
}

package defkind_test

import vesti "../src"

import "core:os"
import "core:path/filepath"
import "core:testing"

@test
compiler_paths_fnv1a_mangle_golden_test :: proc(t: ^testing.T) {
	cases := []struct {
		input:    string,
		expected: string,
	}{
		{"", "@vesti__cbf29ce484222325.tex"},
		{"a", "@vesti__af63dc4c8601ec8c.tex"},
		{"foobar", "@vesti__85944171f73967e8.tex"},
		// Zig's `{x}` is unpadded; this hash deliberately begins with zero.
		{"10", "@vesti__7f89207b4ba08a4.tex"},
		{"C:\\project\\main.ves", "@vesti__606d486e3c4523aa.tex"},
	}

	for test_case in cases {
		mangled, ok := vesti.vesti_name_mangle(test_case.input)
		if !testing.expect_value(t, ok, true) {
			continue
		}
		testing.expect_value(t, mangled, test_case.expected)
		delete(mangled)
	}
}

@test
compiler_paths_extension_and_generated_names_test :: proc(t: ^testing.T) {
	testing.expect_value(t, vesti.vesti_extension_is_valid("paper.ves"), true)
	testing.expect_value(t, vesti.validate_vesti_extension("dir/paper.ves"), true)
	testing.expect_value(t, vesti.vesti_extension_is_valid("paper.VES"), false)
	testing.expect_value(t, vesti.vesti_extension_is_valid("paper.ves.tex"), false)

	changed, changed_ok := vesti.change_extension_basename(
		"/projects/paper.v1.ves",
		"tex",
	)
	if testing.expect_value(t, changed_ok, true) {
		testing.expect_value(t, changed, "paper.v1.tex")
		delete(changed)
	}

	hidden, hidden_ok := vesti.change_extension_basename("/projects/.ves", "tex")
	if testing.expect_value(t, hidden_ok, true) {
		testing.expect_value(t, hidden, ".tex")
		delete(hidden)
	}

	invalid, invalid_ok := vesti.change_extension_basename("/projects/paper", "tex")
	testing.expect_value(t, invalid_ok, false)
	testing.expect_value(t, invalid, "")

	main_tex, main_tex_ok := vesti.generated_tex_filename("/work/thesis.ves", true)
	if testing.expect_value(t, main_tex_ok, true) {
		testing.expect_value(t, main_tex, "thesis.tex")
		delete(main_tex)
	}

	import_tex, import_tex_ok := vesti.generated_tex_basename(
		"/work/chapter.ves",
		false,
	)
	if testing.expect_value(t, import_tex_ok, true) {
		testing.expect_value(t, import_tex, "@vesti__6bbcd31bff89a2ad.tex")
		delete(import_tex)
	}

	main_pdf, main_pdf_ok := vesti.generated_pdf_filename("/work/thesis.ves")
	if testing.expect_value(t, main_pdf_ok, true) {
		testing.expect_value(t, main_pdf, "thesis.pdf")
		delete(main_pdf)
	}
}

compiler_paths_write_fixture :: proc(
	t: ^testing.T,
	root: string,
	relative_path: string,
) -> bool {
	fullpath, join_error := filepath.join({root, relative_path})
	if !testing.expect_value(t, join_error, nil) {
		return false
	}
	defer delete(fullpath)

	directory := filepath.dir(fullpath)
	if !testing.expect_value(t, os.make_directory_all(directory), nil) {
		return false
	}
	return testing.expect_value(t, os.write_entire_file(fullpath, "fixture"), nil)
}

compiler_paths_expected_path :: proc(
	t: ^testing.T,
	root: string,
	relative_path: string,
) -> (string, bool) {
	fullpath, join_error := filepath.join({root, relative_path})
	if !testing.expect_value(t, join_error, nil) {
		return "", false
	}
	return fullpath, true
}

@test
compiler_paths_recursive_deterministic_discovery_test :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "vesti-paths-*", context.allocator)
	if !testing.expect_value(t, root_error, nil) {
		return
	}
	defer {
		_ = os.remove_all(root)
		delete(root)
	}

	fixtures := []string{
		"z.ves",
		"a.ves",
		"nested/b.ves",
		"nested/deeper/c.ves",
		"nested/upper.VES",
		"readme.txt",
		".vesti-dummy/generated.ves",
		"build/generated.ves",
		".git/tracked.ves",
		".zig-cache/cached.ves",
		"zig-out/output.ves",
		".odin-cache/cached.ves",
	}
	for fixture in fixtures {
		if !compiler_paths_write_fixture(t, root, fixture) {
			return
		}
	}

	paths, ok := vesti.discover_vesti_files(root)
	if !testing.expect_value(t, ok, true) {
		return
	}
	defer vesti.compiler_path_list_deinit(&paths)
	if !testing.expect_value(t, len(paths), 4) {
		return
	}

	expected_relatives := []string{
		"a.ves",
		"nested/b.ves",
		"nested/deeper/c.ves",
		"z.ves",
	}
	for relative, index in expected_relatives {
		expected, expected_ok := compiler_paths_expected_path(t, root, relative)
		if !expected_ok {
			return
		}
		testing.expect_value(t, paths[index], expected)
		delete(expected)
	}

	// A second walk must produce exactly the same byte order.
	again, again_ok := vesti.discover_vesti_files(root)
	if !testing.expect_value(t, again_ok, true) {
		return
	}
	defer vesti.compiler_path_list_deinit(&again)
	testing.expect_value(t, len(again), len(paths))
	for path, index in paths {
		testing.expect_value(t, again[index], path)
	}
}

@test
compiler_paths_discovery_invalid_root_test :: proc(t: ^testing.T) {
	missing_root, root_error := os.make_directory_temp("", "vesti-paths-missing-*", context.allocator)
	if !testing.expect_value(t, root_error, nil) {
		return
	}
	if !testing.expect_value(t, os.remove_all(missing_root), nil) {
		delete(missing_root)
		return
	}
	defer delete(missing_root)

	paths, ok := vesti.discover_vesti_files(missing_root)
	defer vesti.compiler_path_list_deinit(&paths)
	testing.expect_value(t, ok, false)
	testing.expect_value(t, len(paths), 0)
}

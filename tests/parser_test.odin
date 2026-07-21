package defkind_test

import vesti "../src"

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

parser_test_tokens :: proc(source: string, allocator := context.allocator) -> [dynamic]vesti.Token {
	lexer := vesti.lexer_init(source)
	tokens := make([dynamic]vesti.Token, 0, 100, allocator)
	for {
		token := vesti.lexer_next(&lexer)
		append(&tokens, token)
		if token.kind == .Eof {
			break
		}
	}
	return tokens
}

parser_test_expect :: proc(
	t: ^testing.T,
	source, expected: string,
	trim_newlines := false,
	allow_lua := false,
) {
	allocator := context.allocator
	tokens := parser_test_tokens(source, allocator)
	defer delete(tokens)
	diagnostic := vesti.diagnostic_init(allocator)
	defer vesti.diagnostic_deinit(&diagnostic)
	options := vesti.parser_options_default(allocator)
	options.diagnostic = &diagnostic
	options.allow_lua_code = allow_lua
	options.perform_file_operations = false
	statements, parsed := vesti.parser_parse(tokens[:], options)
	if !testing.expectf(t, parsed, "parser failed: %s", diagnostic.message) {
		return
	}
	defer vesti.stmt_list_deinit(&statements, allocator)
	output := strings.builder_make(allocator)
	defer strings.builder_destroy(&output)
	generated := vesti.codegen(statements[:], nil, &output, &diagnostic, allocator)
	if !testing.expectf(t, generated, "codegen failed: %s", diagnostic.message) {
		return
	}
	actual := strings.to_string(output)
	if trim_newlines {
		actual = strings.trim(actual, "\n")
	}
	testing.expect_value(t, actual, expected)
}

@test
parser_docclass_simple_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"docclass article",
		"\\documentclass{article}\n\\usepackage{amstext}\n",
	)
}

@test
parser_importpkg_single_test :: proc(t: ^testing.T) {
	parser_test_expect(t, "importpkg foo (bar)", "\\usepackage[bar]{foo}\n")
}

@test
parser_math_inline_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"startdoc $\\sum_1^oo f(x)$",
		"\\begin{document} $\\sum_1^\\infty  f(x)$\n\\end{document}",
		true,
	)
}

@test
parser_environment_basic_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"startdoc\nuseenv center { The Document. }",
		"\\begin{document}\n\\begin{center} The Document. \\end{center}\n\\end{document}",
		true,
	)
}

@test
parser_lua_basic_test :: proc(t: ^testing.T) {
	source := "#::\nfunction test(x,y)\n  return x < y\nend\n::#"
	allocator := context.allocator
	tokens := parser_test_tokens(source, allocator)
	defer delete(tokens)
	diagnostic := vesti.diagnostic_init(allocator)
	defer vesti.diagnostic_deinit(&diagnostic)
	options := vesti.parser_options_default(allocator)
	options.diagnostic = &diagnostic
	options.allow_lua_code = true
	options.perform_file_operations = false
	statements, parsed := vesti.parser_parse(tokens[:], options)
	if !testing.expectf(t, parsed, "parser failed: %s", diagnostic.message) {
		return
	}
	defer vesti.stmt_list_deinit(&statements, allocator)
	testing.expect(t, len(statements) > 0)
	if len(statements) == 0 { return }
	block, is_lua := statements[0].(vesti.Lua_Code_Stmt)
	if !testing.expect(t, is_lua) { return }
	testing.expect_value(t, string(block.code[:]), "\nfunction test(x,y)\n  return x < y\nend\n")
}

@test
parser_docclass_single_option_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"docclass article (a4paper)",
		"\\documentclass[a4paper]{article}\n\\usepackage{amstext}\n",
	)
}

@test
parser_docclass_several_options_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"docclass coprime (tikz,geometry,fancythm)",
		"\\documentclass[tikz,geometry,fancythm]{coprime}\n\\usepackage{amstext}\n",
	)
}

@test
parser_docclass_whitespace_test :: proc(t: ^testing.T) {
	source := "docclass coprime (a4paper , \n" +
	          "    foo, bar-what  ,\n" +
	          ")"
	parser_test_expect(
		t,
		source,
		"\\documentclass[a4paper,foo,bar-what]{coprime}\n\\usepackage{amstext}\n",
	)
}

@test
parser_importpkg_without_options_test :: proc(t: ^testing.T) {
	parser_test_expect(t, "importpkg tikz", "\\usepackage{tikz}\n")
}

@test
parser_importpkg_several_options_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"importpkg foo (bar,baz-f3,oomoom)",
		"\\usepackage[bar,baz-f3,oomoom]{foo}\n",
	)
}

@test
parser_importpkg_multiple_without_options_test :: proc(t: ^testing.T) {
	sources := [4]string{
		"importpkg { tikz, amsmath, coprime-math }",
		"importpkg { tikz, amsmath, coprime-math, }",
		"importpkg {\n    tikz,\n    amsmath,\n    coprime-math,\n}",
		"importpkg {\n    tikz,\n    amsmath,\n    coprime-math\n}",
	}
	expected := "\\usepackage{tikz}\n" +
	            "\\usepackage{amsmath}\n" +
	            "\\usepackage{coprime-math}\n"
	for source in sources {
		parser_test_expect(t, source, expected)
	}
}

@test
parser_importpkg_multiple_options_layouts_test :: proc(t: ^testing.T) {
	sources := [8]string{
		"importpkg { tikz, amsmath, coprime-math (stix) }",
		"importpkg { tikz, amsmath, coprime-math(stix) }",
		"importpkg { tikz, amsmath, coprime-math (stix), }",
		"importpkg { tikz, amsmath, coprime-math(stix), }",
		"importpkg {\n    tikz,\n    amsmath,\n    coprime-math (stix),\n}",
		"importpkg {\n    tikz,\n    amsmath,\n    coprime-math(stix),\n}",
		"importpkg {\n    tikz,\n    amsmath,\n    coprime-math (stix)\n}",
		"importpkg {\n    tikz,\n    amsmath,\n    coprime-math (\n  stix\n  )\n}",
	}
	expected := "\\usepackage{tikz}\n" +
	            "\\usepackage{amsmath}\n" +
	            "\\usepackage[stix]{coprime-math}\n"
	for source in sources {
		parser_test_expect(t, source, expected)
	}
}

@test
parser_importpkg_multiple_options_dense_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"importpkg { tikz (a,b,c), foo-f(aa-aa, bb2cc), novax, bar2-a-b(faaa, aa-b-c) }",
		"\\usepackage[a,b,c]{tikz}\n" +
		"\\usepackage[aa-aa,bb2cc]{foo-f}\n" +
		"\\usepackage{novax}\n" +
		"\\usepackage[faaa,aa-b-c]{bar2-a-b}\n",
	)
}

@test
parser_importpkg_multiple_options_multiline_test :: proc(t: ^testing.T) {
	source := "importpkg {\n" +
	          "    tikz (a, b, c),\n" +
	          "    foo-f(aa-aa,\n" +
	          "        bb2cc),\n" +
	          " novax,\n" +
	          "                 bar2-a-b(faaa,   aa-b-c\n" +
	          ")\n" +
	          "}"
	parser_test_expect(
		t,
		source,
		"\\usepackage[a,b,c]{tikz}\n" +
		"\\usepackage[aa-aa,bb2cc]{foo-f}\n" +
		"\\usepackage{novax}\n" +
		"\\usepackage[faaa,aa-b-c]{bar2-a-b}\n",
	)
}

@test
parser_math_display_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"startdoc $$\\int_0^->f(x)$$",
		"\\begin{document} \\[\\int_0^\\rightarrow f(x)\\]\n\\end{document}",
		true,
	)
}

@test
parser_math_document_multiline_test :: proc(t: ^testing.T) {
	source := "docclass coprime (tikz, geometry)\n" +
	          "importpkg {\n" +
	          "    fontenc (T1),\n" +
	          "    inputenc (utf-8),\n" +
	          "}startdoc\n" +
	          "$\\sum_1^oo f(x) $a b c d"
	expected := "\\documentclass[tikz,geometry]{coprime}\n" +
	            "\\usepackage{amstext}\n\n" +
	            "\\usepackage[T1]{fontenc}\n" +
	            "\\usepackage[utf-8]{inputenc}\n\n" +
	            "\\begin{document}\n" +
	            "$\\sum_1^\\infty  f(x) $a b c d\n" +
	            "\\end{document}\n"
	parser_test_expect(t, source, expected)
}

@test
parser_math_document_adjacent_directives_test :: proc(t: ^testing.T) {
	source := "docclass coprime (tikz, geometry)importpkg {\n" +
	          "    fontenc (T1),\n" +
	          "    inputenc (utf-8),\n" +
	          "}startdoc\n" +
	          "$\\sum_1^oo f(x) $a b c d"
	expected := "\\documentclass[tikz,geometry]{coprime}\n" +
	            "\\usepackage{amstext}\n" +
	            "\\usepackage[T1]{fontenc}\n" +
	            "\\usepackage[utf-8]{inputenc}\n\n" +
	            "\\begin{document}\n" +
	            "$\\sum_1^\\infty  f(x) $a b c d\n" +
	            "\\end{document}\n"
	parser_test_expect(t, source, expected)
}

@test
parser_environment_basic_duplicate_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"startdoc\nuseenv center { The Document. }",
		"\\begin{document}\n\\begin{center} The Document. \\end{center}\n\\end{document}",
		true,
	)
}

@test
parser_environment_parameters_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"startdoc\nuseenv minipage (0.7\\pagewidth) {\n    The Document.\n}",
		"\\begin{document}\n\\begin{minipage}{0.7\\pagewidth}\n    The Document.\n\\end{minipage}\n\\end{document}",
		true,
	)
	parser_test_expect(
		t,
		"startdoc\nuseenv minipage(0.7\\pagewidth) {\n    The Document.\n}",
		"\\begin{document}\n\\begin{minipage}{0.7\\pagewidth}\n    The Document.\n\\end{minipage}\n\\end{document}",
		true,
	)
	parser_test_expect(
		t,
		"startdoc\nuseenv figure [ht] {\n    The Document.\n}",
		"\\begin{document}\n\\begin{figure}[ht]\n    The Document.\n\\end{figure}\n\\end{document}",
		true,
	)
	parser_test_expect(
		t,
		"startdoc\nuseenv foo (bar1)[bar2](bar3)(bar4)[bar5] {\n    The Document.\n}",
		"\\begin{document}\n\\begin{foo}{bar1}[bar2]{bar3}{bar4}[bar5]\n    The Document.\n\\end{foo}\n\\end{document}",
		true,
	)
	parser_test_expect(
		t,
		"startdoc\nuseenv foo* (bar1)(bar2) {\n    The Document.\n}",
		"\\begin{document}\n\\begin{foo*}{bar1}{bar2}\n    The Document.\n\\end{foo*}\n\\end{document}",
		true,
	)
	parser_test_expect(
		t,
		"startdoc\nuseenv foo *(bar1)(bar2) {\n    The Document.\n}",
		"\\begin{document}\n\\begin{foo}*{bar1}{bar2}\n    The Document.\n\\end{foo}\n\\end{document}",
		true,
	)
}

@test
parser_phantom_environment_test :: proc(t: ^testing.T) {
	source := "begenv center#1\n" +
	          "begenv center a\n" +
	          "begenv center* a\n" +
	          "begenv center*        a\n" +
	          "begenv center*a\n" +
	          "begenv center** a\n" +
	          "begenv center**    a\n" +
	          "begenv center**a\n" +
	          "begenv center [asd](caewa)a\n" +
	          "begenv center     [asd](caewa) a\n" +
	          "begenv center[asd](caewa) a\n" +
	          "begenv center* [asd](caewa) a\n" +
	          "begenv center*         [asd](caewa) a\n" +
	          "begenv center*[asd](caewa) a\n" +
	          "begenv center** [asd](caewa) a\n" +
	          "begenv center**     [asd](caewa) a\n" +
	          "begenv center**[asd](caewa) a\n" +
	          "begenv center *a\n" +
	          "begenv center* *[asd](caewa) a"
	expected := "\\begin{center}#1\n" +
	            "\\begin{center}a\n" +
	            "\\begin{center*}a\n" +
	            "\\begin{center*}a\n" +
	            "\\begin{center*}a\n" +
	            "\\begin{center**}a\n" +
	            "\\begin{center**}a\n" +
	            "\\begin{center**}a\n" +
	            "\\begin{center}[asd]{caewa}a\n" +
	            "\\begin{center}[asd]{caewa} a\n" +
	            "\\begin{center}[asd]{caewa} a\n" +
	            "\\begin{center*}[asd]{caewa} a\n" +
	            "\\begin{center*}[asd]{caewa} a\n" +
	            "\\begin{center*}[asd]{caewa} a\n" +
	            "\\begin{center**}[asd]{caewa} a\n" +
	            "\\begin{center**}[asd]{caewa} a\n" +
	            "\\begin{center**}[asd]{caewa} a\n" +
	            "\\begin{center}*a\n" +
	            "\\begin{center*}*[asd](caewa) a"
	parser_test_expect(t, source, expected, true)
}

@test
parser_uncovered_codegen_branches_test :: proc(t: ^testing.T) {
	parser_test_expect(t, "${a//b}$", "$\\frac{a}{b}$")
	parser_test_expect(t, "$?(x)?$", "$\\left(x\\right)$")
	parser_test_expect(
		t,
		"defun foo (m) { #1 }",
		"\\NewDocumentCommand{\\foo}{m}{#1}%\n",
	)
	parser_test_expect(
		t,
		"defenv box (m) { begin #1 } { end #1 }",
		"\\NewDocumentEnvironment{box}{m}{begin #1}{end #1}%\n",
	)
	parser_test_expect(
		t,
		"#eq(label) { x }",
		"\\begin{equation}\\label{label} x \\end{equation}",
	)
	parser_test_expect(
		t,
		"#picture[1mm](20, 10)(2, 3) {x}",
		"\\setlength{\\unitlength}{1mm}\n\\begin{picture}(20,10)(2,3)x\\end{picture}",
	)
}

@test
parser_remaining_builtins_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"#showfont(2)",
		" {\\ttfamily\\expandafter\\meaning\\the\\textfont2}",
	)
	parser_test_expect(t, "#chardef 41 \\A\n", "\\chardef\\A=\"41\n")
	parser_test_expect(
		t,
		"#mathchardef .ordinary 0 41 \\A\n",
		"\\Umathchardef\\A=0 0 \"41\n",
	)
	parser_test_expect(t, "$#textmode{x}$", "$x$")
	parser_test_expect(t, "#mathmode{x}", "x")
	parser_test_expect(t, "importmod (coprime)", "")
	parser_test_expect(t, "#copy_file (ignored.txt)", "")
}

@(test)
parser_enum_label_escaping_test :: proc(t: ^testing.T) {
	parser_test_expect(
		t,
		"#enum(a***b*){x}",
		"\\begingroup \\renewcommand{\\labelenumi}{a*{enumi}b{enumi}}\n" +
		"\\begin{enumerate}x\\end{enumerate}\\endgroup ",
	)
}

@test
parser_lua_metadata_and_import_name_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	diagnostic := vesti.diagnostic_init(allocator)
	defer vesti.diagnostic_deinit(&diagnostic)
	options := vesti.parser_options_default(allocator)
	options.diagnostic = &diagnostic
	options.allow_lua_code = true
	options.perform_file_operations = false

	lua_tokens := parser_test_tokens("#::x::#*[foo, bar]<out>", allocator)
	defer delete(lua_tokens)
	lua_statements, lua_ok := vesti.parser_parse(lua_tokens[:], options)
	if !testing.expectf(t, lua_ok, "parser failed: %s", diagnostic.message) { return }
	defer vesti.stmt_list_deinit(&lua_statements, allocator)
	block, is_lua := lua_statements[0].(vesti.Lua_Code_Stmt)
	if !testing.expect(t, is_lua) { return }
	testing.expect_value(t, block.is_global, true)
	imports, has_imports := block.code_import.?
	if testing.expect(t, has_imports) {
		testing.expect_value(t, len(imports), 2)
		if len(imports) == 2 {
			testing.expect_value(t, imports[0], "foo")
			testing.expect_value(t, imports[1], "bar")
		}
	}
	exported, has_export := block.code_export.?
	if testing.expect(t, has_export) {
		testing.expect_value(t, exported, "out")
	}

	import_tokens := parser_test_tokens("importves (sub/file.ves)", allocator)
	defer delete(import_tokens)
	import_statements, import_ok := vesti.parser_parse(import_tokens[:], options)
	if !testing.expectf(t, import_ok, "parser failed: %s", diagnostic.message) { return }
	defer vesti.stmt_list_deinit(&import_statements, allocator)
	statement, is_import := import_statements[0].(vesti.Import_Vesti_Stmt)
	if !testing.expect(t, is_import) { return }
	name := string(statement.name[:])
	testing.expect(t, strings.has_prefix(name, "@vesti__"))
	testing.expect(t, strings.has_suffix(name, ".tex"))
}

@test
parser_engine_change_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	tokens := parser_test_tokens("#engine_type(pdf)", allocator)
	defer delete(tokens)
	diagnostic := vesti.diagnostic_init(allocator)
	defer vesti.diagnostic_deinit(&diagnostic)
	engine := vesti.Latex_Engine.tectonic
	options := vesti.parser_options_default(allocator)
	options.diagnostic = &diagnostic
	options.engine = &engine
	options.perform_file_operations = false
	statements, parsed := vesti.parser_parse(tokens[:], options)
	if !testing.expectf(t, parsed, "parser failed: %s", diagnostic.message) { return }
	defer vesti.stmt_list_deinit(&statements, allocator)
	testing.expect_value(t, engine, vesti.Latex_Engine.pdflatex)
}

parser_test_real_project :: proc(t: ^testing.T, path: string) {
	allocator := context.allocator
	bytes, read_err := os.read_entire_file(path, allocator)
	if !testing.expectf(t, read_err == nil, "cannot read %s", path) {
		return
	}
	defer delete(bytes, allocator)

	diagnostic := vesti.diagnostic_init(allocator)
	defer vesti.diagnostic_deinit(&diagnostic)
	directory := filepath.dir(path)
	preprocessor, init_err := vesti.preprocessor_init(
		string(bytes),
		directory,
		&diagnostic,
		allocator,
	)
	if !testing.expectf(t, init_err == nil, "cannot initialize preprocessor for %s", path) {
		return
	}
	defer vesti.preprocessor_deinit(&preprocessor)
	tokens, processed := vesti.preprocessor_process(&preprocessor)
	if !testing.expectf(
		t,
		processed,
		"preprocessor failed for %s: %s",
		path,
		diagnostic.message,
	) {
		return
	}
	defer vesti.token_list_deinit(&tokens, allocator)

	options := vesti.parser_options_default(allocator)
	options.diagnostic = &diagnostic
	options.allow_lua_code = true
	options.file_directory = directory
	options.perform_file_operations = false
	statements, parsed := vesti.parser_parse(tokens.items[:], options)
	if !testing.expectf(t, parsed, "parser failed for %s: %s", path, diagnostic.message) {
		return
	}
	defer vesti.stmt_list_deinit(&statements, allocator)

	output := strings.builder_make(allocator)
	defer strings.builder_destroy(&output)
	generated := vesti.codegen(statements[:], nil, &output, &diagnostic, allocator)
	if !testing.expectf(t, generated, "codegen failed for %s: %s", path, diagnostic.message) {
		return
	}
}

@(test)
parser_real_projects_smoke_test :: proc(t: ^testing.T) {
	directories := [?]string{
		"tests/AApproach",
		"tests/Half_Space",
		"tests/Kindergarten_Volume2",
	}
	file_count := 0
	for directory in directories {
		walker := os.walker_create(directory)
		for info in os.walker_walk(&walker) {
			if info.type != .Regular || !strings.has_suffix(info.fullpath, ".ves") {
				continue
			}
			file_count += 1
			parser_test_real_project(t, info.fullpath)
		}
		failed_path, walk_err := os.walker_error(&walker)
		testing.expectf(t, walk_err == nil, "cannot walk %s: %s", failed_path, walk_err)
		os.walker_destroy(&walker)
	}
	testing.expectf(t, file_count >= 70, "expected the full real-project corpus, found %d files", file_count)
}

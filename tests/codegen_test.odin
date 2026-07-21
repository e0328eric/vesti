package defkind_test

import vesti "../src"

import "core:strings"
import "core:testing"

cg_stmt_list :: proc(values: ..vesti.Stmt) -> vesti.Stmt_List {
	result := make(vesti.Stmt_List)
	for value in values {
		append(&result, value)
	}
	return result
}

cg_text :: proc(value: string) -> vesti.Stmt {
	return vesti.Text_Lit_Stmt{text = vesti.cow_str_borrowed(value)}
}

cg_math :: proc(value: string) -> vesti.Stmt {
	return vesti.Math_Lit_Stmt{text = value}
}

cg_bytes :: proc(value: string) -> vesti.Byte_Buffer {
	result := make(vesti.Byte_Buffer)
	append(&result, value)
	return result
}

cg_cow_list :: proc(values: ..string) -> vesti.Cow_Str_List {
	result := make(vesti.Cow_Str_List)
	for value in values {
		append(&result, vesti.cow_str_borrowed(value))
	}
	return result
}

cg_expect :: proc(
	t: ^testing.T,
	stmts: ^vesti.Stmt_List,
	expected: string,
	placeholder: ^vesti.Stmt_List = nil,
) {
	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	ok := vesti.codegen(stmts^[:], placeholder, &builder, &diagnostic)
	if !testing.expect_value(t, ok, true) {
		return
	}
	testing.expect_value(t, strings.to_string(builder), expected)
}

@test
codegen_document_math_golden_test :: proc(t: ^testing.T) {
	doc_options := cg_cow_list("a4paper", "twocolumn")
	xcolor_options := cg_cow_list("dvipsnames")
	packages := make(vesti.Use_Package_List)
	append(&packages, vesti.Use_Package{name = vesti.cow_str_borrowed("geometry")})
	append(
		&packages,
		vesti.Use_Package{
			name = vesti.cow_str_borrowed("xcolor"),
			options = xcolor_options,
		},
	)

	numerator := cg_stmt_list(cg_math("1"))
	denominator := cg_stmt_list(cg_math("2"))
	math_inner := cg_stmt_list(
		cg_math("x="),
		vesti.Fraction_Stmt{numerator = numerator, denominator = denominator},
	)
	label := cg_bytes("eq:half")
	stmts := cg_stmt_list(
		vesti.Document_Class_Stmt{
			name = vesti.cow_str_borrowed("article"),
			options = doc_options,
		},
		vesti.Import_Multiple_Pkgs_Stmt{packages = packages},
		vesti.Document_Start_Stmt{},
		cg_text(" "),
		vesti.Math_Ctx_Stmt{state = .Labeled, inner = math_inner, label = label},
		vesti.Document_End_Stmt{},
	)
	defer vesti.stmt_list_deinit(&stmts)

	cg_expect(
		t,
		&stmts,
		"\\documentclass[a4paper,twocolumn]{article}\n" +
		"\\usepackage{amstext}\n" +
		"\\usepackage{geometry}\n" +
		"\\usepackage[dvipsnames]{xcolor}\n" +
		"\n\\begin{document} " +
		"\\begin{equation}\\label{eq:half}x=\\frac{1}{2}\\end{equation}" +
		"\n\\end{document}\n",
	)
}

@test
codegen_inline_constructs_golden_test :: proc(t: ^testing.T) {
	braced_inner := cg_stmt_list(cg_text("grouped"))
	unwrapped_inner := cg_stmt_list(cg_text("raw"))
	plain_inner := cg_stmt_list(cg_text("where"))
	math_inner := cg_stmt_list(
		vesti.Math_Delimiter_Stmt{delimiter = "(", kind = .Left_Big},
		cg_math("x"),
		vesti.Math_Delimiter_Stmt{delimiter = ")", kind = .Right_Big},
		vesti.Plain_Text_In_Math_Stmt{
			add_front_space = true,
			add_back_space = true,
			inner = plain_inner,
		},
	)
	stmts := cg_stmt_list(
		vesti.Nop_Stmt{},
		vesti.Braced_Stmt{inner = braced_inner},
		vesti.Braced_Stmt{unwrap_brace = true, inner = unwrapped_inner},
		vesti.Math_Ctx_Stmt{state = .Inline, inner = math_inner},
		vesti.Import_Single_Pkg_Stmt{
			pkg = vesti.Use_Package{name = vesti.cow_str_borrowed("amsmath")},
		},
	)
	defer vesti.stmt_list_deinit(&stmts)

	cg_expect(
		t,
		&stmts,
		"{grouped}raw$\\left(x\\right)\\text{ where }$\\usepackage{amsmath}\n",
	)
}

@test
codegen_environments_and_picture_golden_test :: proc(t: ^testing.T) {
	main_arg := cg_stmt_list(cg_text("bar"))
	optional_arg := cg_stmt_list(cg_text("wide"))
	args := make(vesti.Arg_List)
	append(&args, vesti.Arg{needed = .Star_Arg})
	append(&args, vesti.Arg{needed = .Main_Arg, ctx = main_arg})
	append(&args, vesti.Arg{needed = .Optional, ctx = optional_arg})
	env_inner := cg_stmt_list(cg_text("body"))
	env_label := cg_bytes("env:foo")

	picture_inner := cg_stmt_list(cg_text("dot"))
	unit_length := cg_bytes("1mm")
	phantom_args := make(vesti.Arg_List)
	phantom_optional := cg_stmt_list(cg_text("ht"))
	append(&phantom_args, vesti.Arg{needed = .Optional, ctx = phantom_optional})

	stmts := cg_stmt_list(
		vesti.Environment_Stmt{
			name = vesti.cow_str_borrowed("foo"),
			args = args,
			inner = env_inner,
			label = env_label,
		},
		cg_text("|"),
		vesti.Picture_Environment_Stmt{
			width = 10,
			height = 20,
			xoffset = 1,
			yoffset = 2,
			unit_length = unit_length,
			inner = picture_inner,
		},
		cg_text("|"),
		vesti.Begin_Phantom_Environ_Stmt{
			name = vesti.cow_str_borrowed("figure"),
			args = phantom_args,
			add_newline = true,
		},
		cg_text("caption"),
		vesti.End_Phantom_Environ_Stmt{name = vesti.cow_str_borrowed("figure")},
		cg_text("|"),
		vesti.Import_Vesti_Stmt{name = cg_bytes("chapter.tex")},
		cg_text("|"),
		vesti.File_Path_Stmt{path = vesti.cow_str_borrowed("out/file.tex")},
	)
	defer vesti.stmt_list_deinit(&stmts)

	cg_expect(
		t,
		&stmts,
		"\\begin{foo}*{bar}[wide]\\label{env:foo}body\\end{foo}|" +
		"\\setlength{\\unitlength}{1mm}\n\\begin{picture}(10,20)(1,2)dot\\end{picture}|" +
		"\\begin{figure}[ht]\ncaption\\end{figure}|" +
		"\\input{chapter.tex}|out/file.tex",
	)
}

@test
codegen_definitions_and_placeholder_golden_test :: proc(t: ^testing.T) {
	globals := cg_stmt_list(cg_text("GLOBAL"))
	defer vesti.stmt_list_deinit(&globals)

	function_body := cg_stmt_list(cg_text(" \n value=#1 \t"))
	begin_body := cg_stmt_list(cg_text(" \r\n BEGIN \t"))
	end_body := cg_stmt_list(cg_text("\n END  "))
	stmts := cg_stmt_list(
		vesti.Placeholder_Stmt{},
		vesti.Define_Function_Stmt{
			name = vesti.cow_str_borrowed("foo"),
			param_str = vesti.cow_str_borrowed("#1"),
			inner = function_body,
		},
		vesti.Define_Env_Stmt{
			name = vesti.cow_str_borrowed("box"),
			param_str = vesti.cow_str_borrowed("m"),
			inner_begin = begin_body,
			inner_end = end_body,
		},
		vesti.Defun_Param_List_Stmt{nested = 2, arg_num = 3},
	)
	defer vesti.stmt_list_deinit(&stmts)

	cg_expect(
		t,
		&stmts,
		"\n%%%    Global Definitions\nGLOBAL\n%%%    End Global Definitions\n" +
		"\\expandafter\\ifx\\csname foo\\endcsname\\relax\n" +
		"\\protected\\def\\foo#1{value=#1}%\n" +
		"\\else\\errmessage{foo is already defined}\\fi\n" +
		"\\NewDocumentEnvironment{box}{m}{BEGIN}{END}%\n" +
		"####3",
		&globals,
	)
}

Codegen_Lua_Test_State :: struct {
	saw_expected_code: bool,
}

codegen_lua_test_evaluator :: proc(
	code: string,
	output: ^strings.Builder,
	user_data: rawptr,
) -> bool {
	state := cast(^Codegen_Lua_Test_State)user_data
	state.saw_expected_code = code == "helper()\nmain()"
	_ = strings.write_string(output, "EVAL")
	return state.saw_expected_code
}

@test
codegen_lua_import_export_and_disabled_golden_test :: proc(t: ^testing.T) {
	export_code := cg_bytes("helper()")
	main_code := cg_bytes("main()")
	imports := make([dynamic]string)
	append(&imports, "common")
	stmts := cg_stmt_list(
		vesti.Lua_Code_Stmt{code_export = "common", code = export_code},
		vesti.Lua_Code_Stmt{code_import = imports, code = main_code},
	)
	defer vesti.stmt_list_deinit(&stmts)

	// Passing no evaluator mirrors the original `lua = null` path.
	cg_expect(t, &stmts, "")

	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	state := Codegen_Lua_Test_State{}
	generator := vesti.codegen_init(
		context.allocator,
		"",
		stmts[:],
		false,
		&diagnostic,
		codegen_lua_test_evaluator,
		rawptr(&state),
	)
	defer vesti.codegen_deinit(&generator)

	testing.expect_value(t, vesti.codegen_emit(&generator, nil, &builder), true)
	testing.expect_value(t, state.saw_expected_code, true)
	testing.expect_value(t, strings.to_string(builder), "EVAL")
}

@test
codegen_defun_parameter_overflow_diagnostic_test :: proc(t: ^testing.T) {
	stmts := cg_stmt_list(
		vesti.Defun_Param_List_Stmt{nested = uint(size_of(uint)*8), arg_num = 1},
	)
	defer vesti.stmt_list_deinit(&stmts)
	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	testing.expect_value(t, vesti.codegen(stmts[:], nil, &builder, &diagnostic), false)
	testing.expect_value(t, diagnostic.kind, vesti.Diagnostic_Kind.Parse)
	testing.expect_value(t, diagnostic.has_span, true)
}

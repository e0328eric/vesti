package defkind_test

import vesti "../src"

import "core:strings"
import "core:testing"

@test
defun_primitive_default_test :: proc(t: ^testing.T) {
	kind, ok := vesti.parse_defun_kind("", false)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, vesti.defun_kind_trim_left(kind), true)
	testing.expect_value(t, vesti.defun_kind_trim_right(kind), true)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	vesti.defun_kind_write_prologue(kind, "foo", &builder)
	vesti.defun_kind_write_param(kind, nil, &builder)
	vesti.defun_kind_write_epilogue(kind, "foo", &builder)
	testing.expect_value(
		t,
		strings.to_string(builder),
		"\\expandafter\\ifx\\csname foo\\endcsname\\relax\n" +
		"\\protected\\def\\foo{}%\n" +
		"\\else\\errmessage{foo is already defined}\\fi\n",
	)
}

@test
defun_primitive_flags_test :: proc(t: ^testing.T) {
	kind, ok := vesti.parse_defun_kind("rg!e<>", false)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, vesti.defun_kind_trim_left(kind), false)
	testing.expect_value(t, vesti.defun_kind_trim_right(kind), false)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	vesti.defun_kind_write_prologue(kind, "foo", &builder)
	vesti.defun_kind_write_param(kind, "#1", &builder)
	vesti.defun_kind_write_epilogue(kind, "foo", &builder)
	testing.expect_value(t, strings.to_string(builder), "\\xdef\\foo#1{}%\n")
}

@test
defun_xparse_test :: proc(t: ^testing.T) {
	kind, ok := vesti.parse_defun_kind("pe", true)
	testing.expect_value(t, ok, true)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	vesti.defun_kind_write_prologue(kind, "foo", &builder)
	vesti.defun_kind_write_param(kind, "m O{}", &builder)
	vesti.defun_kind_write_epilogue(kind, "foo", &builder)
	testing.expect_value(
		t,
		strings.to_string(builder),
		"\\ProvideExpandableDocumentCommand{\\foo}{m O{}}{}%\n",
	)
}

@test
defun_invalid_mutates_like_zig_test :: proc(t: ^testing.T) {
	kind := vesti.Defun_Kind{redef = true}
	testing.expect_value(t, vesti.defun_kind_parse(&kind, "p", false), false)
	testing.expect_value(t, kind.redef, true)
	testing.expect_value(t, kind.provide, true)

	kind = {}
	testing.expect_value(t, vesti.defun_kind_parse(&kind, "g", true), false)
	testing.expect_value(t, kind.global, true)
	testing.expect_value(t, kind.xparse, true)

	kind = {}
	testing.expect_value(t, vesti.defun_kind_parse(&kind, "rp", true), false)
	testing.expect_value(t, kind.redef, true)
	testing.expect_value(t, kind.provide, true)

	kind = vesti.Defun_Kind{redef = true}
	testing.expect_value(t, vesti.defun_kind_parse(&kind, "?", false), false)
	testing.expect_value(t, kind.redef, true)
	testing.expect_value(t, kind.xparse, false)
}

@test
defenv_parse_and_emit_test :: proc(t: ^testing.T) {
	kind, ok := vesti.parse_defenv_kind("p<>()")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, vesti.defenv_kind_begin_trim_left(kind), false)
	testing.expect_value(t, vesti.defenv_kind_begin_trim_right(kind), false)
	testing.expect_value(t, vesti.defenv_kind_end_trim_left(kind), false)
	testing.expect_value(t, vesti.defenv_kind_end_trim_right(kind), false)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	vesti.defenv_kind_write_prologue(kind, "box", &builder)
	vesti.defenv_kind_write_param(kind, "O{} m", &builder)
	vesti.defenv_kind_write_epilogue(kind, &builder)
	testing.expect_value(
		t,
		strings.to_string(builder),
		"\\ProvideDocumentEnvironment{box}{O{} m}{}%\n",
	)
}

@test
defenv_invalid_mutates_like_zig_test :: proc(t: ^testing.T) {
	kind := vesti.Defenv_Kind{redef = true}
	testing.expect_value(t, vesti.defenv_kind_parse(&kind, "p!",), false)
	testing.expect_value(t, kind.redef, true)
	testing.expect_value(t, kind.provide, true)
	testing.expect_value(t, kind.declare, true)
}

@test
ast_recursive_deinit_test :: proc(t: ^testing.T) {
	inner := make(vesti.Stmt_List)
	inner_text, err := vesti.cow_str_owned_copy("body")
	if !testing.expect_value(t, err, nil) {
		return
	}
	append(&inner, vesti.Text_Lit_Stmt{text = inner_text})

	arg_ctx := make(vesti.Stmt_List)
	arg_text, arg_err := vesti.cow_str_owned_copy("argument")
	if !testing.expect_value(t, arg_err, nil) {
		vesti.stmt_list_deinit(&inner)
		return
	}
	append(&arg_ctx, vesti.Text_Lit_Stmt{text = arg_text})
	args := make(vesti.Arg_List)
	append(&args, vesti.Arg{needed = .Optional, ctx = arg_ctx})

	label := make(vesti.Byte_Buffer)
	append(&label, "eq:owned")
	name, name_err := vesti.cow_str_owned_copy("owned-environment")
	if !testing.expect_value(t, name_err, nil) {
		vesti.stmt_list_deinit(&inner)
		vesti.arg_list_deinit(&args)
		delete(label)
		return
	}
	stmt := vesti.Stmt(vesti.Environment_Stmt{
		name  = name,
		args  = args,
		inner = inner,
		label = label,
	})

	vesti.stmt_deinit(&stmt)
	_, is_nop := stmt.(vesti.Nop_Stmt)
	testing.expect_value(t, is_nop, true)
	vesti.stmt_deinit(&stmt) // Cleanup helpers are intentionally idempotent.
}

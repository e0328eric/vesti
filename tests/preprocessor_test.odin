package defkind_test

import "core:os"
import "core:strings"
import "core:testing"

import vesti "../src"

run_preprocessor :: proc(
	t: ^testing.T,
	source: string,
	base_dir := ".",
) -> (vesti.Token_List, bool) {
	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)
	preprocessor, init_err := vesti.preprocessor_init(
		source,
		base_dir,
		&diagnostic,
	)
	if init_err != nil {
		testing.expect(t, false)
		return {}, false
	}
	tokens, ok := vesti.preprocessor_process(&preprocessor)
	// Included token literals must remain valid after this deinitialization;
	// Token_List owns the included source buffers.
	vesti.preprocessor_deinit(&preprocessor)
	return tokens, ok
}

expect_preprocessed_text :: proc(
	t: ^testing.T,
	tokens: ^vesti.Token_List,
	expected: string,
	ignore_whitespace := false,
) {
	builder, builder_err := strings.builder_make()
	if builder_err != nil {
		testing.expect(t, false)
		return
	}
	defer strings.builder_destroy(&builder)
	for token in tokens.items {
		if token.kind == .Eof {
			continue
		}
		if ignore_whitespace &&
		   (token.kind == .Space || token.kind == .Tab || token.kind == .Newline) {
			continue
		}
		strings.write_string(&builder, token.literal.in_text)
	}
	testing.expect_value(t, strings.to_string(builder), expected)
}

@(test)
preprocessor_def_nested_args_and_undef :: proc(t: ^testing.T) {
	source := `#def #pair {#1+#2}
#def #twice {#pair(#1)(#1)}
#twice(x)
#undef #pair
#ifdef #pair
bad
#else
good
#endif
`
	tokens, ok := run_preprocessor(t, source)
	if !ok {
		testing.expect(t, false)
		return
	}
	defer vesti.token_list_deinit(&tokens)
	expect_preprocessed_text(t, &tokens, "x+x\ngood\n")
}

@(test)
preprocessor_indented_def_consumes_following_indent_test :: proc(t: ^testing.T) {
	source := "before\n    #def #x {X}\n    after"
	tokens, ok := run_preprocessor(t, source)
	if !ok {
		testing.expect(t, false)
		return
	}
	defer vesti.token_list_deinit(&tokens)
	// The directive line's indentation remains, while Zig's cursor behavior
	// consumes the indentation immediately following the #def line.
	expect_preprocessed_text(t, &tokens, "before\n    after")
}

@(test)
preprocessor_lua_conditionals_and_inactive_nesting :: proc(t: ^testing.T) {
	source := `#def #n {2}
#if (#n * 3 == 6 and not false)
yes
#elif (true)
bad-elif
#else
bad-else
#endif
#if (false)
#if (this is not valid lua !!!)
bad-nested
#endif
#else
nested
#endif
`
	tokens, ok := run_preprocessor(t, source)
	if !ok {
		testing.expect(t, false)
		return
	}
	defer vesti.token_list_deinit(&tokens)
	expect_preprocessed_text(t, &tokens, "yes\nnested\n")
}

@(test)
preprocessor_elifdef_and_elifndef :: proc(t: ^testing.T) {
	source := `#def #flag {true}
#if (false)
bad-if
#elifdef #flag
elifdef-selected
#elifndef #missing
bad-late-elif
#else
bad-else
#endif
#undef #flag
#ifdef #flag
bad-ifdef
#elifndef #flag
elifndef-selected
#endif
`
	tokens, ok := run_preprocessor(t, source)
	if !ok {
		testing.expect(t, false)
		return
	}
	defer vesti.token_list_deinit(&tokens)
	expect_preprocessed_text(t, &tokens, "elifdef-selected\nelifndef-selected\n")
}

@(test)
preprocessor_identifier_modes :: proc(t: ^testing.T) {
	source := `#at_on
\foo@bar
#at_off
\foo@bar
#ltx3_on
\foo_bar:
#ltx3_off
\foo_bar:
`
	tokens, ok := run_preprocessor(t, source)
	if !ok {
		testing.expect(t, false)
		return
	}
	defer vesti.token_list_deinit(&tokens)
	found_at_on, found_at_off := false, false
	found_ltx3_on, found_ltx3_off := false, false
	found_at_identifier, found_ltx3_identifier := false, false
	found_plain_after_at, found_plain_after_ltx3 := false, false
	for token in tokens.items {
		switch token.literal.in_text {
		case "\\makeatletter": found_at_on = true
		case "\\makeatother":  found_at_off = true
		case "\\ExplSyntaxOn":  found_ltx3_on = true
		case "\\ExplSyntaxOff": found_ltx3_off = true
		case "\\foo@bar":
			found_at_identifier = token.kind == .MakeAtLetterFnt
		case "\\foo_bar:":
			found_ltx3_identifier = token.kind == .Latex3Fnt
		case "@":
			found_plain_after_at = token.kind == .At
		case "_":
			found_plain_after_ltx3 = token.kind == .Subscript
		case:
		}
	}
	testing.expect(t, found_at_on && found_at_off)
	testing.expect(t, found_ltx3_on && found_ltx3_off)
	testing.expect(t, found_at_identifier && found_ltx3_identifier)
	testing.expect(t, found_plain_after_at && found_plain_after_ltx3)
}

@(test)
preprocessor_nested_include_and_owned_source :: proc(t: ^testing.T) {
	// Re-including after the first include has returned is not a cycle.
	source := "#include(parent.ves)\n#include(parent.ves)\n#from_include(ok)"
	tokens, ok := run_preprocessor(t, source, "tests/preprocessor_fixtures")
	if !ok {
		testing.expect(t, false)
		return
	}
	defer vesti.token_list_deinit(&tokens)
	testing.expect_value(t, len(tokens.owned_sources), 4)
	expect_preprocessed_text(t, &tokens, "included:ok", true)
}

@(test)
preprocessor_noltx3_rejects_latex3_modes :: proc(t: ^testing.T) {
	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)
	preprocessor, init_err := vesti.preprocessor_init(
		"#noltx3\n#ltx3_on\n",
		".",
		&diagnostic,
	)
	if init_err != nil {
		testing.expect(t, false)
		return
	}
	defer vesti.preprocessor_deinit(&preprocessor)
	tokens, ok := vesti.preprocessor_process(&preprocessor)
	if ok {
		vesti.token_list_deinit(&tokens)
	}
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(diagnostic.message, "disabled"))
}

@(test)
preprocessor_include_cycle_is_diagnostic :: proc(t: ^testing.T) {
	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)
	preprocessor, init_err := vesti.preprocessor_init(
		"#include(cycle_a.ves)",
		"tests/preprocessor_fixtures",
		&diagnostic,
	)
	if init_err != nil {
		testing.expect(t, false)
		return
	}
	defer vesti.preprocessor_deinit(&preprocessor)
	tokens, ok := vesti.preprocessor_process(&preprocessor)
	if ok {
		vesti.token_list_deinit(&tokens)
	}
	testing.expect(t, !ok)
	testing.expect_value(t, diagnostic.kind, vesti.Diagnostic_Kind.Parse)
	testing.expect(t, strings.contains(diagnostic.message, "circular"))
}

@(test)
preprocessor_real_project_sources :: proc(t: ^testing.T) {
	cases := [?]struct {
		path:     string,
		base_dir: string,
	}{
		{
			"tests/Half_Space/chapter2/basic_facts.ves",
			"tests/Half_Space/chapter2",
		},
		{
			"tests/Kindergarten_Volume2/General-Topology/separation-axioms.ves",
			"tests/Kindergarten_Volume2/General-Topology",
		},
	}
	for test_case in cases {
		bytes, read_err := os.read_entire_file(test_case.path, context.allocator)
		if read_err != nil {
			testing.expect(t, false)
			continue
		}
		tokens, ok := run_preprocessor(t, string(bytes), test_case.base_dir)
		if ok {
			testing.expect(t, len(tokens.items) > 20)
			vesti.token_list_deinit(&tokens)
		} else {
			testing.expect(t, false)
		}
		delete(bytes, context.allocator)
	}
}

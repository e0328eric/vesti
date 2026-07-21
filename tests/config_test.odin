package defkind_test

import "core:testing"

import vesti "../src"

@test
config_json_defaults_and_overrides_test :: proc(t: ^testing.T) {
	defaults, ok := vesti.config_parse_json(`{}`)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, defaults.engine, vesti.Latex_Engine.tectonic)
	testing.expect_value(t, defaults.lua.make_log, false)
	testing.expect_value(t, defaults.lua.line_limit, 45)

	config, parsed := vesti.config_parse_json(
		`{"engine":"xelatex","lua":{"make_log":true,"line_limit":72}}`,
	)
	testing.expect_value(t, parsed, true)
	testing.expect_value(t, config.engine, vesti.Latex_Engine.xelatex)
	testing.expect_value(t, config.lua.make_log, true)
	testing.expect_value(t, config.lua.line_limit, 72)
}

@test
config_json_rejects_bad_values_test :: proc(t: ^testing.T) {
	diagnostic := vesti.diagnostic_init()
	defer vesti.diagnostic_deinit(&diagnostic)

	_, syntax_ok := vesti.config_parse_json(`{"engine":`, &diagnostic)
	testing.expect_value(t, syntax_ok, false)
	testing.expect_value(t, diagnostic.kind, vesti.Diagnostic_Kind.IO)

	_, engine_ok := vesti.config_parse_json(`{"engine":"rubber"}`, &diagnostic)
	testing.expect_value(t, engine_ok, false)

	_, limit_ok := vesti.config_parse_json(`{"lua":{"line_limit":0}}`, &diagnostic)
	testing.expect_value(t, limit_ok, false)

	_, type_ok := vesti.config_parse_json(`{"lua":{"line_limit":"45"}}`, &diagnostic)
	testing.expect_value(t, type_ok, false)

	_, trailing_ok := vesti.config_parse_json(`{} trailing`, &diagnostic)
	testing.expect_value(t, trailing_ok, false)

	_, comma_ok := vesti.config_parse_json(`{"engine":"tectonic",}`, &diagnostic)
	testing.expect_value(t, comma_ok, false)
}

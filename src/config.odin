package main

import "core:mem"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

Latex_Engine :: enum u8 {
	latex,
	pdflatex,
	xelatex,
	lualatex,
	tectonic,
}

latex_engine_string :: proc(engine: Latex_Engine) -> string {
	switch engine {
	case .latex:     return "latex"
	case .pdflatex:  return "pdflatex"
	case .xelatex:   return "xelatex"
	case .lualatex:  return "lualatex"
	case .tectonic:  return "tectonic"
	}
	return "tectonic"
}

latex_engine_parse :: proc(value: string) -> (Latex_Engine, bool) {
	trimmed := strings.trim(value, " .\t\r\n\"")
	switch trimmed {
	case "latex", "plain":       return .latex, true
	case "pdflatex", "pdf":      return .pdflatex, true
	case "xelatex", "xe":        return .xelatex, true
	case "lualatex", "lua":      return .lualatex, true
	case "tectonic", "tect":     return .tectonic, true
	}
	return .tectonic, false
}

Config :: struct {
	engine: Latex_Engine,
	lua: struct {
		make_log:  bool,
		line_limit: int,
	},
}

config_default :: proc() -> Config {
	return Config{
		engine = .tectonic,
		lua = {
			make_log = false,
			line_limit = 45,
		},
	}
}

config_directory :: proc(allocator := context.allocator) -> (string, bool) {
	when ODIN_OS == .Windows {
		base, found := os.lookup_env("APPDATA", allocator)
		if !found {
			return "", false
		}
		defer delete(base, allocator)
		path, err := filepath.join({base, "vesti"}, allocator)
		return path, err == nil
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		base, found := os.lookup_env("HOME", allocator)
		if !found {
			return "", false
		}
		defer delete(base, allocator)
		path, err := filepath.join({base, ".config", "vesti"}, allocator)
		return path, err == nil
	} else {
		return "", false
	}
}

config_type_error :: proc(
	diagnostic: ^Diagnostic,
	field: string,
	source_name: string,
) {
	if diagnostic != nil {
		_ = diagnostic_setf(
			diagnostic,
			.IO,
			{},
			false,
			"use the documented value type",
			"invalid type for %s in %s",
			field,
			source_name,
		)
	}
}

config_from_value :: proc(
	encoded: json.Value,
	source_name: string,
	diagnostic: ^Diagnostic = nil,
) -> (Config, bool) {
	config := config_default()
	root, root_ok := encoded.(json.Object)
	if !root_ok {
		if diagnostic != nil {
			_ = diagnostic_setf(
				diagnostic,
				.IO,
				{},
				false,
				"configuration must be an object/map",
				"configuration in %s must be an object/map",
				source_name,
			)
		}
		return config, false
	}

	if raw, found := root["engine"]; found {
		value, type_ok := raw.(json.String)
		if !type_ok {
			config_type_error(diagnostic, "engine", source_name)
			return config_default(), false
		}
		engine, ok := latex_engine_parse(value)
		if !ok {
			if diagnostic != nil {
				_ = diagnostic_setf(
					diagnostic,
					.IO,
					{},
					false,
					"valid engines are latex, pdflatex, xelatex, lualatex, and tectonic",
					"invalid engine in %s: %s",
					source_name,
					value,
				)
			}
			return config_default(), false
		}
		config.engine = engine
	}
	if raw, found := root["lua"]; found {
		lua, type_ok := raw.(json.Object)
		if !type_ok {
			config_type_error(diagnostic, "lua", source_name)
			return config_default(), false
		}
		if value, present := lua["make_log"]; present {
			make_log, value_ok := value.(json.Boolean)
			if !value_ok {
				config_type_error(diagnostic, "lua.make_log", source_name)
				return config_default(), false
			}
			config.lua.make_log = make_log
		}
		if value, present := lua["line_limit"]; present {
			line_limit_64, value_ok := value.(json.Integer)
			if !value_ok || line_limit_64 > i64(max(int)) {
				config_type_error(diagnostic, "lua.line_limit", source_name)
				return config_default(), false
			}
			line_limit := int(line_limit_64)
			if line_limit < 1 {
				if diagnostic != nil {
					_ = diagnostic_setf(
						diagnostic,
						.IO,
						{},
						false,
						"",
						"invalid lua.line_limit in %s",
						source_name,
					)
				}
				return config_default(), false
			}
			config.lua.line_limit = line_limit
		}
	}
	return config, true
}

config_parse :: proc(
	contents: string,
	format: Data_Format,
	source_name: string,
	diagnostic: ^Diagnostic = nil,
	allocator: mem.Allocator = context.allocator,
) -> (Config, bool) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&arena)
	value, parse_err := data_parse(
		contents,
		format,
		mem.dynamic_arena_allocator(&arena),
	)
	if parse_err != .None {
		if diagnostic != nil {
			_ = diagnostic_setf(
				diagnostic,
				.IO,
				{},
				false,
				"configuration must contain exactly one valid document",
				"invalid %s configuration %s: %s",
				data_format_name(format),
				source_name,
				data_parse_error_string(parse_err),
			)
		}
		return config_default(), false
	}
	return config_from_value(value, source_name, diagnostic)
}

config_parse_json :: proc(
	contents: string,
	diagnostic: ^Diagnostic = nil,
	allocator: mem.Allocator = context.allocator,
) -> (Config, bool) {
	return config_parse(contents, .JSON, "config.json", diagnostic, allocator)
}

config_parse_yaml :: proc(
	contents: string,
	diagnostic: ^Diagnostic = nil,
	allocator: mem.Allocator = context.allocator,
) -> (Config, bool) {
	return config_parse(contents, .YAML, "config.yaml", diagnostic, allocator)
}

config_parse_toml :: proc(
	contents: string,
	diagnostic: ^Diagnostic = nil,
	allocator: mem.Allocator = context.allocator,
) -> (Config, bool) {
	return config_parse(contents, .TOML, "config.toml", diagnostic, allocator)
}

config_parse_messagepack :: proc(
	contents: string,
	diagnostic: ^Diagnostic = nil,
	allocator: mem.Allocator = context.allocator,
) -> (Config, bool) {
	return config_parse(contents, .MessagePack, "config.msgpack", diagnostic, allocator)
}

config_load :: proc(
	diagnostic: ^Diagnostic = nil,
	allocator: mem.Allocator = context.allocator,
) -> (Config, bool) {
	directory, ok := config_directory(allocator)
	if !ok {
		return config_default(), true // no usable config directory: keep defaults
	}
	defer delete(directory, allocator)
	file, find_err := data_find_file(directory, "config", allocator)
	switch find_err {
	case .Not_Found:
		return config_default(), true
	case .Ambiguous:
		if diagnostic != nil {
			_ = diagnostic_set(
				diagnostic,
				.IO,
				"multiple Vesti configuration files found; keep exactly one of config.json, config.yaml, config.yml, config.toml, or config.msgpack",
			)
		}
		return config_default(), false
	case .Path_Error:
		return config_default(), false
	case .None:
	}
	defer delete(file.path, allocator)
	data, read_err := os.read_entire_file(file.path, allocator)
	if read_err != nil {
		if diagnostic != nil {
			_ = diagnostic_setf(
				diagnostic,
				.IO,
				{},
				false,
				"",
				"failed to read %s",
				file.path,
			)
		}
		return {}, false
	}
	defer delete(data, allocator)
	return config_parse(
		string(data),
		file.format,
		filepath.base(file.path),
		diagnostic,
		allocator,
	)
}

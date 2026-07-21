package main

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

Vesti_Module_Export :: struct {
	name:     string,
	location: Maybe(string),
}

Vesti_Module :: struct {
	name:    string,
	version: Maybe(string),
	exports: []Vesti_Module_Export,
}

Vesti_Module_JSON_Error :: enum {
	None,
	Invalid_JSON,
	Trailing_Content,
	Root_Not_Object,
	Name_Not_String,
	Version_Not_String_Or_Null,
	Exports_Not_Array,
	Export_Not_Object,
	Export_Name_Not_String,
	Export_Location_Not_String_Or_Null,
	Out_Of_Memory,
}

vesti_module_deinit :: proc(module: ^Vesti_Module, allocator := context.allocator) {
	if len(module.name) > 0 {
		delete(module.name, allocator)
	}
	if version, ok := module.version.?; ok && len(version) > 0 {
		delete(version, allocator)
	}
	for &item in module.exports {
		if len(item.name) > 0 {
			delete(item.name, allocator)
		}
		if location, ok := item.location.?; ok && len(location) > 0 {
			delete(location, allocator)
		}
	}
	delete(module.exports, allocator)
	module^ = {}
}

vesti_module_error_string :: proc(err: Vesti_Module_JSON_Error) -> string {
	switch err {
	case .None:                               return "none"
	case .Invalid_JSON:                       return "invalid document"
	case .Trailing_Content:                   return "trailing content"
	case .Root_Not_Object:                    return "manifest must be an object"
	case .Name_Not_String:                    return "name must be a string"
	case .Version_Not_String_Or_Null:         return "version must be a string or null"
	case .Exports_Not_Array:                  return "exports must be an array"
	case .Export_Not_Object:                  return "each export must be an object"
	case .Export_Name_Not_String:             return "export name must be a string"
	case .Export_Location_Not_String_Or_Null: return "export location must be a string or null"
	case .Out_Of_Memory:                      return "out of memory"
	}
	return "invalid manifest"
}

vesti_module_json_error_string :: proc(err: Vesti_Module_JSON_Error) -> string {
	if err == .Invalid_JSON do return "invalid JSON"
	return vesti_module_error_string(err)
}

vesti_module_parse_failure :: proc(
	module: ^Vesti_Module,
	err: Vesti_Module_JSON_Error,
	allocator: mem.Allocator,
) -> (Vesti_Module, Vesti_Module_JSON_Error) {
	vesti_module_deinit(module, allocator)
	return {}, err
}

vesti_module_from_value :: proc(
	encoded: json.Value,
	allocator: mem.Allocator = context.allocator,
) -> (module: Vesti_Module, module_err: Vesti_Module_JSON_Error) {
	root, root_ok := encoded.(json.Object)
	if !root_ok {
		return vesti_module_parse_failure(&module, .Root_Not_Object, allocator)
	}

	if raw_name, found := root["name"]; found {
		name, type_ok := raw_name.(json.String)
		if !type_ok {
			return vesti_module_parse_failure(&module, .Name_Not_String, allocator)
		}
		cloned, clone_err := strings.clone(name, allocator)
		if clone_err != nil {
			return vesti_module_parse_failure(&module, .Out_Of_Memory, allocator)
		}
		module.name = cloned
	}

	if raw_version, found := root["version"]; found {
		if version, type_ok := raw_version.(json.String); type_ok {
			cloned, clone_err := strings.clone(version, allocator)
			if clone_err != nil {
				return vesti_module_parse_failure(&module, .Out_Of_Memory, allocator)
			}
			module.version = cloned
		} else if _, null_ok := raw_version.(json.Null); !null_ok {
			return vesti_module_parse_failure(
				&module,
				.Version_Not_String_Or_Null,
				allocator,
			)
		}
	}

	raw_exports, exports_found := root["exports"]
	if !exports_found {
		return module, .None
	}
	exports, exports_ok := raw_exports.(json.Array)
	if !exports_ok {
		return vesti_module_parse_failure(&module, .Exports_Not_Array, allocator)
	}
	module.exports = make([]Vesti_Module_Export, len(exports), allocator)
	for raw_export, index in exports {
		export_object, export_ok := raw_export.(json.Object)
		if !export_ok {
			return vesti_module_parse_failure(&module, .Export_Not_Object, allocator)
		}

		if raw_name, found := export_object["name"]; found {
			name, type_ok := raw_name.(json.String)
			if !type_ok {
				return vesti_module_parse_failure(&module, .Export_Name_Not_String, allocator)
			}
			cloned, clone_err := strings.clone(name, allocator)
			if clone_err != nil {
				return vesti_module_parse_failure(&module, .Out_Of_Memory, allocator)
			}
			module.exports[index].name = cloned
		}

		if raw_location, found := export_object["location"]; found {
			if location, type_ok := raw_location.(json.String); type_ok {
				cloned, clone_err := strings.clone(location, allocator)
				if clone_err != nil {
					return vesti_module_parse_failure(&module, .Out_Of_Memory, allocator)
				}
				module.exports[index].location = cloned
			} else if _, null_ok := raw_location.(json.Null); !null_ok {
				return vesti_module_parse_failure(
					&module,
					.Export_Location_Not_String_Or_Null,
					allocator,
				)
			}
		}
	}

	return module, .None
}

vesti_module_parse :: proc(
	contents: string,
	format: Data_Format,
	allocator: mem.Allocator = context.allocator,
) -> (module: Vesti_Module, module_err: Vesti_Module_JSON_Error) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&arena)
	value, parse_err := data_parse(
		contents,
		format,
		mem.dynamic_arena_allocator(&arena),
	)
	if parse_err == .Trailing_Content {
		return {}, .Trailing_Content
	}
	if parse_err != .None {
		if parse_err == .Out_Of_Memory do return {}, .Out_Of_Memory
		return {}, .Invalid_JSON
	}
	return vesti_module_from_value(value, allocator)
}

vesti_module_parse_json :: proc(
	contents: string,
	allocator: mem.Allocator = context.allocator,
) -> (Vesti_Module, Vesti_Module_JSON_Error) {
	return vesti_module_parse(contents, .JSON, allocator)
}

vesti_module_parse_yaml :: proc(
	contents: string,
	allocator: mem.Allocator = context.allocator,
) -> (Vesti_Module, Vesti_Module_JSON_Error) {
	return vesti_module_parse(contents, .YAML, allocator)
}

vesti_module_parse_toml :: proc(
	contents: string,
	allocator: mem.Allocator = context.allocator,
) -> (Vesti_Module, Vesti_Module_JSON_Error) {
	return vesti_module_parse(contents, .TOML, allocator)
}

vesti_module_parse_messagepack :: proc(
	contents: string,
	allocator: mem.Allocator = context.allocator,
) -> (Vesti_Module, Vesti_Module_JSON_Error) {
	return vesti_module_parse(contents, .MessagePack, allocator)
}

module_error :: proc(
	diagnostic: ^Diagnostic,
	span: Span,
	has_span: bool,
	note: string,
	format: string,
	args: ..any,
) -> bool {
	if diagnostic != nil {
		_ = diagnostic_setf(diagnostic, .IO, span, has_span, note, format, ..args)
	}
	return false
}

download_module :: proc(
	mod_name: string,
	import_span: Span = {},
	has_span := false,
	diagnostic: ^Diagnostic = nil,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	name := strings.trim_left(strings.trim_space(mod_name), "/\\")
	if len(name) == 0 {
		return module_error(
			diagnostic,
			import_span,
			has_span,
			"module names may not be empty",
			"invalid Vesti module name",
		)
	}

	config_path, ok := config_directory(allocator)
	if !ok {
		return module_error(
			diagnostic,
			import_span,
			has_span,
			"set APPDATA on Windows or HOME on Unix",
			"cannot determine the Vesti configuration directory",
		)
	}
	defer delete(config_path, allocator)

	module_dir, join_err := filepath.join({config_path, name}, allocator)
	if join_err != nil {
		return module_error(
			diagnostic,
			import_span,
			has_span,
			"",
			"cannot construct the path for module %s",
			name,
		)
	}
	defer delete(module_dir, allocator)

	manifest_file, manifest_find_err := data_find_file(module_dir, "vesti", allocator)
	if manifest_find_err == .Path_Error {
		return module_error(
			diagnostic,
			import_span,
			has_span,
			"",
			"cannot construct the manifest path for module %s",
			name,
		)
	}
	if manifest_find_err == .Ambiguous {
		return module_error(
			diagnostic,
			import_span,
			has_span,
			"keep exactly one of vesti.json, vesti.yaml, vesti.yml, vesti.toml, or vesti.msgpack",
			"multiple module manifests found for %s",
			name,
		)
	}
	if manifest_find_err == .Not_Found {
		return module_error(
			diagnostic,
			import_span,
			has_span,
			"module manifests are named vesti.json, vesti.yaml, vesti.yml, vesti.toml, or vesti.msgpack",
			"cannot find a manifest for module %s",
			name,
		)
	}
	manifest_path := manifest_file.path
	defer delete(manifest_path, allocator)

	contents, read_err := os.read_entire_file(manifest_path, allocator)
	if read_err != nil {
		return module_error(
			diagnostic,
			import_span,
			has_span,
			"module manifests are named vesti.json, vesti.yaml, vesti.yml, vesti.toml, or vesti.msgpack",
			"cannot open file %s",
			manifest_path,
		)
	}
	defer delete(contents, allocator)

	manifest, parse_err := vesti_module_parse(
		string(contents),
		manifest_file.format,
		allocator,
	)
	if parse_err != .None {
		return module_error(
			diagnostic,
			import_span,
			has_span,
			"module manifests must contain name, version, and exports fields",
			"invalid %s module manifest %s: %s",
			data_format_name(manifest_file.format),
			manifest_path,
			vesti_module_error_string(parse_err),
		)
	}
	defer vesti_module_deinit(&manifest, allocator)

	if len(manifest.name) == 0 || len(manifest.exports) == 0 {
		return module_error(
			diagnostic,
			import_span,
			has_span,
			"a module needs a non-empty name and at least one export",
			"invalid %s module manifest %s",
			data_format_name(manifest_file.format),
			manifest_path,
		)
	}

	for item in manifest.exports {
		if len(item.name) == 0 {
			return module_error(
				diagnostic,
				import_span,
				has_span,
				"export names may not be empty",
				"invalid export in %s",
				manifest_path,
			)
		}

		source, source_err := filepath.join({module_dir, item.name}, allocator)
		if source_err != nil {
			return module_error(
				diagnostic,
				import_span,
				has_span,
				"",
				"cannot construct the source path for export %s",
				item.name,
			)
		}
		defer delete(source, allocator)

		location := VESTI_DUMMY_DIR
		if requested, present := item.location.?; present && len(requested) > 0 {
			location = requested
		}
		if directory_err := os.make_directory_all(location); directory_err != nil {
			return module_error(
				diagnostic,
				import_span,
				has_span,
				"",
				"cannot create module export directory %s",
				location,
			)
		}

		destination, destination_err := filepath.join({location, item.name}, allocator)
		if destination_err != nil {
			return module_error(
				diagnostic,
				import_span,
				has_span,
				"",
				"cannot construct the destination path for export %s",
				item.name,
			)
		}
		defer delete(destination, allocator)

		if copy_err := os.copy_file(destination, source); copy_err != nil {
			return module_error(
				diagnostic,
				import_span,
				has_span,
				"verify that every manifest export exactly matches an installed filename",
				"cannot copy from %s into %s: %s",
				source,
				destination,
				os.error_string(copy_err),
			)
		}
	}

	return true
}

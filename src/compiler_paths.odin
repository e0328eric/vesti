package main

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Compiler_Path_List :: [dynamic]string

// vesti_name_mangle matches std.hash.Fnv1a_64 and Zig's lower-case, unpadded
// hexadecimal formatting exactly.  The returned string belongs to allocator.
vesti_name_mangle :: proc(
	filename: string,
	allocator: mem.Allocator = context.allocator,
) -> (mangled: string, ok: bool) {
	value := hash.fnv64a(transmute([]byte)filename)
	return fmt.aprintf("@vesti__%x.tex", value, allocator = allocator), true
}

// The Zig helper intentionally discards the input directory and changes only
// the final basename.  into is the extension without its leading dot.
change_extension_basename :: proc(
	filename: string,
	into: string,
	allocator: mem.Allocator = context.allocator,
) -> (changed: string, ok: bool) {
	basename := filepath.base(filename)
	dot_index := strings.last_index_byte(basename, '.')
	if dot_index < 0 {
		return "", false
	}

	bytes := make([]byte, dot_index+1+len(into), allocator)
	copy(bytes[:dot_index], transmute([]byte)basename[:dot_index])
	bytes[dot_index] = '.'
	copy(bytes[dot_index+1:], transmute([]byte)into)
	return string(bytes), true
}

// vesti_extension_is_valid preserves the original case-sensitive `.ves`
// check.  In particular, `.VES` is not accepted.
vesti_extension_is_valid :: proc(filename: string) -> bool {
	return filepath.ext(filename) == ".ves"
}

validate_vesti_extension :: vesti_extension_is_valid

// Main inputs keep their basename; imported inputs are named by the hash of
// their full path so equal basenames in different directories cannot collide.
generated_tex_filename :: proc(
	filename: string,
	is_main: bool,
	allocator: mem.Allocator = context.allocator,
) -> (generated: string, ok: bool) {
	if is_main {
		return change_extension_basename(filename, "tex", allocator)
	}
	return vesti_name_mangle(filename, allocator)
}

generated_pdf_filename :: proc(
	filename: string,
	allocator: mem.Allocator = context.allocator,
) -> (generated: string, ok: bool) {
	return change_extension_basename(filename, "pdf", allocator)
}

// These names make the basename-only contract explicit while retaining the
// filename spellings expected by compiler wiring.
generated_tex_basename :: generated_tex_filename
generated_pdf_basename :: generated_pdf_filename

compiler_path_list_deinit :: proc(
	paths: ^Compiler_Path_List,
	allocator: mem.Allocator = context.allocator,
) {
	if paths == nil {
		return
	}
	for path in paths^ {
		delete(path, allocator)
	}
	if paths^ != nil {
		delete(paths^)
	}
	paths^ = nil
}

_compiler_path_is_excluded_directory :: proc(name: string) -> bool {
	switch name {
	case VESTI_DUMMY_DIR,
	     ".git", ".hg", ".svn",
	     ".zig-cache", "zig-out", ".odin-cache", "build":
		return true
	}
	return false
}

_compiler_path_less :: proc(left, right: string) -> bool {
	return strings.compare(left, right) < 0
}

// discover_vesti_files recursively returns owned absolute paths, sorted by
// their byte spelling.  Sorting removes filesystem enumeration order from
// compile_all, while directory pruning keeps generated and build trees out.
discover_vesti_files :: proc(
	root: string,
	allocator: mem.Allocator = context.allocator,
) -> (files: Compiler_Path_List, ok: bool) {
	files = make(Compiler_Path_List, allocator)
	absolute_root, absolute_error := filepath.abs(root, allocator)
	if absolute_error != nil {
		compiler_path_list_deinit(&files, allocator)
		return nil, false
	}
	defer delete(absolute_root, allocator)

	walker := os.walker_create(absolute_root)
	defer os.walker_destroy(&walker)
	if _, walk_error := os.walker_error(&walker); walk_error != nil {
		compiler_path_list_deinit(&files, allocator)
		return nil, false
	}

	for info in os.walker_walk(&walker) {
		if _, walk_error := os.walker_error(&walker); walk_error != nil {
			compiler_path_list_deinit(&files, allocator)
			return nil, false
		}

		if info.type == .Directory {
			if _compiler_path_is_excluded_directory(info.name) {
				os.walker_skip_dir(&walker)
			}
			continue
		}
		if info.type != .Regular || !vesti_extension_is_valid(info.name) {
			continue
		}

		owned_path, clone_error := strings.clone(info.fullpath, allocator)
		if clone_error != nil {
			compiler_path_list_deinit(&files, allocator)
			return nil, false
		}
		if _, append_error := append(&files, owned_path); append_error != nil {
			delete(owned_path, allocator)
			compiler_path_list_deinit(&files, allocator)
			return nil, false
		}
	}

	if _, walk_error := os.walker_error(&walker); walk_error != nil {
		compiler_path_list_deinit(&files, allocator)
		return nil, false
	}
	slice.sort_by(files[:], _compiler_path_less)
	return files, true
}

use std::fs;
use std::io;
use std::path::Path;

use crate::diagnostic::{Diagnostic, IoDiagnostic, ParseDiagnostic};
use crate::lua::Lua;

/// Errors raised while loading or running build Lua scripts.
#[derive(Debug)]
pub enum LuaScriptError {
    CompileVesFailed,
    LuaEvalFailed,
}

pub fn get_build_lua_contents(
    luacode_path: &str,
    diagnostic: &mut Diagnostic<'_>,
) -> Result<Option<String>, LuaScriptError> {
    match fs::read_to_string(luacode_path) {
        Ok(contents) => Ok(Some(contents)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => {
            diagnostic.init_diag_inner(crate::diagnostic::DiagnosticInner::IoError(
                IoDiagnostic::new(None, format!("failed to read {luacode_path}")),
            ));
            Err(LuaScriptError::CompileVesFailed)
        }
    }
}

/// `filename` is only used to compose the error message.
pub fn run_lua_code(
    lua: &mut Lua,
    diagnostic: &mut Diagnostic<'_>,
    luacode_contents: &str,
    filename: &str,
) -> Result<(), LuaScriptError> {
    if lua.eval_code(luacode_contents).is_err() {
        let lua_runtime_err = ParseDiagnostic::lua_eval_failed(
            None,
            format!("failed to run luacode from {filename}"),
            "see above lua error message",
        );
        diagnostic.init_diag_inner(crate::diagnostic::DiagnosticInner::ParseError(
            lua_runtime_err,
        ));
        return Err(LuaScriptError::LuaEvalFailed);
    }
    Ok(())
}

/// Helper used by `Path`-based callers (kept for ergonomics).
pub fn get_build_lua_contents_path(
    luacode_path: &Path,
    diagnostic: &mut Diagnostic<'_>,
) -> Result<Option<String>, LuaScriptError> {
    match luacode_path.to_str() {
        Some(s) => get_build_lua_contents(s, diagnostic),
        None => Ok(None),
    }
}

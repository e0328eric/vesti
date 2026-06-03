use std::cell::RefCell;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use mlua::{Lua as MLua, MultiValue, Value, Variadic};

use crate::config::Config;
use crate::diagnostic::Diagnostic;
use crate::parser::{LatexEngine, Parser, ParserAllows};
use crate::vesti_info::VESTI_DUMMY_DIR;

/// Compile attributes that `vesti.compile` (in `first.lua`) may set.
#[derive(Debug, Clone, Copy, Default)]
pub struct CompileAttribute {
    pub compile_all: bool,
    pub watch: bool,
    pub no_color: bool,
    pub no_exit_err: bool,
    pub engine_already_changed: bool,
}

/// Mutable state shared between the `Lua` wrapper and every registered
/// callback.
pub struct SharedState {
    /// Accumulates `vesti.print` output, drained by `take_vesti_output`.
    pub buf: String,
    pub engine: LatexEngine,
    pub make_log: bool,
    pub line_limit: usize,
    pub is_first_lua: bool,
    /// Set by `vesti.compile`; the main `.ves` file to compile.
    pub main_ves: Option<String>,
    pub compile_attr: CompileAttribute,
}

/// Errors surfaced by the embedded runtime.
#[derive(Debug)]
pub enum LuaError {
    Eval,
    Init,
}

pub struct Lua {
    lua: MLua,
    shared: Rc<RefCell<SharedState>>,
    http: reqwest::blocking::Client,
}

impl Lua {
    pub fn init(
        engine: LatexEngine,
        config: &Config,
        compile_attr: CompileAttribute,
    ) -> Result<Self, LuaError> {
        let lua = MLua::new();

        let shared = Rc::new(RefCell::new(SharedState {
            buf: String::with_capacity(100),
            engine,
            make_log: config.lua.make_log,
            line_limit: config.lua.line_limit,
            is_first_lua: false,
            main_ves: None,
            compile_attr,
        }));

        // Build the HTTP client exactly once. Reused by every `download`/`ping`.
        let http = reqwest::blocking::Client::builder()
            .build()
            .map_err(|_| LuaError::Init)?;

        let this = Lua { lua, shared, http };
        this.register_vesti_table().map_err(|_| LuaError::Init)?;
        Ok(this)
    }

    pub fn engine(&self) -> LatexEngine {
        self.shared.borrow().engine
    }

    pub fn set_is_first_lua(&self, v: bool) {
        self.shared.borrow_mut().is_first_lua = v;
    }

    pub fn main_ves(&self) -> Option<String> {
        self.shared.borrow().main_ves.clone()
    }

    pub fn compile_attr(&self) -> CompileAttribute {
        self.shared.borrow().compile_attr
    }

    pub fn change_latex_engine(&self, new_engine: LatexEngine) {
        self.shared.borrow_mut().engine = new_engine;
    }

    pub fn clear_vesti_output(&self) {
        self.shared.borrow_mut().buf.clear();
    }

    pub fn take_vesti_output(&self) -> String {
        std::mem::take(&mut self.shared.borrow_mut().buf)
    }

    pub fn eval_code(&self, raw_code: &str) -> Result<(), LuaError> {
        let code = raw_code.trim_matches([' ', '\t', '\n']);
        match self.lua.load(raw_code).exec() {
            Ok(()) => Ok(()),
            Err(err) => {
                self.report_lua_error(code, &err.to_string());
                Err(LuaError::Eval)
            }
        }
    }

    fn report_lua_error(&self, code: &str, err_msg: &str) {
        let (make_log, line_limit) = {
            let s = self.shared.borrow();
            (s.make_log, s.line_limit)
        };

        eprintln!("================== <LUA ERROR> ==================");
        eprintln!("                    <LUACODE>");

        let lines_count = code.matches('\n').count();
        let should_make_log = make_log || lines_count >= line_limit;

        if should_make_log {
            if make_log {
                eprintln!("luacode is stored in {VESTI_DUMMY_DIR}/luacode.lua");
            } else {
                eprintln!(
                    "luacode has so many lines than {line_limit}. See {VESTI_DUMMY_DIR}/luacode.lua"
                );
            }
            // Best-effort: write the offending code into the dummy dir.
            let log_path = Path::new(VESTI_DUMMY_DIR).join("luacode.lua");
            if let Ok(mut f) = fs::File::create(&log_path) {
                let _ = f.write_all(code.as_bytes());
            }
        } else {
            // Print the code with line numbers
            let padding = decimal_width(lines_count.max(1));
            for (i, line) in code.lines().enumerate() {
                let n = i + 1;
                eprintln!("{n:>padding$} | {line}", padding = padding);
            }
        }

        eprintln!("-------------------------------------------------");
        eprintln!("                 <ERROR MESSAGE>");
        eprintln!("{err_msg}");
        eprintln!("=================================================");
    }

    fn register_vesti_table(&self) -> mlua::Result<()> {
        let lua = &self.lua;
        let table = lua.create_table()?;

        // vesti.print(..., { sep = <string>, nl = <number> }?)
        {
            let shared = Rc::clone(&self.shared);
            let f =
                lua.create_function(move |lua, args: MultiValue| lua_print(lua, &shared, args))?;
            table.set("print", f)?;
        }

        // vesti.parse(<ves_string>) -> string
        {
            let shared = Rc::clone(&self.shared);
            let f = lua.create_function(move |_, code: mlua::String| lua_parse(&shared, code))?;
            table.set("parse", f)?;
        }

        // vesti.vestiDummyDir() -> string
        {
            let f = lua.create_function(move |_, ()| Ok(VESTI_DUMMY_DIR.to_owned()))?;
            table.set("vestiDummyDir", f)?;
        }

        // vesti.getCurrentDir() -> string
        {
            let f = lua.create_function(move |_, ()| {
                let cwd = std::env::current_dir()
                    .map_err(|_| mlua::Error::runtime("cannot get the current directory"))?;
                Ok(cwd.to_string_lossy().into_owned())
            })?;
            table.set("getCurrentDir", f)?;
        }

        // vesti.setCurrentDir(<dir_name>)
        {
            let f = lua.create_function(move |_, dir_path: String| {
                std::env::set_current_dir(&dir_path).map_err(|_| {
                    mlua::Error::runtime(format!("failed to change directory into {dir_path}"))
                })?;
                Ok(())
            })?;
            table.set("setCurrentDir", f)?;
        }

        // vesti.getEngineType() -> string
        {
            let shared = Rc::clone(&self.shared);
            let f =
                lua.create_function(move |_, ()| Ok(shared.borrow().engine.to_str().to_owned()))?;
            table.set("getEngineType", f)?;
        }

        // vesti.unzip(<filename>, <dest_dir>) -> bool
        {
            let f = lua.create_function(move |_, (filename, dirpath): (String, String)| {
                lua_unzip(&filename, &dirpath)
            })?;
            table.set("unzip", f)?;
        }

        // vesti.ping(<url>) -> bool
        {
            let http = self.http.clone();
            let f = lua.create_function(move |_, url: String| Ok(lua_ping(&http, &url)))?;
            table.set("ping", f)?;
        }

        // vesti.download(<url>, <filename>)
        {
            let http = self.http.clone();
            let f = lua.create_function(move |_, (url, filename): (String, String)| {
                lua_download(&http, &url, &filename)
            })?;
            table.set("download", f)?;
        }

        // vesti.getModule(<mod_name>)
        {
            let f = lua.create_function(move |_, mod_name: String| {
                let mut diagnostic = Diagnostic::new();
                crate::ves_module::download_module(&mut diagnostic, &mod_name, None).map_err(
                    |_| mlua::Error::runtime(format!("cannot get a vesti module {mod_name}")),
                )?;
                Ok(())
            })?;
            table.set("getModule", f)?;
        }

        // vesti.mkdir(<dir_name>)
        {
            let f =
                lua.create_function(move |_, dir_name: String| match fs::create_dir(&dir_name) {
                    Ok(()) => Ok(()),
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
                    Err(_) => Err(mlua::Error::runtime(format!(
                        "failed to make a directory {dir_name}"
                    ))),
                })?;
            table.set("mkdir", f)?;
        }

        // vesti.joinpath(...) -> string
        {
            let f = lua.create_function(move |_, parts: Variadic<String>| {
                if parts.is_empty() {
                    return Err(mlua::Error::runtime(
                        "invalid argument\nUsage: vesti.joinpath(...) -> string",
                    ));
                }
                let mut path = PathBuf::new();
                for p in parts.iter() {
                    path.push(p);
                }
                Ok(path.to_string_lossy().into_owned())
            })?;
            table.set("joinpath", f)?;
        }

        // vesti.compile(<main_ves>, { <configurations> }?)
        {
            let shared = Rc::clone(&self.shared);
            let f =
                lua.create_function(move |lua, args: MultiValue| lua_compile(lua, &shared, args))?;
            table.set("compile", f)?;
        }

        lua.globals().set("vesti", table)?;
        Ok(())
    }
}

fn decimal_width(mut n: usize) -> usize {
    let mut w = 1;
    while n >= 10 {
        n /= 10;
        w += 1;
    }
    w
}

fn lua_print(lua: &MLua, shared: &Rc<RefCell<SharedState>>, args: MultiValue) -> mlua::Result<()> {
    let mut values: Vec<Value> = args.into_iter().collect();
    if values.is_empty() {
        return Err(mlua::Error::runtime(
            "invalid argument\nUsage: vesti.print(..., { sep = <string>, nl = <number >= 0>}?)\nDefault: sep = \" \", nl = 1",
        ));
    }

    // Defaults.
    let mut sep = " ".to_owned();
    let mut nl: usize = 1;

    // If the last argument is a table, treat it as options.
    if let Some(Value::Table(opts)) = values.last() {
        let opts = opts.clone();
        match opts.get::<Value>("sep")? {
            Value::Nil => {}
            Value::String(s) => sep = s.to_str()?.to_string(),
            _ => return Err(mlua::Error::runtime("`sep` should be a string")),
        }
        match opts.get::<Value>("nl")? {
            Value::Nil => {}
            Value::Integer(n) => nl = (n.max(0) as usize).min(2),
            Value::Number(n) => nl = (n.max(0.0) as usize).min(2),
            _ => return Err(mlua::Error::runtime("`nl` should be a nonnegative number")),
        }
        values.pop();
    }

    let mut state = shared.borrow_mut();
    for (i, v) in values.iter().enumerate() {
        if i > 0 {
            state.buf.push_str(&sep);
        }
        // Coerce to string the same way Lua's tostring would.
        let s = lua_value_to_string(lua, v)?;
        state.buf.push_str(&s);
    }
    for _ in 0..nl {
        state.buf.push('\n');
    }
    Ok(())
}

fn lua_value_to_string(lua: &MLua, v: &Value) -> mlua::Result<String> {
    match v {
        Value::String(s) => Ok(s.to_str()?.to_string()),
        Value::Integer(n) => Ok(n.to_string()),
        Value::Number(n) => Ok(n.to_string()),
        Value::Boolean(b) => Ok(b.to_string()),
        Value::Nil => Ok("nil".to_owned()),
        other => {
            // Fall back to Lua's tostring for tables/userdata/etc.
            let coerced = lua.coerce_string(other.clone())?;
            match coerced {
                Some(s) => Ok(s.to_str()?.to_string()),
                None => Err(mlua::Error::runtime(
                    "given value is not convertible into string",
                )),
            }
        }
    }
}

fn lua_parse(shared: &Rc<RefCell<SharedState>>, code: mlua::String) -> mlua::Result<String> {
    let vesti_code = code.to_str()?.to_string();
    let engine = shared.borrow().engine;

    let mut diagnostic = Diagnostic::new();
    let mut parser = Parser::new(
        &vesti_code,
        &mut diagnostic,
        ParserAllows {
            luacode: false,
            global_def: false,
            is_main: false,
            change_engine: true,
        },
        // disallow changing engine type (slot = None), default to current.
        (None, engine),
    )
    .map_err(|err| mlua::Error::runtime(format!("parser init failed because of {err:?}")))?;

    let stmts = parser
        .parse()
        .map_err(|err| mlua::Error::runtime(format!("parse failed. error: {err:?}")))?;

    let mut out = String::with_capacity(256);
    {
        let mut codegen = crate::codegen::Codegen::new(&stmts, false, &mut diagnostic);
        codegen.codegen(None, None, &mut out).map_err(|err| {
            if let Some(text) = diagnostic.render(true) {
                eprint!("{text}");
            }
            mlua::Error::runtime(format!("codegen failed because of {err:?}"))
        })?;
    }

    Ok(out)
}

fn lua_unzip(filename: &str, dirpath: &str) -> mlua::Result<bool> {
    let file = fs::File::open(filename)
        .map_err(|_| mlua::Error::runtime(format!("cannot open a file `{filename}`")))?;

    let dest = Path::new(dirpath);
    if !dest.is_dir() {
        return Err(mlua::Error::runtime(format!(
            "cannot open a directory `{dirpath}`.\nNotice that this function does not make a directory"
        )));
    }

    let mut archive = zip::ZipArchive::new(file)
        .map_err(|_| mlua::Error::runtime(format!("failed to extract `{filename}`")))?;
    archive
        .extract(dest)
        .map_err(|_| mlua::Error::runtime(format!("failed to extract `{filename}`")))?;

    Ok(true)
}

fn lua_ping(http: &reqwest::blocking::Client, url: &str) -> bool {
    http.get(url).send().is_ok()
}

fn lua_download(http: &reqwest::blocking::Client, url: &str, filename: &str) -> mlua::Result<()> {
    let mut resp = http
        .get(url)
        .send()
        .map_err(|_| mlua::Error::runtime(format!("failed to obtain a response from {url}")))?
        // Don't silently write a 404/500 error page into the file
        .error_for_status()
        .map_err(|e| mlua::Error::runtime(format!("request to {url} failed: {e}")))?;

    let mut file = fs::File::create(filename)
        .map_err(|_| mlua::Error::runtime(format!("cannot create a file `{filename}`")))?;

    let mut buf = [0u8; 4096];
    loop {
        let n = resp.read(&mut buf).map_err(|e| {
            mlua::Error::runtime(format!("error occurs while reading from {url}: {e}"))
        })?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n]).map_err(|e| {
            mlua::Error::runtime(format!("error occurs while writing into {filename}: {e}"))
        })?;
    }
    file.flush()
        .map_err(|_| mlua::Error::runtime(format!("failed to write into {filename}")))?;
    Ok(())
}

fn lua_compile(
    _lua: &MLua,
    shared: &Rc<RefCell<SharedState>>,
    args: MultiValue,
) -> mlua::Result<()> {
    {
        if !shared.borrow().is_first_lua {
            return Err(mlua::Error::runtime(
                "cannot use `vesti.compile` outside of `first.lua`",
            ));
        }
    }

    let values: Vec<Value> = args.into_iter().collect();
    if values.is_empty() || values.len() > 2 {
        return Err(mlua::Error::runtime(
            "invalid argument\nUsage: vesti.compile(<main_ves: string>, { <configurations> }?)",
        ));
    }

    let main_ves = match &values[0] {
        Value::String(s) => s.to_str()?.to_string(),
        _ => {
            return Err(mlua::Error::runtime(
                "first argument should be a `string`\nUsage: vesti.compile(<main_ves: string>, { <configurations> }?)",
            ));
        }
    };
    shared.borrow_mut().main_ves = Some(main_ves);

    if let Some(Value::Table(opts)) = values.get(1) {
        // boolean attributes
        macro_rules! bool_attr {
            ($field:ident, $key:literal) => {{
                match opts.get::<Value>($key)? {
                    Value::Nil => {}
                    Value::Boolean(b) => shared.borrow_mut().compile_attr.$field = b,
                    _ => {
                        return Err(mlua::Error::runtime(concat!(
                            "`",
                            $key,
                            "` should be a boolean"
                        )));
                    }
                }
            }};
        }
        bool_attr!(compile_all, "compile_all");
        bool_attr!(watch, "watch");
        bool_attr!(no_color, "no_color");
        bool_attr!(no_exit_err, "no_exit_err");

        // engine string
        match opts.get::<Value>("engine")? {
            Value::Nil => {}
            Value::String(s) => {
                let engine_str = s.to_str()?;
                let engine = match &*engine_str {
                    "latex" => LatexEngine::Latex,
                    "pdf" => LatexEngine::PdfLatex,
                    "xe" => LatexEngine::XeLatex,
                    "lua" => LatexEngine::LuaLatex,
                    #[cfg(feature = "tectonic-backend")]
                    "tect" => LatexEngine::Tectonic,
                    _ => {
                        #[cfg(feature = "tectonic-backend")]
                        return Err(mlua::Error::runtime(
                            "invalid `engine`. Must either `latex`, `pdf`, `xe`, `lua`, or `tect`",
                        ));
                        #[cfg(not(feature = "tectonic-backend"))]
                        return Err(mlua::Error::runtime(
                            "invalid `engine`. Must either `latex`, `pdf`, `xe`, or `lua`",
                        ));
                    }
                };
                let mut state = shared.borrow_mut();
                state.engine = engine;
                state.compile_attr.engine_already_changed = true;
            }
            _ => return Err(mlua::Error::runtime("`engine` should be a string")),
        }
    }

    Ok(())
}

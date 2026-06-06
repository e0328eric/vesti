use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::SystemTime;

use walkdir::WalkDir;

#[cfg(target_os = "windows")]
use windows::{Win32::UI::WindowsAndMessaging as win, core::s};

use crate::diagnostic::{Diagnostic, DiagnosticInner, IoDiagnostic};
use crate::lua::{CompileAttribute, Lua};
use crate::luascript::{self, LuaScriptError};
use crate::parser::{LatexEngine, Parser, ParserAllows, ast::Stmt};
use crate::vesti_info::{VESTI_DUMMY_DIR, VESTI_VERSION};

pub static SHUTDOWN: AtomicBool = AtomicBool::new(false);

#[derive(Debug)]
pub enum CompileError {
    ExtensionDifferent,
    FailedToOpenFile,
    CompileVesFailed,
    CompileLatexFailed,
    ParseFailed,
    Io(io::Error),
    LuaScript(LuaScriptError),
}

impl From<io::Error> for CompileError {
    fn from(e: io::Error) -> Self {
        CompileError::Io(e)
    }
}

impl From<LuaScriptError> for CompileError {
    fn from(e: LuaScriptError) -> Self {
        CompileError::LuaScript(e)
    }
}

/// Paths to the build Lua scripts
#[derive(Clone)]
pub struct LuaScripts {
    pub before: String,
    pub step: String,
}

/// Loaded contents of the build Lua scripts
#[derive(Default)]
pub struct LuaContents {
    pub before: Option<String>,
    pub step: Option<String>,
}

impl LuaContents {
    pub fn init(
        diagnostic: &mut Diagnostic<'_>,
        scripts: &LuaScripts,
    ) -> Result<Self, LuaScriptError> {
        Ok(LuaContents {
            before: luascript::get_build_lua_contents(&scripts.before, diagnostic)?,
            step: luascript::get_build_lua_contents(&scripts.step, diagnostic)?,
        })
    }
}

/// A single vesti file's owned source plus whether it is a "main" file.
struct VestiSource {
    /// Absolute path of the file.
    filename: String,
    /// Owned source text — borrowed by the parser/AST/codegen.
    source: String,
    is_main: bool,
}

/// A parsed file: its AST borrows the arena (`src.source`), so this never
/// outlives the `Vec<VestiSource>` it points into.
struct ParsedFile<'s> {
    src: &'s VestiSource,
    ast: Vec<Stmt<'s>>,
}

pub struct Compiler {
    pub main_filename: String,
    pub engine: LatexEngine,
    pub compile_limit: usize,
    pub luacode_scripts: LuaScripts,
    pub luacode_contents: LuaContents,
    pub attr: CompileAttribute,
}

impl Compiler {
    pub fn compile(&mut self, lua: &mut Lua) -> Result<(), CompileError> {
        if let Some(lc) = self.luacode_contents.before.clone() {
            // A short-lived diagnostic is fine here: `before.lua` has no source
            // spans to borrow.
            let mut diagnostic = Diagnostic::new();
            luascript::run_lua_code(lua, &mut diagnostic, &lc, &self.luacode_scripts.before)
                .map_err(|e| {
                    diagnostic.pretty_print(self.attr.no_color);
                    CompileError::LuaScript(e)
                })?;
        }

        'watch: loop {
            let snapshot = self.attr.watch.then_some(self.watch_snapshot());

            match self.compile_inner(lua) {
                Ok(()) => {}
                Err(err) => {
                    if SHUTDOWN.load(Ordering::SeqCst) {
                        return Ok(());
                    }

                    raise_messagebox(
                        "vesti compile failed",
                        "vesti compilation error occurs. See the console for more information",
                    );

                    match err {
                        CompileError::FailedToOpenFile | CompileError::Io(_) => return Err(err),
                        _ => {}
                    }

                    if !self.attr.watch || !self.attr.no_exit_err {
                        return Err(err);
                    }
                }
            }

            let Some(snapshot) = snapshot else {
                break;
            };

            eprintln!("Ctrl+C to quit...");
            loop {
                if SHUTDOWN.load(Ordering::SeqCst) {
                    break 'watch;
                }
                if self.watch_snapshot() != snapshot {
                    break;
                }

                std::thread::sleep(std::time::Duration::from_millis(200));
            }
        }

        Ok(())
    }

    fn collect_watch_files(&self) -> Vec<PathBuf> {
        let mut files: Vec<PathBuf> = vec![PathBuf::from(&self.main_filename)];

        if self.attr.compile_all {
            let dummy_name = Path::new(VESTI_DUMMY_DIR).file_name();
            for entry in WalkDir::new(".").into_iter().filter_map(Result::ok) {
                if !entry.file_type().is_file() {
                    continue;
                }

                let path = entry.path();
                if dummy_name.is_some()
                    && path.components().any(|c| Some(c.as_os_str()) == dummy_name)
                {
                    continue;
                }
                if path.extension().and_then(|e| e.to_str()) == Some("ves") {
                    files.push(path.to_path_buf());
                }
            }
        }

        files
    }

    fn watch_snapshot(&self) -> BTreeMap<PathBuf, Option<SystemTime>> {
        self.collect_watch_files()
            .into_iter()
            .map(|path| {
                let mtime = fs::metadata(&path).and_then(|m| m.modified()).ok();
                (path, mtime)
            })
            .collect()
    }

    fn compile_inner(&mut self, lua: &mut Lua) -> Result<(), CompileError> {
        // make vesti-dummy directory
        match fs::create_dir(VESTI_DUMMY_DIR) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(CompileError::Io(e)),
        }
        // add .gitignore in the dummy dir
        fs::write(Path::new(VESTI_DUMMY_DIR).join(".gitignore"), "*\n")?;

        // the main file must have a `.ves` extension
        if Path::new(&self.main_filename)
            .extension()
            .and_then(|e| e.to_str())
            != Some("ves")
        {
            eprintln!("error: extension of `{}` is not `ves`", self.main_filename);
            return Err(CompileError::ExtensionDifferent);
        }

        // resolve the main file's absolute path
        let main_abs = match fs::canonicalize(&self.main_filename) {
            Ok(p) => p.to_string_lossy().into_owned(),
            Err(_) => {
                eprintln!("error: failed to open file `{}`", self.main_filename);
                return Err(CompileError::FailedToOpenFile);
            }
        };

        // gather the set of files to compile
        let mut main_files: BTreeMap<String, bool> = BTreeMap::new();
        main_files.insert(main_abs.clone(), true);

        let mut vesti_files: BTreeMap<String, bool> = main_files.clone();
        if self.attr.compile_all {
            update_ves_files(&main_files, &mut vesti_files)?;
        }

        let mut sources: Vec<VestiSource> = Vec::with_capacity(vesti_files.len());
        for (filename, &is_main) in &vesti_files {
            let source = match fs::read_to_string(filename) {
                Ok(s) => s,
                Err(_) => {
                    eprintln!("error: failed to read from {filename}");
                    return Err(CompileError::CompileVesFailed);
                }
            };
            sources.push(VestiSource {
                filename: filename.clone(),
                source,
                is_main,
            });
        }

        // A diagnostic scoped to the source arena: the parser/codegen borrow
        // both `&source` and `&mut diagnostic`, so they must share this scope.
        // The compiler prints it itself on failure.
        let mut diagnostic: Diagnostic<'_> = Diagnostic::new();

        let mut parsed: Vec<ParsedFile<'_>> = Vec::with_capacity(sources.len());
        for vs in &sources {
            match self.parse_vesti(vs, &mut diagnostic) {
                Ok((stmts, engine)) => {
                    self.engine = engine;
                    parsed.push(ParsedFile {
                        src: vs,
                        ast: stmts,
                    });
                }
                Err(e) => {
                    diagnostic.lock_print_at_main = true;
                    diagnostic.pretty_print(self.attr.no_color);
                    return Err(e);
                }
            }
        }

        for pf in &parsed {
            if let Err(e) = self.codegen_to_latex(pf, lua, &mut diagnostic) {
                diagnostic.lock_print_at_main = true;
                diagnostic.pretty_print(self.attr.no_color);
                return Err(e);
            }
        }
        // ASTs/sources are no longer needed for parse/codegen past this point.
        drop(parsed);

        for (filename, _) in main_files.iter().filter(|&(_, m)| *m) {
            if let Err(e) = self.compile_latex(filename, lua, &mut diagnostic) {
                diagnostic.lock_print_at_main = true;
                diagnostic.pretty_print(self.attr.no_color);
                return Err(e);
            }
        }

        Ok(())
    }

    /// Parse a single file: returns its AST (borrowing
    /// the arena) and the engine after any `compty` changes.
    fn parse_vesti<'s>(
        &mut self,
        vs: &'s VestiSource,
        diagnostic: &mut Diagnostic<'s>,
    ) -> Result<(Vec<Stmt<'s>>, LatexEngine), CompileError> {
        let change_engine = !self.attr.engine_already_changed;

        // The parser holds `&mut Diagnostic` for its lifetime, so it must be
        // fully dropped before we touch `diagnostic` again on the error path.
        let parse_result: Result<(Vec<Stmt<'s>>, LatexEngine), ()> = match Parser::new(
            &vs.source,
            diagnostic,
            ParserAllows {
                luacode: true,
                global_def: true,
                is_main: vs.is_main,
                change_engine,
            },
            (Some(self.engine), self.engine),
        ) {
            // parser creation failed; its borrow of `diagnostic` is already
            // released (no `Parser` value exists).
            Err(_) => Err(()),
            Ok(mut parser) => match parser.parse() {
                Ok(stmts) => Ok((stmts, parser.current_engine())),
                Err(_) => Err(()),
            },
        };

        match parse_result {
            Ok(v) => Ok(v),
            Err(()) => {
                diagnostic.init_metadata(
                    Some(std::borrow::Cow::Owned(vs.filename.clone())),
                    Some(std::borrow::Cow::Owned(vs.source.clone())),
                );
                Err(CompileError::ParseFailed)
            }
        }
    }

    /// Codegen one already-parsed file and write the `.tex`
    fn codegen_to_latex<'s>(
        &mut self,
        pf: &ParsedFile<'s>,
        lua: &mut Lua,
        diagnostic: &mut Diagnostic<'s>,
    ) -> Result<(), CompileError> {
        let vs = pf.src;

        // change engine type via `compty`: keep the Lua runtime's engine in sync
        lua.change_latex_engine(self.engine);

        // Codegen.
        let mut tex_content = String::with_capacity(256);
        {
            let mut codegen = crate::codegen::Codegen::new(&pf.ast, vs.is_main, diagnostic);
            // `placeholder` is always `None`: global_defkinds is unused upstream.
            if codegen.codegen(Some(lua), None, &mut tex_content).is_err() {
                // codegen's borrow of `diagnostic` ends here (codegen dropped).
                drop(codegen);
                diagnostic.init_metadata(
                    Some(std::borrow::Cow::Owned(vs.filename.clone())),
                    Some(std::borrow::Cow::Owned(vs.source.clone())),
                );
                return Err(CompileError::CompileLatexFailed);
            }
        }

        // Write the generated `.tex` with the prologue.
        let output_filename = get_tex_filename(&vs.filename, vs.is_main)?;
        let output_path = Path::new(VESTI_DUMMY_DIR).join(&output_filename);

        let prologue = format!(
            "%\n%    this file was generated by vesti {VESTI_VERSION}\n%    compile this file using {} engine\n%    =========================================\n%    vesti: https://github.com/e0328eric/vesti\n%\n",
            self.engine.to_str()
        );

        let mut full = String::with_capacity(prologue.len() + tex_content.len());
        full.push_str(&prologue);
        full.push_str(&tex_content);
        fs::write(&output_path, full)?;

        Ok(())
    }

    fn compile_latex(
        &mut self,
        filename: &str,
        lua: &mut Lua,
        diagnostic: &mut Diagnostic<'_>,
    ) -> Result<(), CompileError> {
        self.compile_latex_helper(filename, lua, diagnostic)?;

        // copy <dummy>/<name>.pdf -> ./<name>.pdf
        let main_pdf_file = change_extension(filename, "pdf")?;
        let from = Path::new(VESTI_DUMMY_DIR).join(&main_pdf_file);
        fs::copy(&from, &main_pdf_file)?;

        Ok(())
    }

    #[cfg(not(feature = "tectonic-backend"))]
    fn compile_latex_helper(
        &mut self,
        filename: &str,
        lua: &mut Lua,
        diagnostic: &mut Diagnostic<'_>,
    ) -> Result<(), CompileError> {
        let main_tex_file = get_tex_filename(filename, true)?;

        for i in 0..self.compile_limit {
            eprintln!(
                "[compile number {}, engine: {}]",
                i + 1,
                self.engine.to_str()
            );
            self.compile_latex_with_external(&main_tex_file, diagnostic)?;
            if let Some(lc) = self.luacode_contents.step.clone() {
                luascript::run_lua_code(lua, diagnostic, &lc, &self.luacode_scripts.step)?;
            }
            eprintln!("[compiled]");
        }

        Ok(())
    }

    #[cfg(feature = "tectonic-backend")]
    fn compile_latex_helper(
        &mut self,
        filename: &str,
        lua: &mut Lua,
        diagnostic: &mut Diagnostic<'_>,
    ) -> Result<(), CompileError> {
        let main_tex_file = get_tex_filename(filename, true)?;

        if self.engine == LatexEngine::Tectonic {
            // change current directory into VESTI_DUMMY_DIR in order to compile
            // LaTeX through tectonic
            let dir_changer = CurrentDirChanger {
                current: std::env::current_dir()?,
                into: Path::new(VESTI_DUMMY_DIR),
            };
            dir_changer.change_dir()?;

            self.compile_latex_with_tectonic(&main_tex_file, diagnostic)?;
            if let Some(lc) = self.luacode_contents.before.clone() {
                luascript::run_lua_code(lua, diagnostic, &lc, &self.luacode_scripts.before)?;
            }
        } else {
            for i in 0..self.compile_limit {
                eprintln!(
                    "[compile number {}, engine: {}]",
                    i + 1,
                    self.engine.to_str()
                );
                self.compile_latex_with_external(&main_tex_file, diagnostic)?;
                if let Some(lc) = self.luacode_contents.step.clone() {
                    luascript::run_lua_code(lua, diagnostic, &lc, &self.luacode_scripts.step)?;
                }
                eprintln!("[compiled]");
            }
        }

        Ok(())
    }

    /// External-engine compilation (latex/pdflatex/xelatex/lualatex), run as a
    /// subprocess inside the dummy dir.
    fn compile_latex_with_external(
        &self,
        main_tex_file: &str,
        diagnostic: &mut Diagnostic<'_>,
    ) -> Result<(), CompileError> {
        let output = std::process::Command::new(self.engine.to_str())
            .arg("-halt-on-error")
            .arg(main_tex_file)
            .current_dir(VESTI_DUMMY_DIR)
            .output()?;

        // stash stdout/stderr in the dummy dir
        let _ = fs::write(
            Path::new(VESTI_DUMMY_DIR).join("stdout.txt"),
            &output.stdout,
        );
        let _ = fs::write(
            Path::new(VESTI_DUMMY_DIR).join("stderr.txt"),
            &output.stderr,
        );

        if !output.status.success() {
            let io_diag = IoDiagnostic::with_note(
                None,
                format!("{} gaves an error while processing", self.engine.to_str()),
                format!(
                    "<Latex Engine Log>\n{}",
                    String::from_utf8_lossy(&output.stdout)
                ),
            );
            diagnostic.init_diag_inner(DiagnosticInner::IoError(io_diag));
            return Err(CompileError::CompileLatexFailed);
        }

        Ok(())
    }

    #[cfg(feature = "tectonic-backend")]
    fn compile_latex_with_tectonic(
        &self,
        main_tex_file: &str,
        diagnostic: &mut Diagnostic<'_>,
    ) -> Result<(), CompileError> {
        if vesti_tectonic::compile_latex_with_tectonic(
            main_tex_file,
            VESTI_DUMMY_DIR,
            self.compile_limit,
        ) {
            Ok(())
        } else {
            let io_diag = IoDiagnostic::with_note(
                None,
                "tectonic gaves an error while processing".to_owned(),
                String::new(),
            );
            diagnostic.init_diag_inner(DiagnosticInner::IoError(io_diag));
            Err(CompileError::CompileLatexFailed)
        }
    }

    fn engine_already_changed(&self) -> bool {
        self.attr.engine_already_changed
    }
}

fn update_ves_files(
    main_files: &BTreeMap<String, bool>,
    vesti_files: &mut BTreeMap<String, bool>,
) -> Result<(), CompileError> {
    for entry in WalkDir::new(".").into_iter().filter_map(Result::ok) {
        if !entry.file_type().is_file() {
            continue;
        }
        if entry.path().extension().and_then(|e| e.to_str()) != Some("ves") {
            continue;
        }
        let real = match fs::canonicalize(entry.path()) {
            Ok(p) => p.to_string_lossy().into_owned(),
            Err(_) => continue,
        };
        #[allow(clippy::map_entry)]
        if !vesti_files.contains_key(&real) {
            let is_main = main_files.contains_key(&real);
            vesti_files.insert(real, is_main);
        }
    }
    Ok(())
}

fn get_tex_filename(filename: &str, is_main: bool) -> Result<String, CompileError> {
    if is_main {
        change_extension(filename, "tex")
    } else {
        Ok(crate::parser::vesti_name_mangle(filename))
    }
}

fn change_extension(filename: &str, into: &str) -> Result<String, CompileError> {
    let base = Path::new(filename)
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| CompileError::Io(io::Error::other("invalid filename")))?;
    match base.rfind('.') {
        Some(idx) => Ok(format!("{}.{}", &base[..idx], into)),
        None => Err(CompileError::Io(io::Error::other("invalid filename"))),
    }
}

fn raise_messagebox(_title: &str, contents: &str) {
    #[cfg(target_os = "linux")]
    {
        // best-effort: zenity may not be installed
        let _ = std::process::Command::new("zenity")
            .arg("--error")
            .arg(format!("--text={contents}"))
            .arg(format!("--title={_title}"))
            .output();
    }
    #[cfg(target_os = "windows")]
    {
        unsafe {
            win::MessageBoxA(
                None,
                s!("vesti compilation failed. See the console for more information."),
                s!("vesti watch warning"),
                win::MB_ICONWARNING | win::MB_OK,
            )
        };
        eprintln!("VESTI ERROR: {}", contents);
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        eprintln!("VESTI ERROR: {}", contents);
    }
}

// helper struct for changing current directory
struct CurrentDirChanger<'p> {
    current: PathBuf,
    into: &'p Path,
}

impl CurrentDirChanger<'_> {
    fn change_dir(&self) -> io::Result<()> {
        std::env::set_current_dir(self.into)
    }
}

impl Drop for CurrentDirChanger<'_> {
    fn drop(&mut self) {
        if std::env::set_current_dir(&self.current).is_err() {
            panic!("failed to recover cmd");
        }
    }
}

#[cfg(feature = "tectonic-backend")]
mod vesti_tectonic {
    use super::*;
    use std::io::IsTerminal;
    use std::time::SystemTime;

    use tectonic::{
        config, driver,
        status::{self, StatusBackend},
    };

    /// Safe equivalent of the FFI `compile_latex_with_tectonic`. Compiles
    /// `latex_filename` (relative to `vesti_local_dummy_dir`) to PDF using tectonic,
    /// rerunning up to `compile_limit` times. Returns `true` on success.
    pub fn compile_latex_with_tectonic(
        latex_filename: &str,
        vesti_local_dummy_dir: &str,
        compile_limit: usize,
    ) -> bool {
        macro_rules! unwrap {
            ($val:expr) => {
                match $val {
                    Ok(val) => val,
                    Err(err) => {
                        eprintln!("TECTONIC ERROR: {err}");
                        return false;
                    }
                }
            };
        }

        println!("[Compile {latex_filename}, engine: tectonic]");

        let mut status: Box<dyn StatusBackend> = if io::stdout().is_terminal() {
            Box::new(status::termcolor::TermcolorStatusBackend::new(
                status::ChatterLevel::Normal,
            ))
        } else {
            Box::<status::NoopStatusBackend>::default()
        };

        let config = unwrap!(config::PersistentConfig::open(true));
        let bundle = unwrap!(config.default_bundle(false));
        let format_cache_path = unwrap!(config.format_cache_path());

        let mut sb = driver::ProcessingSessionBuilder::default();
        sb.bundle(bundle)
            .primary_input_path(latex_filename)
            .filesystem_root(vesti_local_dummy_dir)
            .tex_input_name(latex_filename)
            .format_name("latex")
            .format_cache_path(format_cache_path)
            .keep_logs(true)
            .keep_intermediates(true)
            .print_stdout(false)
            .build_date(SystemTime::now())
            .output_format(driver::OutputFormat::Pdf);

        if compile_limit > 0 {
            sb.reruns(compile_limit);
        }

        let mut sess = unwrap!(sb.create(&mut *status));

        if let Err(err) = sess.run(&mut *status) {
            eprintln!("TECTONIC ERROR: {err}\nSee logs in {vesti_local_dummy_dir}\n");
            return false;
        }

        println!("[Compile {latex_filename} Done]");
        true
    }
}

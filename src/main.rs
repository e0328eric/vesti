#![allow(dead_code)]

mod codegen;
mod compiler;
mod config;
mod diagnostic;
mod lexer;
mod location;
mod lua;
mod luascript;
mod parser;
mod ves_module;
mod vesti_info;

use std::fs;
use std::path::Path;
use std::process::ExitCode;
use std::sync::atomic::Ordering;

use clap::{Parser as ClapParser, Subcommand};

use crate::compiler::{Compiler, LuaContents, LuaScripts};
use crate::config::Config;
use crate::diagnostic::Diagnostic;
use crate::lua::{CompileAttribute, Lua};
use crate::parser::LatexEngine;
use crate::vesti_info::VESTI_DUMMY_DIR;

/// A LaTeX transpiler.
#[derive(ClapParser)]
#[command(name = "vesti", version, about = "A latex transpiler")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Compile vesti into a LaTeX file
    Compile(CompileArgs),
    /// Remove the .vesti-dummy directory
    Clear,
    /// Initialize a vesti project
    Init {
        /// project name
        project: String,
    },
}

#[derive(clap::Args)]
struct CompileArgs {
    /// filename to compile
    filename: Option<String>,

    /// compile vesti into a tex file only (currently a no-op)
    #[arg(short = 'e', long = "emit-tex")]
    emit_tex: bool,

    /// on watch mode, exit immediately when an error occurs
    #[arg(short = 'E', long = "exit-err")]
    exit_err: bool,

    /// no color output on a terminal
    #[arg(short = 'N', long = "no-color")]
    no_color: bool,

    /// compile vesti without assuming `first.lua` exists
    #[arg(short = 'S', long = "standalone")]
    standalone: bool,

    /// watch vesti files and recompile when modified
    #[arg(short = 'W', long = "watch")]
    watch: bool,

    /// compile using latex (overridable via the `#engine_type` builtin)
    #[arg(short = 'L', long = "latex")]
    latex: bool,
    /// compile using pdflatex
    #[arg(short = 'p', long = "pdflatex")]
    pdflatex: bool,
    /// compile using xelatex
    #[arg(short = 'x', long = "xelatex")]
    xelatex: bool,
    /// compile using lualatex
    #[arg(short = 'l', long = "lualatex")]
    lualatex: bool,
    #[cfg(feature = "tectonic-backend")]
    /// compile using tectonic
    #[arg(short = 'T', long = "tectonic")]
    tectonic: bool,

    /// number of the compile cycles
    #[arg(long = "lim", default_value_t = 3)]
    lim: usize,

    /// run lua code once
    #[arg(long = "first-script", default_value = "first.lua")]
    first_script: String,
    /// run lua code once for each vesti run
    #[arg(long = "before-script", default_value = "before.lua")]
    before_script: String,
    /// custom lua code to execute at the end of each vesti step
    #[arg(long = "step-script", default_value = "step.lua")]
    step_script: String,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    if let Err(e) = ctrlc::set_handler(|| {
        crate::compiler::SHUTDOWN.store(true, Ordering::SeqCst);
    }) {
        eprintln!("CRITICAL ERROR: failed to set the Ctrl+C handler: {e}");
        return ExitCode::FAILURE;
    }

    let result = match cli.command {
        Command::Init { project } => init_step(&project),
        Command::Clear => clear_step(),
        Command::Compile(args) => compile_step(args),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(msg) => {
            if !msg.is_empty() {
                eprintln!("{msg}");
            }
            ExitCode::FAILURE
        }
    }
}

fn init_step(project_name: &str) -> Result<(), String> {
    let first_lua = format!(
        "-- below code imports vesti module\n-- vesti.getModule(\"module_name\")\nvesti.compile(\"{project_name}.ves\", {{ engine = \"tect\", compile_all = true }})\n"
    );
    fs::write("first.lua", first_lua).map_err(|e| format!("error: cannot write first.lua: {e}"))?;

    let project_ves = "docclass article\nstartdoc\nHello, World!\n";
    fs::write(format!("{project_name}.ves"), project_ves)
        .map_err(|e| format!("error: cannot write {project_name}.ves: {e}"))?;

    Ok(())
}

fn clear_step() -> Result<(), String> {
    match fs::remove_dir_all(VESTI_DUMMY_DIR) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(format!("error: failed to remove {VESTI_DUMMY_DIR}: {e}")),
    }
    println!("[successively remove {VESTI_DUMMY_DIR}]");
    Ok(())
}

fn compile_step(args: CompileArgs) -> Result<(), String> {
    let mut diagnostic = Diagnostic::new();

    let config = Config::init(&mut diagnostic).map_err(|_| {
        diagnostic.pretty_print(args.no_color);
        String::new()
    })?;

    let mut engine = get_engine(
        config.engine,
        EngineFlags {
            latex: args.latex,
            pdflatex: args.pdflatex,
            xelatex: args.xelatex,
            lualatex: args.lualatex,
            #[cfg(feature = "tectonic-backend")]
            tectonic: args.tectonic,
        },
    )?;

    // initialize Lua globally
    let mut lua = Lua::init(
        engine,
        &config,
        CompileAttribute {
            compile_all: true,
            watch: args.watch,
            no_color: args.no_color,
            no_exit_err: !args.exit_err,
            engine_already_changed: false,
        },
    )
    .map_err(|_| "error: failed to initialize the Lua runtime".to_owned())?;

    let filename_given = args.filename.as_deref().unwrap_or("").to_owned();

    // -S ignores first.lua and sets compile_all = false
    if !args.standalone {
        // search first.lua upward when no filename was supplied
        if filename_given.is_empty() && !find_and_chdir_to_first_lua()? {
            return Err("error: `first.lua` is not found.".to_owned());
        }

        let first_lua = luascript::get_build_lua_contents(&args.first_script, &mut diagnostic)
            .map_err(|_| {
                diagnostic.pretty_print(args.no_color);
                String::new()
            })?
            .ok_or_else(|| "error: `first.lua` is not found.".to_owned())?;

        // run first.lua
        lua.set_is_first_lua(true);
        luascript::run_lua_code(&mut lua, &mut diagnostic, &first_lua, &args.first_script)
            .map_err(|_| {
                diagnostic.pretty_print(args.no_color);
                String::new()
            })?;
        lua.set_is_first_lua(false);

        // first.lua may have changed the engine
        engine = lua.engine();
    }

    // determine the main vesti file
    let main_ves = if !filename_given.is_empty() {
        filename_given
    } else {
        lua.main_ves()
            .ok_or_else(|| "error: vesti.compile is missing in first.lua".to_owned())?
    };

    let luacode_scripts = LuaScripts {
        before: args.before_script.clone(),
        step: args.step_script.clone(),
    };
    let luacode_contents = LuaContents::init(&mut diagnostic, &luacode_scripts).map_err(|_| {
        diagnostic.pretty_print(args.no_color);
        String::new()
    })?;

    // assemble attributes, honoring -S (standalone)
    let mut attr = lua.compile_attr();
    if args.standalone {
        attr.compile_all = false;
    }

    let mut compiler = Compiler {
        main_filename: main_ves,
        engine,
        compile_limit: args.lim,
        luacode_scripts,
        luacode_contents,
        attr,
    };

    compiler
        .compile(&mut lua)
        .map_err(|e| format!("error: compilation failed ({e:?})"))?;

    Ok(())
}

fn find_and_chdir_to_first_lua() -> Result<bool, String> {
    let cwd = std::env::current_dir()
        .map_err(|_| "error: cannot get the current directory".to_owned())?;

    let mut dir: Option<&Path> = Some(cwd.as_path());
    while let Some(d) = dir {
        let candidate = d.join("first.lua");
        if candidate.is_file() {
            std::env::set_current_dir(d)
                .map_err(|e| format!("error: failed to chdir into {}: {e}", d.display()))?;
            return Ok(true);
        }
        dir = d.parent();
    }
    Ok(false)
}

struct EngineFlags {
    latex: bool,
    pdflatex: bool,
    xelatex: bool,
    lualatex: bool,
    #[cfg(feature = "tectonic-backend")]
    tectonic: bool,
}

fn get_engine(default_engine: LatexEngine, ty: EngineFlags) -> Result<LatexEngine, String> {
    #[cfg(feature = "tectonic-backend")]
    let count = (ty.latex as u8) << 0
        | (ty.pdflatex as u8) << 1
        | (ty.xelatex as u8) << 2
        | (ty.lualatex as u8) << 3
        | (ty.tectonic as u8) << 4;

    #[allow(clippy::identity_op)]
    #[cfg(not(feature = "tectonic-backend"))]
    let count = (ty.latex as u8) << 0
        | (ty.pdflatex as u8) << 1
        | (ty.xelatex as u8) << 2
        | (ty.lualatex as u8) << 3;

    match count {
        0 => Ok(default_engine),
        1 => Ok(LatexEngine::Latex),
        2 => Ok(LatexEngine::PdfLatex),
        4 => Ok(LatexEngine::XeLatex),
        8 => Ok(LatexEngine::LuaLatex),
        #[cfg(feature = "tectonic-backend")]
        16 => Ok(LatexEngine::Tectonic),
        _ => Err("error: more than one latex engine flag was given".to_owned()),
    }
}

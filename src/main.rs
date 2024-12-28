#![allow(clippy::enum_variant_names)]
#![allow(clippy::derive_partial_eq_without_eq)]
#![allow(clippy::needless_return)]
#![deny(bindings_with_variant_name)]

mod codegen;
mod commands;
mod compile;
mod constants;
mod error;
mod lexer;
mod location;
mod parser;
mod vesmodule;

use std::fs;
use std::process::ExitCode;

use clap::Parser;

use crate::commands::{LatexEngineType, VestiOpt};
use crate::compile::VestiCompiler;
use crate::error::VestiErr;

fn main() -> ExitCode {
    let args = commands::VestiOpt::parse();

    match args {
        VestiOpt::Clear => match fs::remove_dir_all(constants::VESTI_LOCAL_DUMMY_DIR) {
            Ok(_) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("{err}");
                return ExitCode::FAILURE;
            }
        },
        ref argument @ VestiOpt::Compile {
            has_sub_vesti,
            emit_tex_only,
            compile_limit,
            no_color,
            watch,
            use_old_bracket,
            ..
        } => {
            let pretty_print = if no_color {
                crate::error::pretty_print::plain_print
            } else {
                crate::error::pretty_print::pretty_print
            };

            let file_lists = match args.take_filename() {
                Ok(inner) => inner,
                Err(err) => {
                    pretty_print(None, err, None).unwrap();
                    return ExitCode::FAILURE;
                }
            };

            let engine_type = match argument.get_latex_type() {
                Ok(LatexEngineType::Invalid) => {
                    let err = VestiErr::make_util_err(error::VestiUtilErrKind::InvalidLaTeXEngine);
                    pretty_print(None, err, None).unwrap();
                    return ExitCode::FAILURE;
                }
                Ok(engine) => engine,
                Err(err) => {
                    pretty_print(None, err, None).unwrap();
                    return ExitCode::FAILURE;
                }
            };

            let use_old_bracket = match commands::get_use_old_bracket_status() {
                Ok(val) => use_old_bracket || val,
                Err(err) => {
                    pretty_print(None, err, None).unwrap();
                    return ExitCode::FAILURE;
                }
            };

            let mut compiler = match VestiCompiler::init(
                &file_lists,
                engine_type,
                has_sub_vesti,
                emit_tex_only,
                compile_limit,
                no_color,
                use_old_bracket,
                watch,
            ) {
                Ok(compiler) => compiler,
                Err(err) => {
                    pretty_print(None, err, None).unwrap();
                    return ExitCode::FAILURE;
                }
            };

            compiler.run()
        }
    }
}

#![allow(clippy::enum_variant_names)]
#![allow(clippy::derive_partial_eq_without_eq)]
#![allow(clippy::needless_return)]
#![deny(bindings_with_variant_name)]
#![allow(unused)]

mod codegen;
mod commands;
mod compile;
mod constants;
mod error;
mod exit_status;
mod initialization;
mod lexer;
mod location;
mod macros;
mod parser;

use std::env;
use std::fs;
use std::io::ErrorKind;
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use clap::Parser;

use crate::commands::{LatexEngineType, VestiOpt};
use crate::error::pretty_print::pretty_print;
use crate::error::VestiErr;
use crate::exit_status::ExitCode;
use crate::initialization::generate_vesti_file;

fn main() -> ExitCode {
    let args = commands::VestiOpt::parse();

    match args {
        VestiOpt::Init { project_name } => {
            let project_name = if let Some(project_name) = project_name {
                PathBuf::from(project_name)
            } else {
                const ERR_MESSAGE: &str = "cannot get the current directory";
                let tmp = std::env::current_dir().expect(ERR_MESSAGE);
                PathBuf::from(tmp.file_name().expect(ERR_MESSAGE))
            };
            try_catch!(generate_vesti_file(project_name), _, ExitCode::Success)
        }
        VestiOpt::Clear => {
            try_catch!(io_handle: fs::remove_dir_all(constants::VESTI_LOCAL_DUMMY_DIR), _, ExitCode::Success)
        }
        ref argument @ VestiOpt::Compile {
            has_sub_vesti,
            emit_tex_only,
            compile_limit,
            ..
        } => {
            match fs::create_dir(constants::VESTI_LOCAL_DUMMY_DIR) {
                Ok(()) => {}
                Err(err) => {
                    let err_kind = err.kind();
                    if err_kind != ErrorKind::AlreadyExists {
                        pretty_print::<false>(None, err.into(), None).unwrap();
                        return ExitCode::Failure;
                    }
                }
            }

            let file_lists = match args.take_filename() {
                Ok(inner) => inner,
                Err(err) => {
                    pretty_print::<false>(None, err, None).unwrap();
                    return ExitCode::Failure;
                }
            };

            let engine_type = match argument.get_latex_type() {
                Ok(LatexEngineType::Invalid) => {
                    let err = VestiErr::make_util_err(error::VestiUtilErrKind::InvalidLaTeXEngine);
                    pretty_print::<false>(None, err, None).unwrap();
                    return ExitCode::Failure;
                }
                Ok(engine) => engine,
                Err(err) => {
                    pretty_print::<false>(None, err, None).unwrap();
                    return ExitCode::Failure;
                }
            };

            let mut handle_vesti: Vec<JoinHandle<_>> = Vec::with_capacity(10);
            let mut main_files: Vec<PathBuf> = Vec::with_capacity(10);
            let (main_file_sender, main_file_receiver) = mpsc::sync_channel::<PathBuf>(5);

            // compile vesti files into latex files
            for file_name in file_lists {
                let main_file_sender = main_file_sender.clone();
                handle_vesti.push(thread::spawn(move || {
                    compile::vesti::compile_vesti(
                        main_file_sender,
                        file_name,
                        engine_type,
                        has_sub_vesti,
                        emit_tex_only,
                    )
                }));

                if let Ok(main_filename) =
                    main_file_receiver.recv_timeout(Duration::from_millis(500))
                {
                    main_files.push(main_filename);
                }
            }

            for vesti in handle_vesti.into_iter() {
                if vesti.join().unwrap() == ExitCode::Failure {
                    return ExitCode::Failure;
                }
            }

            // compile latex files
            if !emit_tex_only {
                try_catch!(io_handle: env::set_current_dir(constants::VESTI_LOCAL_DUMMY_DIR));

                let mut handle_latex: Vec<JoinHandle<_>> = Vec::with_capacity(10);
                for latex_filename in main_files {
                    handle_latex.push(thread::spawn(move || {
                        match compile::latex::compile_latex(
                            &latex_filename,
                            compile_limit,
                            engine_type,
                        ) {
                            Ok(()) => ExitCode::Success,
                            Err(mut err) => {
                                err.inject_note_msg(format!(
                                    "cannot compile {} with {engine_type}.",
                                    latex_filename.display()
                                ));
                                pretty_print::<true>(None, err, None).unwrap();
                                ExitCode::Failure
                            }
                        }
                    }));
                }

                for latex in handle_latex.into_iter() {
                    if latex.join().unwrap() == ExitCode::Failure {
                        return ExitCode::Failure;
                    }
                }
            }

            println!("bye!");

            ExitCode::Success
        }
    }
}

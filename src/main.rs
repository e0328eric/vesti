#![allow(clippy::enum_variant_names)]
#![allow(clippy::derive_partial_eq_without_eq)]
#![deny(bindings_with_variant_name)]

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
use std::fs::{self, File};
use std::io::{BufWriter, ErrorKind, Read, Write};
use std::path::PathBuf;
use std::process::Command;
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use clap::Parser;

use crate::commands::{LaTeXEngineType, VestiOpt};
use crate::error::pretty_print::pretty_print;
use crate::error::{VestiErr, VestiUtilErrKind};
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
            try_catch!(io_handle: fs::remove_dir_all(constants::VESTI_CACHE_DIR), _, ExitCode::Success)
        }
        ref argument @ VestiOpt::Compile {
            has_sub_vesti,
            emit_tex_only,
            compile_limit,
            ..
        } => {
            match fs::create_dir(constants::VESTI_CACHE_DIR) {
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
                Ok(LaTeXEngineType::Invalid) => {
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
                    compile::compile_vesti(
                        main_file_sender,
                        file_name,
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
                try_catch!(io_handle: env::set_current_dir(constants::VESTI_CACHE_DIR));

                let mut handle_latex: Vec<JoinHandle<_>> = Vec::with_capacity(10);
                for latex_file in main_files {
                    handle_latex.push(thread::spawn(move || {
                        let mut latex_stdout = BufWriter::new(try_catch!(io_handle:
                            File::create(format!("./{}.stdout", latex_file.display())),
                            file,
                            file
                        ));
                        let mut latex_stderr = BufWriter::new(try_catch!(io_handle:
                            File::create(format!("./{}.stderr", latex_file.display())),
                            file,
                            file
                        ));

                        // It is good to compile latex at least three times
                        println!("[Compile {}]", latex_file.display());
                        for i in 0..compile_limit {
                            println!("[Compile num {}]", i + 1);
                            let output = try_catch!(
                                io_handle: Command::new(engine_type.to_string())
                                .arg(&latex_file)
                                .output(),
                                output,
                                output
                            );

                            latex_stdout
                                .write_all(format!("[Compile Num {}]\n", i + 1).as_bytes())
                                .unwrap();
                            latex_stdout.write_all(&output.stdout).unwrap();
                            latex_stdout.write_all("\n".as_bytes()).unwrap();
                            latex_stderr
                                .write_all(format!("[Compile Num {}]\n", i + 1).as_bytes())
                                .unwrap();
                            latex_stderr.write_all(&output.stderr).unwrap();
                            latex_stderr.write_all("\n".as_bytes()).unwrap();

                            if !output.status.success() {
                                let err =
                                    VestiErr::make_util_err(VestiUtilErrKind::LatexCompliationErr);
                                pretty_print::<true>(None, err, None).unwrap();
                                return ExitCode::Failure;
                            }
                        }

                        let mut pdf_filename = latex_file.clone();
                        pdf_filename.set_extension("pdf");
                        let final_pdf_filename =
                            PathBuf::from(format!("../{}", pdf_filename.display()));

                        let mut generated_pdf_file =
                            try_catch!(io_handle: File::open(&pdf_filename), file, file);
                        let mut contents = Vec::with_capacity(1000);

                        try_catch!(io_handle: generated_pdf_file.read_to_end(&mut contents));
                        try_catch!(io_handle: fs::write(final_pdf_filename, contents));

                        // close a file before remove it
                        drop(generated_pdf_file);
                        try_catch!(io_handle: fs::remove_file(pdf_filename));

                        println!("[Compile {} Done]", latex_file.display());

                        ExitCode::Success
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

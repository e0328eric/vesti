#![allow(clippy::enum_variant_names)]
#![allow(clippy::derive_partial_eq_without_eq)]
#![allow(clippy::needless_return)]
#![deny(bindings_with_variant_name)]

mod codegen;
mod commands;
mod compile;
mod constants;
mod error;
mod exit_status;
mod lexer;
mod location;
mod parser;
mod vesmodule;

use std::env;
use std::ffi;
use std::fs;
use std::io::ErrorKind;
use std::path::PathBuf;
use std::process;
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time;
use std::time::Duration;

use clap::Parser;

#[cfg(target_os = "windows")]
use windows::{core::*, Win32::UI::WindowsAndMessaging as win};

use crate::commands::{LatexEngineType, VestiOpt};
use crate::error::VestiErr;
use crate::exit_status::ExitCode;

fn main() -> ExitCode {
    let args = commands::VestiOpt::parse();

    match args {
        VestiOpt::Clear => match fs::remove_dir_all(constants::VESTI_LOCAL_DUMMY_DIR) {
            Ok(_) => ExitCode::Success,
            Err(err) => {
                eprintln!("{err}");
                return ExitCode::Failure;
            }
        },
        ref argument @ VestiOpt::Compile {
            has_sub_vesti,
            emit_tex_only,
            compile_limit,
            no_color,
            watch,
            ..
        } => {
            if watch {
                compile_in_watch(
                    &args,
                    argument,
                    has_sub_vesti,
                    emit_tex_only,
                    compile_limit,
                    no_color,
                )
            } else {
                compile_vesti_main(
                    &args,
                    argument,
                    has_sub_vesti,
                    emit_tex_only,
                    compile_limit,
                    no_color,
                )
            }
        }
    }
}

fn compile_in_watch(
    args: &commands::VestiOpt,
    argument: &commands::VestiOpt,
    has_sub_vesti: bool,
    emit_tex_only: bool,
    compile_limit: Option<usize>,
    no_color: bool,
) -> ExitCode {
    let pretty_print_note = if no_color {
        crate::error::pretty_print::plain_print::<true>
    } else {
        crate::error::pretty_print::pretty_print::<true>
    };

    // handling SIGINT
    // XXX: This is a naive way to handle SIGINT. Later, there is a plan to
    // replace with `signal_handler` crate
    unsafe {
        libc::signal(
            libc::SIGINT,
            signal_handler as *mut ffi::c_void as libc::sighandler_t,
        );
    }

    let current_dir = match env::current_dir() {
        Ok(dir) => dir,
        Err(err) => {
            pretty_print_note(None, err.into(), None).unwrap();
            return ExitCode::Failure;
        }
    };

    let mut first_run = true;
    let mut prev_file_modified = time::SystemTime::now();

    loop {
        let file_lists = match args.take_filename() {
            Ok(inner) => inner,
            Err(err) => {
                pretty_print_note(None, err, None).unwrap();
                return ExitCode::Failure;
            }
        };

        let mut file_modified_list = Vec::with_capacity(file_lists.len());
        for filename in &file_lists {
            match fs::metadata(filename).and_then(|metadata| metadata.modified()) {
                Ok(modified) => file_modified_list.push(modified),
                Err(err) => {
                    if cfg!(target_os = "windows") {
                        unsafe {
                            win::MessageBoxA(
                                None,
                                s!("vesti error occurs. See the console for more information"),
                                s!("vesti watch error"),
                                win::MB_ICONERROR | win::MB_OK,
                            )
                        };
                    }
                    pretty_print_note(None, err.into(), None).unwrap();
                    return ExitCode::Failure;
                }
            };
        }

        for file_modified in &file_modified_list {
            if first_run || *file_modified > prev_file_modified {
                let exitcode = compile_vesti_main(
                    args,
                    argument,
                    has_sub_vesti,
                    emit_tex_only,
                    compile_limit,
                    no_color,
                );

                if exitcode == ExitCode::Failure && cfg!(target_os = "windows") {
                    unsafe {
                        win::MessageBoxA(
                            None,
                            s!("vesti compilation failed. See the console for more information."),
                            s!("vesti watch warning"),
                            win::MB_ICONWARNING | win::MB_OK,
                        )
                    };
                }

                println!("Press Ctrl+C to exit...");

                if let Err(err) = env::set_current_dir(&current_dir) {
                    pretty_print_note(None, err.into(), None).unwrap();
                    return ExitCode::Failure;
                }

                if !first_run {
                    prev_file_modified = *file_modified;
                } else {
                    first_run = false;
                }
                break;
            }
        }

        std::thread::sleep(time::Duration::from_millis(300));
    }
}

fn compile_vesti_main(
    args: &commands::VestiOpt,
    argument: &commands::VestiOpt,
    has_sub_vesti: bool,
    emit_tex_only: bool,
    compile_limit: Option<usize>,
    no_color: bool,
) -> ExitCode {
    let pretty_print = if no_color {
        crate::error::pretty_print::plain_print::<false>
    } else {
        crate::error::pretty_print::pretty_print::<false>
    };
    let pretty_print_note = if no_color {
        crate::error::pretty_print::plain_print::<true>
    } else {
        crate::error::pretty_print::pretty_print::<true>
    };

    match fs::create_dir(constants::VESTI_LOCAL_DUMMY_DIR) {
        Ok(()) => {}
        Err(err) => {
            let err_kind = err.kind();
            if err_kind != ErrorKind::AlreadyExists {
                pretty_print(None, err.into(), None).unwrap();
                return ExitCode::Failure;
            }
        }
    }

    let file_lists = match args.take_filename() {
        Ok(inner) => inner,
        Err(err) => {
            pretty_print(None, err, None).unwrap();
            return ExitCode::Failure;
        }
    };

    let engine_type = match argument.get_latex_type() {
        Ok(LatexEngineType::Invalid) => {
            let err = VestiErr::make_util_err(error::VestiUtilErrKind::InvalidLaTeXEngine);
            pretty_print(None, err, None).unwrap();
            return ExitCode::Failure;
        }
        Ok(engine) => engine,
        Err(err) => {
            pretty_print(None, err, None).unwrap();
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
                no_color,
            )
        }));

        if let Ok(main_filename) = main_file_receiver.recv_timeout(Duration::from_millis(500)) {
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
        if let Err(err) = env::set_current_dir(constants::VESTI_LOCAL_DUMMY_DIR) {
            pretty_print(None, err.into(), None).unwrap();
            return ExitCode::Failure;
        }

        let mut handle_latex: Vec<JoinHandle<_>> = Vec::with_capacity(10);
        for latex_filename in main_files {
            handle_latex.push(thread::spawn(move || {
                match compile::latex::compile_latex(&latex_filename, compile_limit, engine_type) {
                    Ok(()) => ExitCode::Success,
                    Err(mut err) => {
                        err.inject_note_msg(format!(
                            "cannot compile {} with {engine_type}.",
                            latex_filename.display()
                        ));
                        pretty_print_note(None, err, None).unwrap();
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

extern "C" fn signal_handler(_signal: ffi::c_int) -> ! {
    println!("exit vesti...");
    process::exit(0);
}

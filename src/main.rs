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

use std::env;
use std::ffi;
use std::fs;
use std::io::ErrorKind;
use std::path::PathBuf;
use std::process::{self, ExitCode};
use std::time;

use clap::Parser;

#[cfg(target_os = "windows")]
use windows::{core::*, Win32::UI::WindowsAndMessaging as win};

use crate::commands::{LatexEngineType, VestiOpt};
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
            if watch {
                compile_in_watch(
                    &args,
                    argument,
                    has_sub_vesti,
                    emit_tex_only,
                    compile_limit,
                    no_color,
                    use_old_bracket,
                )
            } else {
                compile_vesti_main(
                    &args,
                    argument,
                    has_sub_vesti,
                    emit_tex_only,
                    compile_limit,
                    no_color,
                    use_old_bracket,
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
    use_old_bracket: bool,
) -> ExitCode {
    let pretty_print = if no_color {
        crate::error::pretty_print::plain_print
    } else {
        crate::error::pretty_print::pretty_print
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
            pretty_print(
                None,
                VestiErr::from_io_err(err, "cannot get the current directory"),
                None,
            )
            .unwrap();
            return ExitCode::FAILURE;
        }
    };

    let mut first_run = true;
    let mut prev_file_modified = time::SystemTime::now();

    loop {
        let file_lists = match args.take_filename() {
            Ok(inner) => inner,
            Err(err) => {
                pretty_print(None, err, None).unwrap();
                return ExitCode::FAILURE;
            }
        };

        let mut file_modified_list = Vec::with_capacity(file_lists.len());
        for filename in &file_lists {
            match fs::metadata(filename).and_then(|metadata| metadata.modified()) {
                Ok(modified) => file_modified_list.push(modified),
                Err(err) => {
                    #[cfg(target_os = "windows")]
                    unsafe {
                        win::MessageBoxA(
                            None,
                            s!("vesti error occurs. See the console for more information"),
                            s!("vesti watch error"),
                            win::MB_ICONERROR | win::MB_OK,
                        )
                    };
                    pretty_print(
                        None,
                        VestiErr::from_io_err(
                            err,
                            format!("cannot get a metadata from {}", filename.display()),
                        ),
                        None,
                    )
                    .unwrap();
                    return ExitCode::FAILURE;
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
                    use_old_bracket,
                );

                #[cfg(target_os = "windows")]
                if exitcode == ExitCode::FAILURE {
                    unsafe {
                        win::MessageBoxA(
                            None,
                            s!("vesti compilation failed. See the console for more information."),
                            s!("vesti watch warning"),
                            win::MB_ICONWARNING | win::MB_OK,
                        )
                    };
                }

                println!("\r\nPress Ctrl+C to exit...");

                if let Err(err) = env::set_current_dir(&current_dir) {
                    pretty_print(
                        None,
                        VestiErr::from_io_err(
                            err,
                            format!(
                                "cannot set the current directory into {}",
                                current_dir.display()
                            ),
                        ),
                        None,
                    )
                    .unwrap();
                    return ExitCode::FAILURE;
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
    use_old_bracket: bool,
) -> ExitCode {
    let pretty_print = if no_color {
        crate::error::pretty_print::plain_print
    } else {
        crate::error::pretty_print::pretty_print
    };

    match fs::create_dir(constants::VESTI_LOCAL_DUMMY_DIR) {
        Ok(()) => {}
        Err(err) => {
            let err_kind = err.kind();
            if err_kind != ErrorKind::AlreadyExists {
                pretty_print(
                    None,
                    VestiErr::from_io_err(
                        err,
                        format!(
                            "cannot create directory {}",
                            constants::VESTI_LOCAL_DUMMY_DIR
                        ),
                    ),
                    None,
                )
                .unwrap();
                return ExitCode::FAILURE;
            }
        }
    }

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

    // compile vesti files into latex files
    let mut main_files: Vec<PathBuf> = Vec::with_capacity(10);
    for file_name in file_lists {
        if compile::vesti::compile_vesti(
            &mut main_files,
            file_name,
            engine_type,
            has_sub_vesti,
            emit_tex_only,
            no_color,
            use_old_bracket,
        ) == ExitCode::FAILURE
        {
            return ExitCode::FAILURE;
        }
    }

    // compile latex files
    if !emit_tex_only {
        if let Err(err) = env::set_current_dir(constants::VESTI_LOCAL_DUMMY_DIR) {
            pretty_print(
                None,
                VestiErr::from_io_err(
                    err,
                    format!(
                        "cannot set current directory into {}",
                        constants::VESTI_LOCAL_DUMMY_DIR
                    ),
                ),
                None,
            )
            .unwrap();
            return ExitCode::FAILURE;
        }

        for latex_filename in main_files {
            match compile::latex::compile_latex(&latex_filename, compile_limit, engine_type) {
                Ok(()) => {}
                Err(err) => {
                    pretty_print(None, err, None).unwrap();
                    return ExitCode::FAILURE;
                }
            }
        }
    }

    println!("bye!");

    ExitCode::SUCCESS
}

extern "C" fn signal_handler(_signal: ffi::c_int) -> ! {
    println!("exit vesti...");
    process::exit(0);
}

#![allow(clippy::enum_variant_names)]
#![allow(clippy::derive_partial_eq_without_eq)]
#![deny(bindings_with_variant_name)]

mod codegen;
mod commands;
mod error;
mod exit_status;
mod initialization;
mod lexer;
mod location;
mod parser;

use std::path::PathBuf;
use std::sync::atomic::AtomicUsize;
use std::sync::{Arc, RwLock};
use std::thread::{self, JoinHandle};

use clap::Parser;

use signal_hook::flag as signal_flag;

use crate::commands::{compile_vesti, VestiOpt};
use crate::error::pretty_print::pretty_print;
use crate::exit_status::ExitCode;
use crate::initialization::generate_vesti_file;

fn main() -> ExitCode {
    let args = commands::VestiOpt::parse();
    let is_loop_end = Arc::new(RwLock::new(false));

    if let VestiOpt::Init { project_name } = args {
        let project_name = if let Some(project_name) = project_name {
            PathBuf::from(project_name)
        } else {
            const ERR_MESSAGE: &str = "cannot get the current directory";
            let tmp = std::env::current_dir().expect(ERR_MESSAGE);
            PathBuf::from(tmp.file_name().expect(ERR_MESSAGE))
        };
        return match generate_vesti_file(project_name) {
            Ok(()) => ExitCode::Success,
            Err(err) => {
                println!("{}", pretty_print(None, err, None));
                ExitCode::Failure
            }
        };
    } else {
        let is_continuous = args.is_continuous_compile();

        let trap = Arc::new(AtomicUsize::new(0));
        // TODO: I do not test this code in windows actually :)
        for signal in commands::SIGNALS.iter() {
            signal_flag::register_usize(*signal, Arc::clone(&trap), *signal as usize)
                .expect("Undefined behavior happened!");
        }

        let file_lists = match args.take_file_name() {
            Ok(inner) => inner,
            Err(err) => {
                println!("{}", pretty_print(None, err, None));
                return ExitCode::Failure;
            }
        };

        let mut handle_vesti: Vec<JoinHandle<_>> = Vec::new();
        for file_name in file_lists {
            let cloned_trap = Arc::clone(&trap);
            let cloned_bool = Arc::clone(&is_loop_end);
            handle_vesti.push(thread::spawn(move || {
                return compile_vesti(cloned_trap, file_name, is_continuous, cloned_bool);
            }));
        }

        if is_continuous {
            println!("Press Ctrl+C to finish the program.");
        }

        for vesti in handle_vesti.into_iter() {
            if vesti.join().unwrap() == ExitCode::Failure {
                return ExitCode::Failure;
            }
        }

        println!("bye!");
    }

    ExitCode::Success
}

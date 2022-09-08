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
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use clap::Parser;

#[cfg(target_os = "windows")]
use signal_hook::consts::signal::{SIGILL, SIGINT, SIGTERM};
#[cfg(not(target_os = "windows"))]
use signal_hook::consts::signal::{SIGINT, SIGTERM};
use signal_hook::flag as signal_flag;

use crate::commands::{compile_vesti, VestiOpt};
use crate::error::pretty_print::pretty_print;
use crate::exit_status::ExitCode;
use crate::initialization::generate_vesti_file;

fn main() -> ExitCode {
    let args = commands::VestiOpt::parse();

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
        #[cfg(target_os = "windows")]
        for signal in [SIGINT, SIGTERM, SIGILL].iter() {
            signal_flag::register_usize(*signal, Arc::clone(&trap), *signal as usize)
                .expect("Undefined behavior happened!");
        }
        #[cfg(not(target_os = "windows"))]
        for signal in [SIGINT, SIGTERM].iter() {
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

        let mut handle_vesti: Vec<JoinHandle<()>> = Vec::new();
        for file_name in file_lists {
            handle_vesti.push(thread::spawn(move || {
                compile_vesti(file_name, is_continuous);
            }));
        }

        if !is_continuous {
            for vesti in handle_vesti.into_iter() {
                vesti.join().unwrap();
            }
        } else {
            println!("Press Ctrl+C to finish the program.");
            #[cfg(target_os = "windows")]
            while ![SIGINT, SIGTERM, SIGILL].contains(&(trap.load(Ordering::Relaxed) as i32)) {
                thread::sleep(Duration::from_millis(500));
            }
            #[cfg(not(target_os = "windows"))]
            while ![SIGINT, SIGTERM].contains(&(trap.load(Ordering::Relaxed) as i32)) {
                thread::sleep(Duration::from_millis(500));
            }
        }

        println!("bye!");
    }

    ExitCode::Success
}

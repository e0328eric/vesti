// Copyright (c) 2022 Sungbae Jeong
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::{Duration, SystemTime};

use crate::codegen::make_latex_format;
use crate::error::{self, pretty_print::pretty_print};
use crate::exit_status::ExitCode;
use crate::lexer::Lexer;
use crate::parser::Parser;

use signal_hook::consts::signal::{SIGINT, SIGTERM};
pub const SIGNALS: [i32; 2] = [SIGINT, SIGTERM];

macro_rules! unwrap_err {
    ($name: ident := $to_unwrap: expr, $source: expr, $file_name: expr, $is_loop_end: expr) => {
        let $name = match $to_unwrap {
            Ok(inner) => inner,
            Err(err) => {
                pretty_print($source, err, $file_name).unwrap();
                let mut writer = $is_loop_end.write().unwrap();
                *writer = true;
                return ExitCode::Failure;
            }
        };
    };
    (mut $name: ident := $to_unwrap: expr, $source: expr, $file_name: expr, $is_loop_end: expr) => {
        let mut $name = match $to_unwrap {
            Ok(inner) => inner,
            Err(err) => {
                pretty_print($source, err, $file_name).unwrap();
                let mut writer = $is_loop_end.write().unwrap();
                *writer = true;
                return ExitCode::Failure;
            }
        };
    };
    ($name: ident = $to_unwrap: expr, $source: expr, $file_name: expr, $is_loop_end: expr) => {
        $name = match $to_unwrap {
            Ok(inner) => inner,
            Err(err) => {
                pretty_print($source, err, $file_name).unwrap();
                let mut writer = $is_loop_end.write().unwrap();
                *writer = true;
                return ExitCode::Failure;
            }
        };
    };
}

fn output_file_name(file_name: &Path) -> PathBuf {
    file_name.with_extension("tex")
}

fn take_time(file_name: &Path) -> error::Result<SystemTime> {
    let path = file_name;
    Ok(path.metadata()?.modified()?)
}

pub fn compile_vesti(
    trap: Arc<AtomicUsize>,
    file_name: PathBuf,
    is_continuous: bool,
    is_loop_end: Arc<RwLock<bool>>,
) -> ExitCode {
    let mut init_compile = true;
    let output = output_file_name(&file_name);
    unwrap_err!(mut init_time := take_time(&file_name), None, None, is_loop_end);
    let mut now_time = init_time;

    while !SIGNALS.contains(&(trap.load(Ordering::Relaxed) as i32)) {
        #[allow(clippy::blocks_in_if_conditions)]
        if {
            let reader = is_loop_end.read().unwrap();
            *reader
        } {
            return ExitCode::Failure;
        }
        if init_compile || init_time != now_time {
            let source = fs::read_to_string(&file_name).expect("Opening file error occurred!");
            let mut parser = Parser::new(Lexer::new(&source));
            unwrap_err!(contents := make_latex_format::<false>(&mut parser), Some(source.as_ref()), Some(&file_name), is_loop_end);
            drop(parser);

            fs::write(&output, contents).expect("File write failed.");

            if !is_continuous {
                break;
            }
            if !init_compile {
                println!("Press Ctrl+C to finish the program.");
            }

            init_compile = false;
            init_time = now_time;
        }
        unwrap_err!(now_time = take_time(&file_name), None, None, is_loop_end);
        thread::sleep(Duration::from_millis(500));
    }

    ExitCode::Success
}

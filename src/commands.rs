use crate::error::{self, pretty_print::pretty_print};
use crate::lexer::Lexer;
use crate::parser::Parser;
use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, SystemTime};
use structopt::StructOpt;

macro_rules! unwrap_err {
    ($name: ident := $to_unwrap: expr, $source: expr, $file_name: expr) => {
        let $name = match $to_unwrap {
            Ok(inner) => inner,
            Err(err) => {
                println!("{}", pretty_print($source, err, $file_name));
                std::process::exit(1);
            }
        };
    };
    (mut $name: ident := $to_unwrap: expr, $source: expr, $file_name: expr) => {
        let mut $name = match $to_unwrap {
            Ok(inner) => inner,
            Err(err) => {
                println!("{}", pretty_print($source, err, $file_name));
                std::process::exit(1);
            }
        };
    };
    ($name: ident = $to_unwrap: expr, $source: expr, $file_name: expr) => {
        $name = match $to_unwrap {
            Ok(inner) => inner,
            Err(err) => {
                println!("{}", pretty_print($source, err, $file_name));
                std::process::exit(1);
            }
        };
    };
}

#[derive(StructOpt)]
pub enum VestiOpt {
    Init, // TODO: Do nothing in the alpha version
    Run {
        #[structopt(short, long)]
        continuous: bool,
        #[structopt(name = "FILE", parse(from_os_str))]
        file_name: Vec<PathBuf>,
    },
}

impl VestiOpt {
    pub fn is_continuous_compile(&self) -> bool {
        if let Self::Run { continuous, .. } = self {
            *continuous
        } else {
            false
        }
    }

    pub fn take_file_name(&self) -> Vec<PathBuf> {
        if let Self::Run {
            continuous: _,
            file_name,
        } = self
        {
            file_name.clone()
        } else {
            Vec::new()
        }
    }
}

fn output_file_name(file_name: &Path) -> PathBuf {
    file_name.with_extension("tex")
}

fn take_time(file_name: &Path) -> error::Result<SystemTime> {
    let path = file_name;
    Ok(path.metadata()?.modified()?)
}

pub fn compile_vesti(file_name: PathBuf, is_continuous: bool) {
    let mut init_compile = true;
    let output = output_file_name(&file_name);
    unwrap_err!(mut init_time := take_time(&file_name), None, None);
    let mut now_time = init_time;

    loop {
        if init_compile || init_time != now_time {
            let source = fs::read_to_string(&file_name).expect("Opening file error occured!");
            let mut parser = Parser::new(Lexer::new(&source));
            unwrap_err!(contents := parser.make_latex_format(), Some(source.as_ref()), Some(&file_name));
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
        unwrap_err!(now_time = take_time(&file_name), None, None);
        thread::sleep(Duration::from_millis(500));
    }
}

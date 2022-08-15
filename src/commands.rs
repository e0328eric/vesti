use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, SystemTime};

use clap::Parser as ClapParser;

use crate::codegen::make_latex_format;
use crate::error;
use crate::error::err_kind::{VestiCommandUtilErr, VestiErrKind};
use crate::error::pretty_print::pretty_print;
use crate::exit_status::ExitCode;
use crate::lexer::Lexer;
use crate::parser::Parser;

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

#[derive(ClapParser)]
pub enum VestiOpt {
    /// Initialize the vesti project
    Init {
        #[clap(name = "PROJECT_NAME")]
        project_name: Option<String>,
    },
    Run {
        /// Compile vesti continuously.
        #[clap(short, long)]
        continuous: bool,
        /// If this flag is on, then vesti compiles all vesti files in that directory.
        #[clap(long)]
        all: bool,
        /// Input file names or directory name.
        /// Directory name must type once.
        #[clap(name = "FILE", parse(from_os_str))]
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

    pub fn take_file_name(&self) -> error::Result<Vec<PathBuf>> {
        let mut output: Vec<PathBuf> = Vec::new();

        if let Self::Run {
            continuous: _,
            all,
            file_name,
        } = self
        {
            if !all {
                return Ok(file_name.clone());
            }

            assert_eq!(file_name.len(), 1);

            let file_dir = file_name[0].ancestors().nth(1);
            let current_dir = if file_dir == Some(Path::new("")) {
                Path::new(".").to_path_buf()
            } else if let Some(path) = file_dir {
                path.to_path_buf()
            } else {
                return Err(error::VestiErr {
                    err_kind: VestiErrKind::UtilErr(VestiCommandUtilErr::NoFilenameInputErr),
                    location: None,
                });
            };

            for path in walkdir::WalkDir::new(current_dir) {
                match path {
                    Ok(dir) => {
                        if let Some(ext) = dir.path().extension() {
                            if ext == "ves" {
                                output.push(dir.into_path())
                            }
                        }
                    }
                    Err(_) => {
                        return Err(error::VestiErr {
                            err_kind: VestiErrKind::UtilErr(VestiCommandUtilErr::TakeFilesErr),
                            location: None,
                        })
                    }
                }
            }
            output.sort();
        }

        Ok(output)
    }
}

fn output_file_name(file_name: &Path) -> PathBuf {
    file_name.with_extension("tex")
}

fn take_time(file_name: &Path) -> error::Result<SystemTime> {
    let path = file_name;
    Ok(path.metadata()?.modified()?)
}

pub fn compile_vesti(file_name: PathBuf, is_continuous: bool) -> ExitCode {
    let mut init_compile = true;
    let output = output_file_name(&file_name);
    unwrap_err!(mut init_time := take_time(&file_name), None, None);
    let mut now_time = init_time;

    loop {
        if init_compile || init_time != now_time {
            let source = fs::read_to_string(&file_name).expect("Opening file error occurred!");
            let mut parser = Parser::new(Lexer::new(&source));
            unwrap_err!(contents := make_latex_format::<false>(&mut parser), Some(source.as_ref()), Some(&file_name));
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

    ExitCode::Success
}

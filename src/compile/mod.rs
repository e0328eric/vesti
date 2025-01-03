pub mod latex;
pub mod vesti;

use std::collections::HashMap;
use std::env;
use std::ffi;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process::{self, ExitCode};
use std::thread;
use std::time::{self, SystemTime};

#[cfg(target_os = "windows")]
use windows::{core::*, Win32::UI::WindowsAndMessaging as win};

use crate::commands::LatexEngineType;
use crate::constants;
use crate::error::{self, VestiErr};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct VestiFile<'p> {
    filename: &'p Path,
    latex_filename: Option<PathBuf>,
    dirty: bool,
    is_main: bool,
}

pub struct VestiCompiler<'p> {
    ves_files: Vec<VestiFile<'p>>,
    modification_time: HashMap<&'p Path, SystemTime>,
    engine_type: LatexEngineType,
    has_sub_vesti: bool,
    emit_tex_only: bool,
    compile_limit: Option<usize>,
    no_color: bool,
    is_watch: bool,
}

impl<'p> VestiCompiler<'p> {
    #[allow(clippy::too_many_arguments)]
    pub fn init(
        ves_files_raw: &'p [PathBuf],
        engine_type: LatexEngineType,
        has_sub_vesti: bool,
        emit_tex_only: bool,
        compile_limit: Option<usize>,
        no_color: bool,
        is_watch: bool,
    ) -> error::Result<Self> {
        let mut ves_files = Vec::with_capacity(ves_files_raw.len());
        for filename in ves_files_raw {
            ves_files.push(VestiFile {
                filename: filename.as_path(),
                latex_filename: None,
                dirty: true, // A trick that compile all files in first compilation
                is_main: false,
            });
        }

        let mut modification_time = HashMap::with_capacity(ves_files_raw.len());
        for ves_file in &ves_files {
            modification_time.insert(ves_file.filename, get_modification_time(ves_file.filename)?);
        }

        Ok(Self {
            ves_files,
            modification_time,
            engine_type,
            has_sub_vesti,
            emit_tex_only,
            compile_limit,
            no_color,
            is_watch,
        })
    }

    pub fn run(&mut self) -> ExitCode {
        if self.is_watch {
            self.run_watch()
        } else {
            self.run_once()
        }
    }

    fn run_watch(&mut self) -> ExitCode {
        let pretty_print = if self.no_color {
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
        let mut prev_exitcode = ExitCode::SUCCESS;
        let mut prev_file_modified = time::SystemTime::now();

        loop {
            let recompile = {
                match self.update_modification_time() {
                    Ok(()) => {}
                    Err(err) => {
                        pretty_print(None, err, None).unwrap();
                        return ExitCode::FAILURE;
                    }
                }
                for ves_file in &mut self.ves_files {
                    let file_modified = self.modification_time[ves_file.filename];
                    if first_run || file_modified > prev_file_modified {
                        if !first_run {
                            prev_file_modified = file_modified;
                        } else {
                            first_run = false;
                        }
                        ves_file.dirty = true;
                    }
                }
                self.ves_files.iter().any(|ves_file| ves_file.dirty)
            };
            if recompile && prev_exitcode == ExitCode::SUCCESS {
                prev_exitcode = self.run_once();
                #[cfg(target_os = "windows")]
                if prev_exitcode == ExitCode::FAILURE {
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
            }

            thread::sleep(time::Duration::from_millis(300));
        }
    }

    fn run_once(&mut self) -> ExitCode {
        let pretty_print = if self.no_color {
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

        // compile vesti files into latex files
        for ves_file in &mut self.ves_files {
            if !ves_file.dirty {
                continue;
            }

            if vesti::compile_vesti(
                ves_file,
                self.engine_type,
                self.has_sub_vesti,
                self.emit_tex_only,
                self.no_color,
            ) == ExitCode::FAILURE
            {
                return ExitCode::FAILURE;
            }

            ves_file.dirty = false;
        }

        // compile latex files
        if !self.emit_tex_only {
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

            for ves_file in &mut self.ves_files {
                if !ves_file.is_main {
                    continue;
                }

                match latex::compile_latex(
                    ves_file.latex_filename.as_ref().unwrap(),
                    self.compile_limit,
                    self.engine_type,
                ) {
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

    fn update_modification_time(&mut self) -> error::Result<()> {
        for ves_file in &self.ves_files {
            *self.modification_time.get_mut(ves_file.filename).unwrap() =
                get_modification_time(ves_file.filename)?;
        }

        Ok(())
    }
}

fn get_modification_time(filename: &Path) -> error::Result<SystemTime> {
    return match fs::metadata(filename).and_then(|metadata| metadata.modified()) {
        Ok(modified) => Ok(modified),
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
            Err(VestiErr::from_io_err(
                err,
                format!("cannot get a metadata from {}", filename.display()),
            ))
        }
    };
}

extern "C" fn signal_handler(_signal: ffi::c_int) -> ! {
    println!("exit vesti...");
    process::exit(0);
}

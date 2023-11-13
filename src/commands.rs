use std::path::{Path, PathBuf};

use clap::Parser as ClapParser;

use crate::error::{self, VestiCommandUtilErrKind};

#[derive(ClapParser)]
#[command(author, version, about)]
pub enum VestiOpt {
    /// Initialize the vesti project
    Init {
        #[clap(name = "PROJECT_NAME")]
        project_name: Option<String>,
    },
    /// Compile vesti into Latex file
    Compile {
        /// Compile vesti continuously.
        #[clap(short, long)]
        continuous: bool,
        /// If this flag is on, then vesti compiles all vesti files in that directory.
        #[clap(long)]
        all: bool,
        /// Input file names or directory name.
        /// Directory name must type once.
        #[clap(value_name = "FILE")]
        file_name: Vec<PathBuf>,
    },
}

impl VestiOpt {
    pub fn take_filename(&self) -> error::Result<Vec<PathBuf>> {
        let mut output: Vec<PathBuf> = Vec::new();

        if let Self::Compile {
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
                return Err(error::VestiErr::UtilErr {
                    err_kind: VestiCommandUtilErrKind::NoFilenameInputErr,
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
                        return Err(error::VestiErr::UtilErr {
                            err_kind: VestiCommandUtilErrKind::TakeFilesErr,
                        })
                    }
                }
            }
            output.sort();
        }

        Ok(output)
    }
}

use std::fs;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::string::ToString;

use clap::Parser as ClapParser;
use yaml_rust::YamlLoader;

use crate::error::{self, VestiErr, VestiUtilErrKind};

#[derive(Debug, Clone, Copy)]
pub enum LaTeXEngineType {
    LaTeX,
    PdfLaTeX,
    XeLaTeX,
    LuaLaTeX,
    Invalid,
}

impl FromStr for LaTeXEngineType {
    type Err = std::convert::Infallible;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "latex" => Self::LaTeX,
            "pdflatex" => Self::PdfLaTeX,
            "xelatex" => Self::XeLaTeX,
            "lualatex" => Self::LuaLaTeX,
            _ => Self::Invalid,
        })
    }
}

impl ToString for LaTeXEngineType {
    fn to_string(&self) -> String {
        match self {
            Self::LaTeX => String::from("latex"),
            Self::PdfLaTeX => String::from("pdflatex"),
            Self::XeLaTeX => String::from("xelatex"),
            Self::LuaLaTeX => String::from("lualatex"),
            Self::Invalid => String::new(),
        }
    }
}

#[derive(ClapParser)]
#[command(author, version, about)]
pub enum VestiOpt {
    /// Initialize the vesti project
    Init {
        #[clap(name = "PROJECT_NAME")]
        project_name: Option<String>,
    },
    /// Remove `vesti-cache` folder
    Clear,
    /// Compile vesti into Latex file
    Compile {
        /// Input file names or directory name.
        /// Directory name must type once.
        #[clap(value_name = "FILE")]
        file_name: Vec<PathBuf>,
        /// If this flag is on, then vesti compiles all vesti files in that directory.
        #[clap(long)]
        all: bool,
        /// Whether the project has a sub-vesti files
        #[arg(short = 's', long = "has-sub")]
        has_sub_vesti: bool,
        /// Compile vesti into tex file only.
        /// There is a plan to make a standalone tex file
        #[arg(short = 'T', long = "emit-tex")]
        emit_tex_only: bool,
        /// Compile vesti into pdf with latex
        #[arg(
            short = 'L',
            long = "latex",
            conflicts_with_all(["is_pdflatex", "is_xelatex", "is_lualatex"]),
        )]
        is_latex: bool,
        /// Compile vesti into pdf with pdflatex
        #[arg(
            short = 'p',
            long = "pdflatex",
            conflicts_with_all(["is_latex", "is_xelatex", "is_lualatex"]),
        )]
        is_pdflatex: bool,
        /// Compile vesti into pdf with xelatex
        #[arg(
            short = 'x',
            long = "xelatex",
            conflicts_with_all(["is_latex", "is_pdflatex", "is_lualatex"]),
        )]
        is_xelatex: bool,
        /// Compile vesti into pdf with lualatex
        #[arg(
            short = 'l',
            long = "lualatex",
            conflicts_with_all(["is_latex", "is_pdflatex", "is_xelatex"]),
        )]
        is_lualatex: bool,
        /// Set the number of the compile cycles
        #[arg(long = "lim", default_value_t = 2)]
        compile_limit: usize,
    },
}

impl VestiOpt {
    pub fn take_filename(&self) -> error::Result<Vec<PathBuf>> {
        let mut output: Vec<PathBuf> = Vec::new();

        if let Self::Compile {
            all,
            has_sub_vesti,
            file_name,
            ..
        } = self
        {
            if !all {
                return Ok(file_name.clone());
            }

            if *all && !has_sub_vesti {
                return Err(VestiErr::make_util_err(
                    VestiUtilErrKind::CompileAllWithoutHasSubVesti,
                ));
            }

            assert_eq!(file_name.len(), 1);

            let file_dir = file_name[0].ancestors().nth(1);
            let current_dir = if file_dir == Some(Path::new("")) {
                Path::new(".").to_path_buf()
            } else if let Some(path) = file_dir {
                path.to_path_buf()
            } else {
                return Err(VestiErr::make_util_err(
                    VestiUtilErrKind::NoFilenameInputErr,
                ));
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
                        return Err(VestiErr::make_util_err(VestiUtilErrKind::TakeFilesErr));
                    }
                }
            }
            output.sort();
        }

        Ok(output)
    }

    pub fn get_latex_type(&self) -> error::Result<LaTeXEngineType> {
        let default_engine = read_config()?;

        if let Self::Compile {
            is_latex,
            is_xelatex,
            is_pdflatex,
            is_lualatex,
            ..
        } = self
        {
            let bitmask = (*is_latex as u8) << 3
                | (*is_pdflatex as u8) << 2
                | (*is_xelatex as u8) << 1
                | (*is_lualatex as u8);

            Ok(match bitmask {
                1 => LaTeXEngineType::LuaLaTeX,
                2 => LaTeXEngineType::XeLaTeX,
                4 => LaTeXEngineType::PdfLaTeX,
                8 => LaTeXEngineType::LaTeX,
                _ => default_engine,
            })
        } else {
            Ok(LaTeXEngineType::Invalid)
        }
    }
}

// Read a config file and return the position of the given engine
// The config file must in at .config/vesti directory
// and its name is config.yaml
fn read_config() -> error::Result<LaTeXEngineType> {
    let mut dir = dirs::config_dir().unwrap();
    dir.push("vesti/config.yaml");
    let contents = fs::read_to_string(dir).unwrap_or_default();
    let docs = YamlLoader::load_from_str(&contents)?;
    let doc = docs.get(0);
    let main_engine = if let Some(d) = doc {
        if d["engine"]["main"].is_badvalue() {
            "pdflatex"
        } else {
            d["engine"]["main"].as_str().unwrap()
        }
    } else {
        "pdflatex"
    };
    let main_engine = main_engine.to_lowercase();

    // String -> LaTeXEngineType never failes
    Ok(main_engine.parse().unwrap())
}

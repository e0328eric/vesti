use std::fmt::{self, Display};
use std::fs;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use clap::Parser as ClapParser;
use yaml_rust::YamlLoader;

use crate::error::{self, VestiErr, VestiUtilErrKind};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LatexEngineType {
    RawTexCode,
    LaTeX,
    PdfLaTeX,
    XeLaTeX,
    LuaLaTeX,
    #[cfg(feature = "tectonic-backend")]
    Tectonic,
    Invalid,
}

impl FromStr for LatexEngineType {
    type Err = std::convert::Infallible;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "raw" => Self::RawTexCode,
            "latex" => Self::LaTeX,
            "pdflatex" => Self::PdfLaTeX,
            "xelatex" => Self::XeLaTeX,
            "lualatex" => Self::LuaLaTeX,
            #[cfg(feature = "tectonic-backend")]
            "tectonic" => Self::Tectonic,
            _ => Self::Invalid,
        })
    }
}

impl Display for LatexEngineType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::LaTeX => write!(f, "latex"),
            Self::PdfLaTeX => write!(f, "pdflatex"),
            Self::XeLaTeX => write!(f, "xelatex"),
            Self::LuaLaTeX => write!(f, "lualatex"),
            #[cfg(feature = "tectonic-backend")]
            Self::Tectonic => write!(f, "tectonic"),
            _ => write!(f, ""),
        }
    }
}

#[derive(Debug, ClapParser)]
#[command(author, version, about)]
pub enum VestiOpt {
    /// Remove `vesti-cache` folder
    Clear,
    /// Compile vesti into Latex file
    Compile {
        /// Input file name or directory name.
        /// Directory name must type once.
        #[clap(value_name = "FILE")]
        file_name: Vec<PathBuf>,
        /// If this flag is on, then vesti compiles all vesti files in that directory.
        #[clap(short, long)]
        all: bool,
        /// Whether the project has a sub-vesti files
        #[arg(short = 's', long = "has-sub")]
        has_sub_vesti: bool,
        /// Compile vesti into tex file only.
        /// There is a plan to make a standalone tex file
        #[arg(short = 'e', long = "emit-tex")]
        emit_tex_only: bool,
        /// no color output on a terminal
        #[arg(short = 'N', long = "no-color")]
        no_color: bool,
        /// watch compiling vesti file
        #[arg(short = 'W', long = "watch")]
        watch: bool,
        /// Compile vesti into pdf with latex
        #[arg(
            short = 'L',
            long = "latex",
            conflicts_with_all(["is_pdflatex", "is_xelatex", "is_lualatex", "is_tectonic"]),
        )]
        is_latex: bool,
        /// Compile vesti into pdf with pdflatex
        #[arg(
            short = 'p',
            long = "pdflatex",
            conflicts_with_all(["is_latex", "is_xelatex", "is_lualatex", "is_tectonic"]),
        )]
        is_pdflatex: bool,
        /// Compile vesti into pdf with xelatex
        #[arg(
            short = 'x',
            long = "xelatex",
            conflicts_with_all(["is_latex", "is_pdflatex", "is_lualatex", "is_tectonic"]),
        )]
        is_xelatex: bool,
        /// Compile vesti into pdf with lualatex
        #[arg(
            short = 'l',
            long = "lualatex",
            conflicts_with_all(["is_latex", "is_pdflatex", "is_xelatex", "is_tectonic"]),
        )]
        is_lualatex: bool,
        /// Compile vesti into pdf with tectonic (can use only when it is compiled with `tectonic-backend` feature)
        #[arg(
            short = 'T',
            long = "tectonic",
            conflicts_with_all(["is_latex", "is_pdflatex", "is_xelatex", "is_lualatex"]),
        )]
        is_tectonic: bool,
        /// Set the number of the compile cycles
        #[arg(long = "lim")]
        compile_limit: Option<usize>,
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

    pub fn get_latex_type(&self) -> error::Result<LatexEngineType> {
        let default_engine = read_config()?;

        if let Self::Compile {
            is_latex,
            is_xelatex,
            is_pdflatex,
            is_lualatex,
            is_tectonic,
            ..
        } = self
        {
            let bitmask = (*is_latex as u8)
                | (*is_pdflatex as u8) << 1
                | (*is_xelatex as u8) << 2
                | (*is_lualatex as u8) << 3
                | (*is_tectonic as u8) << 4;

            Ok(match bitmask {
                1 => LatexEngineType::LaTeX,
                2 => LatexEngineType::PdfLaTeX,
                4 => LatexEngineType::XeLaTeX,
                8 => LatexEngineType::LuaLaTeX,
                #[cfg(feature = "tectonic-backend")]
                16 => LatexEngineType::Tectonic,
                #[cfg(not(feature = "tectonic-backend"))]
                16 => LatexEngineType::Invalid,
                _ => default_engine,
            })
        } else {
            Ok(LatexEngineType::Invalid)
        }
    }
}

// Read a config file and return the position of the given engine
// The config file must in at .config/vesti directory
// and its name is config.yaml
fn read_config() -> error::Result<LatexEngineType> {
    let mut dir = dirs::config_dir().unwrap();
    dir.push("vesti/config.yaml");
    let contents = fs::read_to_string(dir).unwrap_or_default();
    let docs = YamlLoader::load_from_str(&contents)?;
    let doc = docs.first();
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

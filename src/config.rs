use std::fs;
use std::io;
use std::path::PathBuf;

use serde::Deserialize;

use crate::diagnostic::{Diagnostic, DiagnosticInner, IoDiagnostic};
use crate::parser::LatexEngine;

#[derive(Debug)]
pub enum ConfigError {
    FailedOpenConfig,
    Io(io::Error),
}

impl From<io::Error> for ConfigError {
    fn from(e: io::Error) -> Self {
        ConfigError::Io(e)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct LuaConfig {
    pub make_log: bool,
    pub line_limit: usize,
}

impl Default for LuaConfig {
    fn default() -> Self {
        LuaConfig {
            make_log: false,
            line_limit: 45,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Config {
    pub engine: LatexEngine,
    pub lua: LuaConfig,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            #[cfg(feature = "tectonic-backend")]
            engine: LatexEngine::Tectonic,
            #[cfg(not(feature = "tectonic-backend"))]
            engine: LatexEngine::PdfLatex,
            lua: LuaConfig::default(),
        }
    }
}

impl Config {
    pub fn init(diagnostic: &mut Diagnostic<'_>) -> Result<Self, ConfigError> {
        let config_dir = get_config_path();
        let config_path = config_dir.join("config.ron");

        let context = match fs::read_to_string(&config_path) {
            Ok(c) => c,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Config::default()),
            Err(_) => {
                let io_diag = IoDiagnostic::new(
                    None,
                    format!("cannot read context from {}", config_path.display()),
                );
                diagnostic.init_diag_inner(DiagnosticInner::IoError(io_diag));
                return Err(ConfigError::FailedOpenConfig);
            }
        };

        match ron::from_str::<Config>(&context) {
            Ok(cfg) => Ok(cfg),
            Err(_) => {
                let io_diag = IoDiagnostic::new(None, "invalid config.ron format".to_owned());
                diagnostic.init_diag_inner(DiagnosticInner::IoError(io_diag));
                Err(ConfigError::FailedOpenConfig)
            }
        }
    }
}

pub fn get_config_path() -> PathBuf {
    #[cfg(windows)]
    {
        let base = std::env::var("APPDATA").unwrap_or_else(|_| ".".to_owned());
        PathBuf::from(base).join("vesti")
    }
    #[cfg(not(windows))]
    {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_owned());
        PathBuf::from(home).join(".config").join("vesti")
    }
}

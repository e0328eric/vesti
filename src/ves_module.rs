use std::fs;
use std::path::PathBuf;

use serde::Deserialize;

use crate::config::get_config_path;
use crate::diagnostic::{Diagnostic, DiagnosticInner, IoDiagnostic};
use crate::location::Span;
use crate::vesti_info::VESTI_DUMMY_DIR;

#[derive(Debug)]
pub enum VesModuleError {
    FailedGetModule,
    FailedOpenConfig,
}

#[derive(Debug, Deserialize)]
pub struct VestiExport {
    pub name: String,
    #[serde(default)]
    pub location: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct VestiModule {
    pub name: String,
    #[serde(default)]
    pub version: Option<String>,
    pub exports: Vec<VestiExport>,
}

pub fn download_module(
    diagnostic: &mut Diagnostic<'_>,
    mod_name: &str,
    import_file_loc: Option<Span>,
) -> Result<(), VesModuleError> {
    let config_path = get_config_path();
    let mod_dir_path: PathBuf = config_path.join(mod_name);
    let mod_data_path = mod_dir_path.join("vesti.ron");

    let context = match fs::read_to_string(&mod_data_path) {
        Ok(c) => c,
        Err(_) => {
            let io_diag = IoDiagnostic::new(
                import_file_loc,
                format!("cannot open file {}", mod_data_path.display()),
            );
            diagnostic.init_diag_inner(DiagnosticInner::IoError(io_diag));
            return Err(VesModuleError::FailedGetModule);
        }
    };

    let ves_module: VestiModule = match ron::from_str(&context) {
        Ok(m) => m,
        Err(_) => {
            let io_diag = IoDiagnostic::new(
                None,
                format!("cannot read context from {}", mod_data_path.display()),
            );
            diagnostic.init_diag_inner(DiagnosticInner::IoError(io_diag));
            return Err(VesModuleError::FailedOpenConfig);
        }
    };
    // `version` is part of the manifest but unused at copy time
    let _ = &ves_module.name;
    let _ = &ves_module.version;

    for export in &ves_module.exports {
        let mod_filename = mod_dir_path.join(&export.name);
        let location = export.location.as_deref().unwrap_or(VESTI_DUMMY_DIR);
        let into_copy_filename = PathBuf::from(location).join(&export.name);

        if fs::copy(&mod_filename, &into_copy_filename).is_err() {
            let io_diag = IoDiagnostic::new(
                import_file_loc,
                format!(
                    "cannot copy from {} into {}",
                    mod_filename.display(),
                    into_copy_filename.display()
                ),
            );
            diagnostic.init_diag_inner(DiagnosticInner::IoError(io_diag));
            return Err(VesModuleError::FailedGetModule);
        }
    }

    Ok(())
}

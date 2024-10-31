use std::fs::{self, File};
use std::io::{BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::commands::LatexEngineType;
use crate::constants::DEFAULT_COMPILATION_LIMIT;
use crate::error::{self, VestiErr, VestiUtilErrKind};

#[cfg(feature = "tectonic-backend")]
pub fn compile_latex(
    latex_filename: &Path,
    compile_limit: Option<usize>,
    engine_type: LatexEngineType,
) -> error::Result<()> {
    if engine_type == LatexEngineType::Tectonic {
        vesti_tectonic::compile_latex_with_tectonic(latex_filename, compile_limit)
    } else {
        compile_latex_with_local(latex_filename, compile_limit, engine_type)
    }
}

#[cfg(not(feature = "tectonic-backend"))]
pub fn compile_latex(
    latex_filename: &Path,
    compile_limit: Option<usize>,
    engine_type: LatexEngineType,
) -> error::Result<()> {
    compile_latex_with_local(latex_filename, compile_limit, engine_type)
}

fn compile_latex_with_local(
    latex_filename: &Path,
    compile_limit: Option<usize>,
    engine_type: LatexEngineType,
) -> error::Result<()> {
    let mut latex_stdout = BufWriter::new(File::create(format!(
        "./{}.stdout",
        latex_filename.display()
    ))?);
    let mut latex_stderr = BufWriter::new(File::create(format!(
        "./{}.stderr",
        latex_filename.display()
    ))?);

    // It is good to compile latex at least two times
    let compile_limit = compile_limit.unwrap_or(DEFAULT_COMPILATION_LIMIT);
    println!("[Compile {}]", latex_filename.display());
    for i in 0..compile_limit {
        println!("[Compile num {}]", i + 1);
        let output = Command::new(engine_type.to_string())
            .arg(latex_filename)
            .output()?;

        latex_stdout
            .write_all(format!("[Compile Num {}]\n", i + 1).as_bytes())
            .unwrap();
        latex_stdout.write_all(&output.stdout).unwrap();
        latex_stdout.write_all("\n".as_bytes()).unwrap();
        latex_stderr
            .write_all(format!("[Compile Num {}]\n", i + 1).as_bytes())
            .unwrap();
        latex_stderr.write_all(&output.stderr).unwrap();
        latex_stderr.write_all("\n".as_bytes()).unwrap();

        if !output.status.success() {
            return Err(VestiErr::make_util_err(
                VestiUtilErrKind::LatexCompliationErr,
            ));
        }
    }

    let mut pdf_filename: PathBuf = latex_filename.into();
    pdf_filename.set_extension("pdf");
    let final_pdf_filename = PathBuf::from(format!("../{}", pdf_filename.display()));

    let mut generated_pdf_file = File::open(&pdf_filename)?;
    let mut contents = Vec::with_capacity(1000);

    generated_pdf_file.read_to_end(&mut contents)?;
    fs::write(final_pdf_filename, contents)?;

    // close a file before remove it
    drop(generated_pdf_file);
    fs::remove_file(pdf_filename)?;

    println!("[Compile {} Done]", latex_filename.display());

    Ok(())
}

#[cfg(feature = "tectonic-backend")]
mod vesti_tectonic {
    use super::*;

    use std::io::{self, IsTerminal};
    use std::time::SystemTime;

    use tectonic::{
        config, driver,
        status::{self, StatusBackend},
    };

    use crate::constants::VESTI_LOCAL_DUMMY_DIR;

    pub(super) fn compile_latex_with_tectonic(
        latex_filename: &Path,
        compile_limit: Option<usize>,
    ) -> error::Result<()> {
        println!("[Compile {}]", latex_filename.display());

        let mut status: Box<dyn StatusBackend> = if io::stdout().is_terminal() {
            Box::new(status::termcolor::TermcolorStatusBackend::new(
                status::ChatterLevel::Normal,
            ))
        } else {
            Box::<status::NoopStatusBackend>::default()
        };

        let config = config::PersistentConfig::open(true)?;
        let bundle = config.default_bundle(false)?;
        let format_cache_path = config.format_cache_path()?;

        let mut sb = driver::ProcessingSessionBuilder::default();
        sb.bundle(bundle)
            .primary_input_path(&latex_filename)
            .filesystem_root(VESTI_LOCAL_DUMMY_DIR)
            .tex_input_name(&latex_filename.to_string_lossy())
            .format_name("latex")
            .format_cache_path(format_cache_path)
            .keep_logs(false)
            .keep_intermediates(false)
            .print_stdout(true)
            .build_date(SystemTime::now())
            .output_format(driver::OutputFormat::Pdf);

        if let Some(this_many) = compile_limit {
            sb.reruns(this_many);
        }

        let mut sess = sb.create(&mut *status)?;
        sess.run(&mut *status)?;

        let mut pdf_filename: PathBuf = latex_filename.into();
        pdf_filename.set_extension("pdf");
        let final_pdf_filename = PathBuf::from(format!("../{}", pdf_filename.display()));

        let mut generated_pdf_file = File::open(&pdf_filename)?;
        let mut contents = Vec::with_capacity(1000);

        generated_pdf_file.read_to_end(&mut contents)?;
        fs::write(final_pdf_filename, contents)?;

        // close a file before remove it
        drop(generated_pdf_file);
        fs::remove_file(pdf_filename)?;

        println!("[Compile {} Done]", latex_filename.display());

        Ok(())
    }
}

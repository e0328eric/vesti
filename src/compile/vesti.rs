use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use base64ct::{Base64Url, Encoding};
use md5::{Digest, Md5};

use crate::codegen::make_latex_format;
use crate::commands::LatexEngineType;
use crate::compile::VestiFile;
use crate::constants;
use crate::error::{self, VestiErr};
use crate::lexer::Lexer;
use crate::parser::Parser;

pub fn compile_vesti(
    ves_file: &mut VestiFile,
    engine_type: LatexEngineType,
    has_sub_vesti: bool,
    emit_tex_only: bool,
    no_color: bool,
    use_old_bracket: bool,
) -> ExitCode {
    let pretty_print = if no_color {
        crate::error::pretty_print::plain_print
    } else {
        crate::error::pretty_print::pretty_print
    };

    let source = match fs::read_to_string(ves_file.filename) {
        Ok(content) => content,
        Err(err) => {
            pretty_print(
                None,
                VestiErr::from_io_err(
                    err,
                    format!("cannot read from {}", ves_file.filename.display()),
                ),
                Some(ves_file.filename),
            )
            .unwrap();
            return ExitCode::FAILURE;
        }
    };
    let mut parser = Parser::new(Lexer::new(&source), !has_sub_vesti, use_old_bracket);
    let contents = match make_latex_format::<false>(&mut parser, engine_type) {
        Ok(inner) => inner,
        Err(err) => {
            pretty_print(Some(source.as_ref()), err, Some(ves_file.filename)).unwrap();
            return ExitCode::FAILURE;
        }
    };
    let is_main_vesti = parser.is_main_vesti();
    drop(parser);

    let output_filename =
        match compile_vesti_write_file(ves_file.filename, contents, is_main_vesti, emit_tex_only) {
            Ok(name) => name,
            Err(err) => {
                pretty_print(None, err, None).unwrap();
                return ExitCode::FAILURE;
            }
        };

    ves_file.is_main = is_main_vesti;
    ves_file.latex_filename = Some(output_filename);

    ExitCode::SUCCESS
}

fn vesti_name_mangle(filename: &Path) -> error::Result<String> {
    // get the absolute path
    // TODO: fs::canonicalize returns error when there is no such path for
    // `file_path_str`. But vesti's error message is so ambiguous to recognize
    // whether error occurs at here. Make a new error variant to handle this.
    let file_path = match fs::canonicalize(filename) {
        Ok(path) => path,
        Err(err) => {
            return Err(VestiErr::from_io_err(
                err,
                format!(
                    "cannot get the canonicalized name for {}",
                    filename.display()
                ),
            ))
        }
    };

    // name mangling process
    let mut hasher = Md5::new();
    hasher.update(file_path.into_os_string().into_encoded_bytes());
    let hash = hasher.finalize();
    let base64_hash = Base64Url::encode_string(&hash);

    Ok(format!("@vesti__{}.tex", base64_hash))
}

// TODO: integrate all tex files into standalone one if `emit_tex_only` flag is true
fn compile_vesti_write_file(
    filename: &Path,
    contents: String,
    is_main_vesti: bool,
    _emit_tex_only: bool,
) -> error::Result<PathBuf> {
    let output_filename = if !is_main_vesti {
        vesti_name_mangle(filename)?
    } else {
        let tmp = filename.with_extension("tex");
        let Some(raw_filename) = tmp.iter().next_back() else {
            return Err(VestiErr::make_util_err(
                error::VestiUtilErrKind::NoFilenameInputErr,
            ));
        };
        let Some(raw_filename) = raw_filename.to_str() else {
            return Err(VestiErr::make_util_err(
                error::VestiUtilErrKind::NoFilenameInputErr,
            ));
        };

        raw_filename.to_string()
    };

    let output_filename1 = format!("{}/{}", constants::VESTI_LOCAL_DUMMY_DIR, output_filename);
    match fs::write(&output_filename1, contents) {
        Ok(()) => {}
        Err(err) => {
            return Err(VestiErr::from_io_err(
                err,
                format!("cannot write into {output_filename1}"),
            ))
        }
    }

    Ok(PathBuf::from(output_filename))
}

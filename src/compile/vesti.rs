use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc::SyncSender;

use base64ct::{Base64Url, Encoding};
use md5::{Digest, Md5};

use crate::codegen::make_latex_format;
use crate::commands::LatexEngineType;
use crate::constants;
use crate::error::{self, VestiErr};
use crate::exit_status::ExitCode;
use crate::lexer::Lexer;
use crate::parser::Parser;

pub fn compile_vesti(
    main_file_sender: SyncSender<PathBuf>,
    file_name: PathBuf,
    engine_type: LatexEngineType,
    has_sub_vesti: bool,
    emit_tex_only: bool,
    no_color: bool,
    use_old_bracket: bool,
) -> ExitCode {
    let pretty_print = if no_color {
        crate::error::pretty_print::plain_print::<false>
    } else {
        crate::error::pretty_print::pretty_print::<false>
    };

    let source = fs::read_to_string(&file_name).expect("Opening file error occurred!");

    let mut parser = Parser::new(Lexer::new(&source), !has_sub_vesti, use_old_bracket);
    let contents = match make_latex_format::<false>(&mut parser, engine_type) {
        Ok(inner) => inner,
        Err(err) => {
            pretty_print(Some(source.as_ref()), err, Some(&file_name)).unwrap();
            return ExitCode::Failure;
        }
    };
    let is_main_vesti = parser.is_main_vesti();
    drop(parser);

    let output_filename =
        match compile_vesti_write_file(&file_name, contents, is_main_vesti, emit_tex_only) {
            Ok(name) => name,
            Err(err) => {
                pretty_print(None, err, None).unwrap();
                return ExitCode::Failure;
            }
        };

    if is_main_vesti {
        main_file_sender
            .send(output_filename)
            .expect("send failed (compile.rs)");
    }

    ExitCode::Success
}

// TODO: integrate all tex files into standalone one if `emit_tex_only` flag is true
fn compile_vesti_write_file(
    filename: &Path,
    contents: String,
    is_main_vesti: bool,
    _emit_tex_only: bool,
) -> error::Result<PathBuf> {
    let output_filename = if !is_main_vesti {
        // get the absolute path
        // TODO: fs::canonicalize returns error when there is no such path for
        // `file_path_str`. But vesti's error message is so ambiguous to recognize
        // whether error occurs at here. Make a new error variant to handle this.
        let file_path = fs::canonicalize(filename)?;

        // name mangling process
        let mut hasher = Md5::new();
        hasher.update(file_path.into_os_string().into_encoded_bytes());
        let hash = hasher.finalize();
        let base64_hash = Base64Url::encode_string(&hash);

        format!("@vesti__{}.tex", base64_hash)
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

    fs::write(
        format!("{}/{}", constants::VESTI_LOCAL_DUMMY_DIR, output_filename),
        contents,
    )?;

    Ok(PathBuf::from(output_filename))
}

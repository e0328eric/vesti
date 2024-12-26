use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::SystemTime;

use base64ct::{Base64Url, Encoding};
use md5::{Digest, Md5};

use crate::codegen::make_latex_format;
use crate::commands::LatexEngineType;
use crate::constants;
use crate::error::{self, VestiErr};
use crate::lexer::Lexer;
use crate::parser::Parser;

pub fn compile_vesti(
    main_files: &mut Vec<PathBuf>,
    file_name: PathBuf,
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

    let current_time = SystemTime::now();
    let (modified_time, first_time) = 'blk: {
        let mangled_name = match vesti_name_mangle(&file_name) {
            Ok(name) => format!("{}/{}", constants::VESTI_LOCAL_DUMMY_DIR, name),
            Err(err) => {
                pretty_print(None, err, Some(&file_name)).unwrap();
                return ExitCode::FAILURE;
            }
        };
        let metadata = match fs::metadata(&mangled_name) {
            Ok(metadata) => metadata,
            Err(err) => {
                if err.kind() == std::io::ErrorKind::NotFound {
                    break 'blk (SystemTime::now(), true);
                } else {
                    pretty_print(
                        None,
                        VestiErr::from_io_err(
                            err,
                            format!("cannot get the metadata from {mangled_name}"),
                        ),
                        Some(&file_name),
                    )
                    .unwrap();
                    return ExitCode::FAILURE;
                }
            }
        };
        match metadata.modified() {
            Ok(time) => (time, false),
            Err(err) => {
                pretty_print(
                    None,
                    VestiErr::from_io_err(
                        err,
                        format!("cannot get the metadata from {mangled_name}"),
                    ),
                    Some(&file_name),
                )
                .unwrap();
                return ExitCode::FAILURE;
            }
        }
    };
    if !first_time && modified_time <= current_time {
        return ExitCode::SUCCESS;
    }

    let source = fs::read_to_string(&file_name).expect("Opening file error occurred!");
    let mut parser = Parser::new(Lexer::new(&source), !has_sub_vesti, use_old_bracket);
    let contents = match make_latex_format::<false>(&mut parser, engine_type) {
        Ok(inner) => inner,
        Err(err) => {
            pretty_print(Some(source.as_ref()), err, Some(&file_name)).unwrap();
            return ExitCode::FAILURE;
        }
    };
    let is_main_vesti = parser.is_main_vesti();
    drop(parser);

    let output_filename =
        match compile_vesti_write_file(&file_name, contents, is_main_vesti, emit_tex_only) {
            Ok(name) => name,
            Err(err) => {
                pretty_print(None, err, None).unwrap();
                return ExitCode::FAILURE;
            }
        };

    if is_main_vesti {
        main_files.push(output_filename);
    }

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

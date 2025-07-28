use std::env;
use std::io::{self, IsTerminal};
use std::time::SystemTime;

use tectonic::{
    config, driver,
    status::{self, StatusBackend},
};

macro_rules! unwrap {
    ($val: expr) => {
        match $val {
            Ok(val) => val,
            Err(err) => {
                eprintln!("TECTONIC ERROR: {err}");
                return false;
            }
        }
    };
}

#[unsafe(no_mangle)]
extern "C" fn compile_latex_with_tectonic(
    latex_filename_ptr: *const u8,
    latex_filename_len: usize,
    vesti_local_dummy_dir_ptr: *const u8,
    vesti_local_dummy_dir_len: usize,
    compile_limit: usize,
) -> bool {
    let latex_filename = unsafe {
        str::from_utf8_unchecked(std::slice::from_raw_parts(
            latex_filename_ptr,
            latex_filename_len,
        ))
    };
    let vesti_local_dummy_dir = unsafe {
        str::from_utf8_unchecked(std::slice::from_raw_parts(
            vesti_local_dummy_dir_ptr,
            vesti_local_dummy_dir_len,
        ))
    };

    let current_dir = unwrap!(env::current_dir());

    println!("[Compile {}, engine: tectonic]", latex_filename);
    unwrap!(env::set_current_dir(vesti_local_dummy_dir));

    let mut status: Box<dyn StatusBackend> = if io::stdout().is_terminal() {
        Box::new(status::termcolor::TermcolorStatusBackend::new(
            status::ChatterLevel::Normal,
        ))
    } else {
        Box::<status::NoopStatusBackend>::default()
    };

    let config = unwrap!(config::PersistentConfig::open(true));
    let bundle = unwrap!(config.default_bundle(false));
    let format_cache_path = unwrap!(config.format_cache_path());

    let mut sb = driver::ProcessingSessionBuilder::default();
    sb.bundle(bundle)
        .primary_input_path(&latex_filename)
        .filesystem_root(vesti_local_dummy_dir)
        .tex_input_name(&latex_filename.to_string())
        .format_name("latex")
        .format_cache_path(format_cache_path)
        .keep_logs(false)
        .keep_intermediates(false)
        .print_stdout(true)
        .build_date(SystemTime::now())
        .output_format(driver::OutputFormat::Pdf);

    if compile_limit > 0 {
        sb.reruns(compile_limit);
    }

    let mut sess = unwrap!(sb.create(&mut *status));
    unwrap!(sess.run(&mut *status));

    unwrap!(env::set_current_dir(current_dir));
    println!("[Compile {} Done]", latex_filename);

    true
}

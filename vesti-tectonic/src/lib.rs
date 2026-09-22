use std::fs;
use std::io::{self, IsTerminal};
use std::path::Path;
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
                eprintln!("TECTONIC ERROR: {err:#}");
                return false;
            }
        }
    };
}

fn prepare_format_cache(path: &Path) -> io::Result<()> {
    // Tectonic's default cache path may not exist on a first run. Its format
    // writer creates a temporary file there, so it needs the directory first.
    fs::create_dir_all(path)
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

    println!("[Compile {}, engine: tectonic]", latex_filename);

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
    if let Err(err) = prepare_format_cache(&format_cache_path) {
        eprintln!(
            "TECTONIC ERROR: cannot create format cache directory {}: {err}",
            format_cache_path.display()
        );
        return false;
    }

    let mut sb = driver::ProcessingSessionBuilder::default();
    sb.bundle(bundle)
        .primary_input_path(&latex_filename)
        .filesystem_root(vesti_local_dummy_dir)
        .tex_input_name(&latex_filename.to_string())
        .format_name("latex")
        .format_cache_path(format_cache_path)
        .keep_logs(true)
        .keep_intermediates(true)
        .print_stdout(false)
        .build_date(SystemTime::now())
        .output_format(driver::OutputFormat::Pdf);

    if compile_limit > 0 {
        sb.reruns(compile_limit);
    }

    let mut sess = unwrap!(sb.create(&mut *status));

    match sess.run(&mut *status) {
        Ok(()) => {}
        Err(err) => {
            eprintln!("TECTONIC ERROR: {err:#}\nSee logs in {vesti_local_dummy_dir}\n");
            return false;
        }
    }

    println!("[Compile {} Done]", latex_filename);

    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tectonic::io::{DigestData, IoProvider, OpenResult, format_cache::FormatCache};

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            static NEXT_ID: AtomicUsize = AtomicUsize::new(0);
            let timestamp = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "vesti-format-cache-{}-{timestamp}-{}",
                std::process::id(),
                NEXT_ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn cold_format_cache_accepts_and_preserves_tectonic_formats() {
        let directory = TestDirectory::new();
        let path = directory.0.join("cache").join("formats");
        let mut cache = FormatCache::new(DigestData::zeros(), path.clone());
        let mut status = status::NoopStatusBackend::default();
        let data = b"cached format data";

        // Reproduce the first-run failure using Tectonic's real cache writer.
        assert!(cache.write_format("latex", data, &mut status).is_err());
        prepare_format_cache(&path).unwrap();
        cache.write_format("latex", data, &mut status).unwrap();

        // Preparing an existing cache must retain the format for subsequent runs.
        prepare_format_cache(&path).unwrap();
        let OpenResult::Ok(mut input) = cache.input_open_format("latex", &mut status) else {
            panic!("the cached format should remain readable");
        };
        let mut actual = Vec::new();
        input.read_to_end(&mut actual).unwrap();
        assert_eq!(actual, data);
    }

    #[test]
    fn format_cache_rejects_a_file_without_overwriting_it() {
        let directory = TestDirectory::new();
        let path = directory.0.join("formats");
        fs::write(&path, b"existing file").unwrap();

        assert!(prepare_format_cache(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"existing file");
    }
}

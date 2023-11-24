#[macro_export]
macro_rules! try_catch {
    (io_handle: $to_handle: expr, $val: pat, $success: expr) => {
        match $to_handle {
            Ok($val) => $success,
            Err(err) => {
                pretty_print::<false>(None, err.into(), None).unwrap();
                return ExitCode::Failure;
            }
        }
    };
    (io_handle: $to_handle: expr) => {
        match $to_handle {
            Ok(_) => {}
            Err(err) => {
                pretty_print::<false>(None, err.into(), None).unwrap();
                return ExitCode::Failure;
            }
        }
    };
    ($to_handle: expr, $val: pat, $success: expr) => {
        match $to_handle {
            Ok($val) => $success,
            Err(err) => {
                pretty_print::<false>(None, err, None).unwrap();
                return ExitCode::Failure;
            }
        }
    };
}

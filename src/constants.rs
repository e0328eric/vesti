pub const VESTI_LOCAL_DUMMY_DIR: &str = "./.vesti-dummy";

pub const DEFAULT_COMPILATION_LIMIT: usize = 2;

// specific error messages
pub const ILLEGAL_USAGE_OF_SUPERSUB_SCRIPT: &str = r#"wrap the whole expression that uses this
symbol using math related warppers like
`$`, `\(`, `\)`, `\[`, `\]` or `defun` like blocks"#;

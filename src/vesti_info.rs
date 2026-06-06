/// Directory name where vesti writes generated `.tex` files and intermediate
/// build artifacts.
pub const VESTI_DUMMY_DIR: &str = "./.vesti-dummy";

/// vesti version string, taken from `Cargo.toml`.
pub const VESTI_VERSION: &str = env!("CARGO_PKG_VERSION");

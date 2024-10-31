use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct VestiModule {
    pub name: String,
    pub version: Option<String>,
    pub exports: Vec<String>,
}

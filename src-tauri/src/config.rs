use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub hotkey: String,
    pub start_at_login: bool,
    pub num_threads: i32,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            hotkey: "F9".into(),
            start_at_login: true,
            num_threads: 4,
        }
    }
}

impl Config {
    pub fn load() -> Self {
        if let Some(dir) = dirs::config_dir() {
            let path = dir.join("talkist/config.json");
            if let Ok(s) = std::fs::read_to_string(&path) {
                match serde_json::from_str(&s) {
                    Ok(c) => return c,
                    Err(e) => eprintln!("config parse error ({}), using defaults", e),
                }
            }
        }
        Self::default()
    }

    pub fn save(&self) -> anyhow::Result<()> {
        let dir = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
        let dir = dir.join("talkist");
        std::fs::create_dir_all(&dir)?;
        std::fs::write(dir.join("config.json"), serde_json::to_vec_pretty(self)?)?;
        Ok(())
    }
}

pub fn model_dir() -> Option<PathBuf> {
    if let Some(d) = std::env::var_os("PARAKEET_MODEL_DIR") {
        return Some(PathBuf::from(d));
    }
    dirs::data_dir().map(|d| {
        d.join("talkist/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8")
    })
}

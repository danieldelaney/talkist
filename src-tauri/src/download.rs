// First-run model download. The app isn't usable (or "installed") until the
// speech model is on disk, so a missing model opens a small window that
// shows download/extraction progress and closes itself when ready.
use anyhow::{anyhow, Context, Result};
use std::io::{BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Emitter, WebviewUrl, WebviewWindowBuilder};

const MODEL_URL: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2";
const MODEL_SHA256: &str = "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad";

pub fn model_ready(dir: &Path) -> bool {
    has_size(dir, "encoder.int8.onnx", 500 * 1024 * 1024)
        && has_size(dir, "decoder.int8.onnx", 1024 * 1024)
        && has_size(dir, "joiner.int8.onnx", 512 * 1024)
        && has_size(dir, "tokens.txt", 1024)
}

pub fn install_model(app: &AppHandle, dir: PathBuf) {
    WebviewWindowBuilder::new(app, "setup", WebviewUrl::App("index.html".into()))
        .inner_size(400.0, 120.0)
        .min_inner_size(400.0, 120.0)
        .max_inner_size(400.0, 120.0)
        .resizable(false)
        .decorations(false)
        .center()
        .build()
        .expect("failed to open setup window");

    let handle = app.clone();
    std::thread::spawn(move || {
        match run_download(&handle, &dir) {
            Ok(()) => {
                handle.restart();
            }
            Err(e) => {
                eprintln!("model download failed: {e:#}");
                let _ = handle.emit("model-error", format!("{e:#}"));
            }
        }
    });
}

fn run_download(app: &AppHandle, dir: &Path) -> Result<()> {
    let custom_url = std::env::var("PARAKEET_MODEL_URL").ok();
    let url = custom_url.clone().unwrap_or_else(|| MODEL_URL.to_string());
    let expected_sha = std::env::var("PARAKEET_MODEL_SHA256")
        .ok()
        .or_else(|| custom_url.is_none().then(|| MODEL_SHA256.to_string()));
    let data_dir = dir.parent().context("model dir has no parent")?;
    std::fs::create_dir_all(data_dir)?;
    let archive = data_dir.join("model.tar.bz2");

    let resp = ureq::get(&url).call().map_err(|e| anyhow!("download failed: {e}"))?;
    let total: usize = resp
        .header("Content-Length")
        .and_then(|h| h.parse().ok())
        .unwrap_or(0);
    let mut reader = resp.into_reader();
    let mut file = BufWriter::new(std::fs::File::create(&archive)?);
    let mut buf = [0u8; 64 * 1024];
    let mut written: usize = 0;
    let mut last_pct: i64 = -1;
    let mut hasher = Sha256::new();
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])?;
        hasher.update(&buf[..n]);
        written += n;
        if total > 0 {
            let pct = (written as i64 * 100) / total as i64;
            if pct != last_pct {
                last_pct = pct;
                let _ = app.emit("model-progress", pct);
            }
        }
    }
    file.flush()?;

    if let Some(expected) = expected_sha {
        let actual = format!("{:x}", hasher.finalize());
        if actual != expected {
            let _ = std::fs::remove_file(&archive);
            return Err(anyhow!("downloaded model failed its checksum"));
        }
    }
    let _ = app.emit("model-install", ());

    if dir.exists() {
        std::fs::remove_dir_all(dir)?;
    }
    let status = std::process::Command::new("tar")
        .args(["-xjf", &archive.display().to_string(), "-C", &data_dir.display().to_string()])
        .status()
        .context("failed to run tar")?;
    if !status.success() {
        return Err(anyhow!("model extraction failed"));
    }
    let _ = std::fs::remove_file(&archive);
    if !model_ready(dir) {
        return Err(anyhow!("archive did not contain the expected model files"));
    }
    Ok(())
}

fn has_size(dir: &Path, name: &str, minimum: u64) -> bool {
    dir.join(name)
        .metadata()
        .map(|m| m.is_file() && m.len() >= minimum)
        .unwrap_or(false)
}

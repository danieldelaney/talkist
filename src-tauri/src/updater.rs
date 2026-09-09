use anyhow::{anyhow, Context, Result};
use minisign_verify::{PublicKey, Signature};
use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::{BufWriter, Read, Write};
use std::process::{Command, Stdio};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};

const MANIFEST_URL: &str = "https://github.com/danieldelaney/talkist/releases/latest/download/update.json";
const SIGNATURE_URL: &str = "https://github.com/danieldelaney/talkist/releases/latest/download/update.json.minisig";
const PUBLIC_KEY: &str = "RWTQDdQS8ZXehztOCrKTWpM0dKGPzAUzfLlMJ7lZNEhWS0VPSqNuf+UW";

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateManifest {
    pub version: String,
    pub package: String,
    pub architecture: String,
    pub url: String,
    pub size: u64,
    pub sha256: String,
}

#[derive(Clone, Serialize)]
pub struct UpdateAvailable {
    pub version: String,
}

pub fn spawn_checks(app: AppHandle) {
    std::thread::spawn(move || loop {
        if let Ok(Some(update)) = check() {
            *app.state::<crate::AppState>().update.lock().unwrap() = Some(update.clone());
            let _ = app.emit_to(
                "settings",
                "update-available",
                UpdateAvailable { version: update.version },
            );
        }
        std::thread::sleep(Duration::from_secs(24 * 60 * 60));
    });
}

fn check() -> Result<Option<UpdateManifest>> {
    let manifest_bytes = fetch_small(MANIFEST_URL, 64 * 1024)?;
    let signature_text = String::from_utf8(fetch_small(SIGNATURE_URL, 16 * 1024)?)?;
    let key = PublicKey::from_base64(PUBLIC_KEY).map_err(|e| anyhow!("invalid update key: {e}"))?;
    let signature = Signature::decode(&signature_text).map_err(|e| anyhow!("invalid signature: {e}"))?;
    key.verify(&manifest_bytes, &signature, false)
        .map_err(|e| anyhow!("update signature failed: {e}"))?;

    let manifest: UpdateManifest = serde_json::from_slice(&manifest_bytes)?;
    if manifest.package != "talkist" || manifest.architecture != "amd64" {
        return Err(anyhow!("update manifest targets another package"));
    }
    if !manifest.url.starts_with("https://github.com/danieldelaney/talkist/releases/download/") {
        return Err(anyhow!("update manifest has an unexpected URL"));
    }
    let available = Version::parse(&manifest.version)?;
    let current = Version::parse(env!("CARGO_PKG_VERSION"))?;
    Ok((available > current).then_some(manifest))
}

fn fetch_small(url: &str, limit: usize) -> Result<Vec<u8>> {
    let response = ureq::get(url).timeout(Duration::from_secs(10)).call()?;
    let mut bytes = Vec::new();
    response.into_reader().take((limit + 1) as u64).read_to_end(&mut bytes)?;
    if bytes.len() > limit { return Err(anyhow!("update metadata is too large")); }
    Ok(bytes)
}

#[tauri::command]
pub fn install_update(app: AppHandle, state: tauri::State<'_, crate::AppState>) -> Result<(), String> {
    let manifest = state.update.lock().unwrap().clone().ok_or("no update is available")?;
    std::thread::spawn(move || {
        if let Err(error) = download_and_install(&app, &manifest) {
            let _ = app.emit_to("settings", "update-error", error.to_string());
        }
    });
    Ok(())
}

fn download_and_install(app: &AppHandle, manifest: &UpdateManifest) -> Result<()> {
    let dir = dirs::cache_dir().context("cannot find cache directory")?.join("talkist");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("talkist_{}_amd64.deb", manifest.version));
    let response = ureq::get(&manifest.url).timeout(Duration::from_secs(30)).call()?;
    let mut reader = response.into_reader();
    let mut file = BufWriter::new(std::fs::File::create(&path)?);
    let mut hasher = Sha256::new();
    let mut written = 0u64;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let n = reader.read(&mut buffer)?;
        if n == 0 { break; }
        written += n as u64;
        if written > manifest.size { return Err(anyhow!("update exceeded expected size")); }
        file.write_all(&buffer[..n])?;
        hasher.update(&buffer[..n]);
        let _ = app.emit_to("settings", "update-progress", (written * 100 / manifest.size) as u8);
    }
    file.flush()?;
    if written != manifest.size || format!("{:x}", hasher.finalize()) != manifest.sha256 {
        let _ = std::fs::remove_file(&path);
        return Err(anyhow!("downloaded update failed verification"));
    }
    verify_deb(&path, manifest)?;
    let _ = app.emit_to("settings", "update-installing", ());
    let mut child = Command::new("/usr/bin/pkcon")
        .args(["--allow-untrusted", "install-local"])
        .arg(&path)
        .stdin(Stdio::piped())
        .spawn()
        .context("PackageKit is unavailable")?;
    child.stdin.take().context("PackageKit input unavailable")?.write_all(b"y\n")?;
    let status = child.wait()?;
    if !status.success() { return Err(anyhow!("PackageKit did not install the update")); }
    let installed = Command::new("dpkg-query")
        .args(["-W", "-f=${Version}", "talkist"])
        .output()?;
    if String::from_utf8_lossy(&installed.stdout).trim() != manifest.version {
        return Err(anyhow!("installed version could not be verified"));
    }
    let _ = std::fs::remove_file(path);
    app.restart();
}

fn verify_deb(path: &std::path::Path, manifest: &UpdateManifest) -> Result<()> {
    for (field, expected) in [
        ("Package", manifest.package.as_str()),
        ("Version", manifest.version.as_str()),
        ("Architecture", manifest.architecture.as_str()),
    ] {
        let output = Command::new("dpkg-deb").args(["--field"]).arg(path).arg(field).output()?;
        if !output.status.success() || String::from_utf8_lossy(&output.stdout).trim() != expected {
            return Err(anyhow!("update has incorrect {field}"));
        }
    }
    Ok(())
}

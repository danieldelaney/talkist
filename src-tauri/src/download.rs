// Speech model readiness check, download, verification, and extraction.
use anyhow::{anyhow, Context, Result};
use sha2::{Digest, Sha256};
use std::io::{BufWriter, ErrorKind, Read, Write};
use std::path::Path;

const MODEL_URL: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2";
const MODEL_SHA256: &str = "1495e91b59d7fc53ddca91f3431758ec99f8fa253fdb0e1e851be0f72b14b0f9";

pub fn model_ready(dir: &Path) -> bool {
    has_size(dir, "encoder.int8.onnx", 500 * 1024 * 1024)
        && has_size(dir, "decoder.int8.onnx", 1024 * 1024)
        && has_size(dir, "joiner.int8.onnx", 512 * 1024)
        && has_size(dir, "tokens.txt", 1024)
}

/// Downloads, verifies, and extracts the speech model synchronously on the
/// calling thread. `on_progress` fires with percentages 0..=100; `on_stage`
/// fires for post-download phases (verifying / extracting).
pub fn download_and_extract<FProg, FStage>(
    dir: &Path,
    mut on_progress: FProg,
    mut on_stage: FStage,
) -> Result<()>
where
    FProg: FnMut(u8),
    FStage: FnMut(&str),
{
    let custom_url = std::env::var("PARAKEET_MODEL_URL").ok();
    let url = custom_url.clone().unwrap_or_else(|| MODEL_URL.to_string());
    let expected_sha = std::env::var("PARAKEET_MODEL_SHA256")
        .ok()
        .or_else(|| custom_url.is_none().then(|| MODEL_SHA256.to_string()));
    let data_dir = dir.parent().context("model dir has no parent")?;
    std::fs::create_dir_all(data_dir)?;
    let archive = data_dir.join("model.tar.bz2");
    let _ = std::fs::remove_file(&archive);

    let resp = ureq::get(&url)
        .call()
        .map_err(|e| anyhow!("download failed: {e}"))?;
    let total: u64 = resp
        .header("Content-Length")
        .and_then(|h| h.parse().ok())
        .unwrap_or(0);
    let mut reader = resp.into_reader();
    let mut file = BufWriter::new(std::fs::File::create(&archive)?);
    let mut buf = [0u8; 64 * 1024];
    let mut written: u64 = 0;
    let mut last_pct: i64 = -1;
    let mut hasher = Sha256::new();

    let read_result: Result<()> = (|| {
        loop {
            let n = reader.read(&mut buf)?;
            if n == 0 {
                break;
            }
            file.write_all(&buf[..n])?;
            hasher.update(&buf[..n]);
            written += n as u64;
            if total > 0 {
                let pct = ((written * 100) / total).min(100) as i64;
                if pct != last_pct {
                    last_pct = pct;
                    on_progress(pct as u8);
                }
            }
        }
        file.flush()?;
        Ok(())
    })();

    if let Err(e) = read_result {
        drop(file);
        let _ = std::fs::remove_file(&archive);
        return Err(e);
    }
    drop(file);

    // ureq's reader can end early without erroring when the connection
    // drops mid-stream, so a short transfer must not reach the hash check.
    if total > 0 && written != total {
        let _ = std::fs::remove_file(&archive);
        return Err(anyhow!(
            "download incomplete: got {written} of {total} bytes"
        ));
    }

    on_stage("Verifying speech model…");
    if let Some(expected) = expected_sha {
        let actual = format!("{:x}", hasher.finalize());
        if actual != expected {
            let _ = std::fs::remove_file(&archive);
            return Err(anyhow!("downloaded model failed its checksum"));
        }
    }

    on_stage("Extracting speech model…");
    if dir.exists() {
        std::fs::remove_dir_all(dir)?;
    }
    let status = std::process::Command::new("tar")
        .args([
            "-xjf",
            &archive.display().to_string(),
            "-C",
            &data_dir.display().to_string(),
        ])
        .status()
        .context("failed to run tar")?;
    let _ = std::fs::remove_file(&archive);
    if !status.success() {
        return Err(anyhow!("model extraction failed"));
    }
    if !model_ready(dir) {
        return Err(anyhow!("archive did not contain the expected model files"));
    }
    Ok(())
}

/// Condenses a model download/extraction error into a short UI-friendly label.
pub fn short_error(err: &anyhow::Error) -> String {
    for cause in err.chain() {
        if let Some(io_err) = cause.downcast_ref::<std::io::Error>() {
            if io_err.kind() == ErrorKind::TimedOut {
                return "Download timed out".into();
            }
            if io_err.raw_os_error() == Some(28) {
                return "Disk full".into();
            }
        }
    }

    let full = format!("{err:#}");
    let lower = full.to_ascii_lowercase();
    if lower.contains("checksum") {
        return "Checksum mismatch".into();
    }
    if lower.contains("extraction failed") || lower.contains("failed to run tar") {
        return "Extract failed".into();
    }
    if lower.contains("expected model files") || lower.contains("download incomplete") {
        return "Incomplete model".into();
    }
    if lower.contains("no space left") || lower.contains("disk full") {
        return "Disk full".into();
    }
    if lower.contains("timed out") || lower.contains("timeout") {
        return "Download timed out".into();
    }
    if lower.contains("network is unreachable")
        || lower.contains("no route to host")
        || lower.contains("temporary failure in name resolution")
    {
        return "Offline".into();
    }
    if lower.contains("dns")
        || lower.contains("failed to lookup")
        || lower.contains("connection refused")
        || lower.contains("cannot connect")
        || lower.contains("connect:")
    {
        return "Can’t reach server".into();
    }

    let first = full.lines().next().unwrap_or(&full).trim();
    if first.chars().count() > 44 {
        let prefix: String = first.chars().take(43).collect();
        format!("{prefix}…")
    } else {
        first.to_string()
    }
}

fn has_size(dir: &Path, name: &str, minimum: u64) -> bool {
    dir.join(name)
        .metadata()
        .map(|m| m.is_file() && m.len() >= minimum)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::short_error;
    use anyhow::anyhow;

    #[test]
    fn maps_common_errors() {
        assert_eq!(
            short_error(&anyhow!("downloaded model failed its checksum")),
            "Checksum mismatch"
        );
        assert_eq!(
            short_error(&anyhow!("model extraction failed")),
            "Extract failed"
        );
        assert_eq!(
            short_error(&anyhow!("archive did not contain the expected model files")),
            "Incomplete model"
        );
        assert_eq!(
            short_error(&anyhow!("download failed: Network is unreachable")),
            "Offline"
        );
        assert_eq!(
            short_error(&anyhow!("download failed: timed out reading body")),
            "Download timed out"
        );
        assert_eq!(
            short_error(&anyhow::Error::new(std::io::Error::from_raw_os_error(28))),
            "Disk full"
        );
    }
}

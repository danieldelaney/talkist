use anyhow::{anyhow, Context, Result};
use minisign_verify::{PublicKey, Signature};
use semver::Version;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::io::{BufWriter, Read, Write};
use std::process::Command;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tauri::{AppHandle, Manager};

const DEB_MANIFEST_URL: &str =
    "https://github.com/danieldelaney/talkist/releases/latest/download/update.json";
const DEB_SIGNATURE_URL: &str =
    "https://github.com/danieldelaney/talkist/releases/latest/download/update.json.minisig";
const DEB_ARM64_MANIFEST_URL: &str =
    "https://github.com/danieldelaney/talkist/releases/latest/download/update-arm64.json";
const DEB_ARM64_SIGNATURE_URL: &str =
    "https://github.com/danieldelaney/talkist/releases/latest/download/update-arm64.json.minisig";
const RPM_X86_64_MANIFEST_URL: &str =
    "https://github.com/danieldelaney/talkist/releases/latest/download/update-rpm.json";
const RPM_X86_64_SIGNATURE_URL: &str =
    "https://github.com/danieldelaney/talkist/releases/latest/download/update-rpm.json.minisig";
const RPM_AARCH64_MANIFEST_URL: &str =
    "https://github.com/danieldelaney/talkist/releases/latest/download/update-rpm-aarch64.json";
const RPM_AARCH64_SIGNATURE_URL: &str =
    "https://github.com/danieldelaney/talkist/releases/latest/download/update-rpm-aarch64.json.minisig";
const PUBLIC_KEY: &str = "RWTQDdQS8ZXehztOCrKTWpM0dKGPzAUzfLlMJ7lZNEhWS0VPSqNuf+UW";

/// Native package format of the host. Chooses which update manifest is
/// fetched and which artifacts install_update accepts.
#[derive(Clone, Copy, PartialEq)]
enum PackageFormat {
    Deb,
    Rpm,
}

impl PackageFormat {
    fn manifest_url(self) -> &'static str {
        match (self, std::env::consts::ARCH) {
            (PackageFormat::Deb, "aarch64") => DEB_ARM64_MANIFEST_URL,
            (PackageFormat::Deb, _) => DEB_MANIFEST_URL,
            (PackageFormat::Rpm, "aarch64") => RPM_AARCH64_MANIFEST_URL,
            (PackageFormat::Rpm, _) => RPM_X86_64_MANIFEST_URL,
        }
    }

    fn signature_url(self) -> &'static str {
        match (self, std::env::consts::ARCH) {
            (PackageFormat::Deb, "aarch64") => DEB_ARM64_SIGNATURE_URL,
            (PackageFormat::Deb, _) => DEB_SIGNATURE_URL,
            (PackageFormat::Rpm, "aarch64") => RPM_AARCH64_SIGNATURE_URL,
            (PackageFormat::Rpm, _) => RPM_X86_64_SIGNATURE_URL,
        }
    }

    /// Architecture string the release manifests use for this format.
    fn architecture(self) -> &'static str {
        match (self, std::env::consts::ARCH) {
            (PackageFormat::Deb, "x86_64") => "amd64",
            (PackageFormat::Deb, "aarch64") => "arm64",
            (PackageFormat::Deb, other) => other,
            (PackageFormat::Rpm, other) => other,
        }
    }
}

fn host_format() -> PackageFormat {
    // Prefer the package manager that owns the installed copy, then fall
    // back to whichever package manager the system runs.
    let installed_with_rpm = Command::new("rpm")
        .args(["-q", "--qf", "%{VERSION}", "talkist"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if installed_with_rpm {
        return PackageFormat::Rpm;
    }
    let installed_with_deb = Command::new("dpkg-query")
        .args(["-W", "-f=${Version}", "talkist"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if installed_with_deb {
        return PackageFormat::Deb;
    }
    if std::path::Path::new("/usr/bin/dpkg").exists() {
        PackageFormat::Deb
    } else {
        PackageFormat::Rpm
    }
}

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

pub fn spawn_checks(app: AppHandle) {
    // Inside Flatpak, updates are managed by Flatpak / Flathub / GNOME Software
    // rather than PackageKit.
    if crate::portal::is_flatpak() {
        return;
    }
    std::thread::spawn(move || loop {
        if let Ok(Some(update)) = check() {
            let version = update.version.clone();
            *app.state::<crate::AppState>().update.lock().unwrap() = Some(update);
            crate::show_tray_update(&app, &version);
        }
        std::thread::sleep(Duration::from_secs(24 * 60 * 60));
    });
}

fn check() -> Result<Option<UpdateManifest>> {
    let format = host_format();
    let (manifest_url, signature_url) = match std::env::var("TALKIST_UPDATE_MANIFEST_URL")
        .ok()
        .filter(|s| !s.is_empty())
    {
        Some(url) => {
            let sig = format!("{url}.minisig");
            (url, sig)
        }
        None => (
            format.manifest_url().to_string(),
            format.signature_url().to_string(),
        ),
    };
    let manifest_bytes = fetch_small(&manifest_url, 64 * 1024)?;
    let signature_text = String::from_utf8(fetch_small(&signature_url, 16 * 1024)?)?;
    let key = PublicKey::from_base64(PUBLIC_KEY).map_err(|e| anyhow!("invalid update key: {e}"))?;
    let signature = Signature::decode(&signature_text).map_err(|e| anyhow!("invalid signature: {e}"))?;
    key.verify(&manifest_bytes, &signature, false)
        .map_err(|e| anyhow!("update signature failed: {e}"))?;

    let manifest: UpdateManifest = serde_json::from_slice(&manifest_bytes)?;
    if manifest.package != "talkist" || manifest.architecture != format.architecture() {
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

pub fn start_install(app: AppHandle) {
    let state = app.state::<crate::AppState>();
    let Some(manifest) = state.update.lock().unwrap().clone() else { return };
    if state.updating.swap(true, Ordering::Relaxed) {
        return;
    }
    crate::set_tray_update_status(&app, "Downloading 0%", false);
    std::thread::spawn(move || {
        if let Err(error) = download_and_install(&app, &manifest) {
            eprintln!("update failed: {error:#}");
            app.state::<crate::AppState>().updating.store(false, Ordering::Relaxed);
            crate::set_tray_update_status(
                &app,
                &format!("Update to {} (retry)", manifest.version),
                true,
            );
        }
    });
}

fn download_and_install(app: &AppHandle, manifest: &UpdateManifest) -> Result<()> {
    let format = manifest_format(manifest);
    let dir = dirs::cache_dir().context("cannot find cache directory")?.join("talkist");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(match format {
        PackageFormat::Deb => format!("talkist_{}_{}.deb", manifest.version, manifest.architecture),
        PackageFormat::Rpm => format!("talkist-{}-1.{}.rpm", manifest.version, manifest.architecture),
    });
    let response = ureq::get(&manifest.url).timeout(Duration::from_secs(30)).call()?;
    let mut reader = response.into_reader();
    let mut file = BufWriter::new(std::fs::File::create(&path)?);
    let mut hasher = Sha256::new();
    let mut written = 0u64;
    let mut last_pct: i64 = -1;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let n = reader.read(&mut buffer)?;
        if n == 0 { break; }
        written += n as u64;
        if written > manifest.size { return Err(anyhow!("update exceeded expected size")); }
        file.write_all(&buffer[..n])?;
        hasher.update(&buffer[..n]);
        if manifest.size > 0 {
            let pct = (written * 100 / manifest.size) as i64;
            if pct != last_pct {
                last_pct = pct;
                crate::set_tray_update_status(app, &format!("Downloading {pct}%"), false);
            }
        }
    }
    file.flush()?;
    if written != manifest.size || format!("{:x}", hasher.finalize()) != manifest.sha256 {
        let _ = std::fs::remove_file(&path);
        return Err(anyhow!("downloaded update failed verification"));
    }
    verify_package(&path, manifest, format)?;
    crate::set_tray_update_status(app, "Installing...", false);
    install_with_packagekit(&path)?;
    let installed = match format {
        PackageFormat::Deb => Command::new("dpkg-query")
            .args(["-W", "-f=${Version}", "talkist"])
            .output()?,
        PackageFormat::Rpm => Command::new("rpm")
            .args(["-q", "--qf", "%{VERSION}", "talkist"])
            .output()?,
    };
    if String::from_utf8_lossy(&installed.stdout).trim() != manifest.version {
        return Err(anyhow!("installed version could not be verified"));
    }
    let _ = std::fs::remove_file(path);
    app.restart();
}

fn manifest_format(manifest: &UpdateManifest) -> PackageFormat {
    // Trust the artifact the manifest points at over host detection so the
    // downloaded file, its verification, and the post-install check agree.
    if manifest.url.ends_with(".rpm") {
        PackageFormat::Rpm
    } else {
        PackageFormat::Deb
    }
}

fn verify_package(path: &std::path::Path, manifest: &UpdateManifest, format: PackageFormat) -> Result<()> {
    match format {
        PackageFormat::Deb => verify_deb(path, manifest),
        PackageFormat::Rpm => verify_rpm(path, manifest),
    }
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

fn verify_rpm(path: &std::path::Path, manifest: &UpdateManifest) -> Result<()> {
    let output = Command::new("rpm")
        .args(["-qp", "--qf", "%{NAME} %{VERSION} %{ARCH}"])
        .arg(path)
        .output()?;
    let expected = format!("{} {} {}", manifest.package, manifest.version, manifest.architecture);
    if !output.status.success() || String::from_utf8_lossy(&output.stdout).trim() != expected {
        return Err(anyhow!("update has incorrect rpm metadata"));
    }
    Ok(())
}

/// Install a local `.deb` or `.rpm` via PackageKit's D-Bus API with
/// `interactive=true` so Polkit triggers the desktop's graphical password
/// prompt (unlike `pkcon -y` / `--noninteractive`, which disables Polkit
/// interaction and immediately fails auth).
#[cfg(target_os = "linux")]
fn install_with_packagekit(path: &std::path::Path) -> Result<()> {
    use futures_util::future::{select, Either};
    use futures_util::StreamExt;
    use zbus::proxy;
    use zbus::zvariant::OwnedObjectPath;

    const PK_EXIT_SUCCESS: u32 = 1;
    const PK_TRANSACTION_FLAG_NONE: u64 = 0;

    #[proxy(
        interface = "org.freedesktop.PackageKit",
        default_service = "org.freedesktop.PackageKit",
        default_path = "/org/freedesktop/PackageKit"
    )]
    trait PackageKit {
        fn create_transaction(&self) -> zbus::Result<OwnedObjectPath>;
    }

    #[proxy(
        interface = "org.freedesktop.PackageKit.Transaction",
        default_service = "org.freedesktop.PackageKit"
    )]
    trait PackageKitTransaction {
        fn set_hints(&self, hints: &[&str]) -> zbus::Result<()>;
        fn install_files(&self, transaction_flags: u64, full_paths: &[&str]) -> zbus::Result<()>;

        #[zbus(signal)]
        fn error_code(&self, code: u32, details: String) -> zbus::Result<()>;

        #[zbus(signal)]
        fn finished(&self, exit: u32, runtime: u32) -> zbus::Result<()>;
    }

    let path_str = path
        .to_str()
        .context("update package path is not valid UTF-8")?;

    async_io::block_on(async {
        let conn = zbus::Connection::system()
            .await
            .context("cannot connect to system bus for PackageKit")?;
        let pk = PackageKitProxy::new(&conn)
            .await
            .context("PackageKit is unavailable")?;
        let tx_path = pk
            .create_transaction()
            .await
            .context("PackageKit CreateTransaction failed")?;
        let tx = PackageKitTransactionProxy::builder(&conn)
            .path(tx_path)?
            .build()
            .await?;

        tx.set_hints(&["interactive=true"])
            .await
            .context("PackageKit SetHints failed")?;

        let mut errors = tx.receive_error_code().await?;
        let mut finished = tx.receive_finished().await?;

        tx.install_files(PK_TRANSACTION_FLAG_NONE, &[path_str])
            .await
            .context("PackageKit InstallFiles failed")?;

        let mut last_error: Option<(u32, String)> = None;
        loop {
            match select(Box::pin(finished.next()), Box::pin(errors.next())).await {
                Either::Left((Some(sig), _)) => {
                    let args = sig.args()?;
                    if args.exit == PK_EXIT_SUCCESS {
                        return Ok(());
                    }
                    if let Some((code, details)) = last_error {
                        return Err(anyhow!(
                            "PackageKit install failed (exit {}, error {code}): {details}",
                            args.exit
                        ));
                    }
                    return Err(anyhow!(
                        "PackageKit did not install the update (exit {})",
                        args.exit
                    ));
                }
                Either::Left((None, _)) => {
                    return Err(anyhow!("PackageKit transaction stream ended unexpectedly"));
                }
                Either::Right((Some(sig), _)) => {
                    if let Ok(args) = sig.args() {
                        eprintln!("PackageKit error {}: {}", args.code, args.details);
                        last_error = Some((args.code, args.details));
                    }
                }
                Either::Right((None, _)) => {
                    if let Some(sig) = finished.next().await {
                        let args = sig.args()?;
                        if args.exit == PK_EXIT_SUCCESS {
                            return Ok(());
                        }
                        if let Some((code, details)) = last_error {
                            return Err(anyhow!(
                                "PackageKit install failed (exit {}, error {code}): {details}",
                                args.exit
                            ));
                        }
                        return Err(anyhow!(
                            "PackageKit did not install the update (exit {})",
                            args.exit
                        ));
                    }
                    return Err(anyhow!("PackageKit transaction stream ended unexpectedly"));
                }
            }
        }
    })
}

#[cfg(not(target_os = "linux"))]
fn install_with_packagekit(_path: &std::path::Path) -> Result<()> {
    Err(anyhow!("PackageKit is only available on Linux"))
}

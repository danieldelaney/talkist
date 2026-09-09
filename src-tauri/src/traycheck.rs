// GNOME Shell (unlike KDE/Windows/macOS) doesn't display tray icons without
// an AppIndicator extension. If this app would end up tray-less, fix it:
// silently enable an installed extension, or ask GNOME Shell to install one
// (the shell shows its own approval prompt — that is the user-facing UI).
use std::process::Command;
use std::thread::sleep;
use std::time::Duration;

const UUIDS: &[&str] = &[
    "appindicatorsupport@rgcjonas.gmail.com",
    "ubuntu-appindicators@ubuntu.com",
];

const INSTALL_UUID: &str = "appindicatorsupport@rgcjonas.gmail.com";

pub fn ensure_tray_support() {
    let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
    if !desktop.contains("GNOME") || watcher_present() {
        return;
    }

    // An installed-but-disabled extension loads live when enabled.
    for uuid in UUIDS {
        if extension_known(uuid) {
            let _ = Command::new("gnome-extensions")
                .args(["enable", uuid])
                .output();
            sleep(Duration::from_millis(500));
            if watcher_present() {
                return;
            }
        }
    }

    // Nothing installed: ask the shell to install it. The method replies
    // asynchronously (DBus NoReply is normal); the user sees GNOME's own
    // install prompt and the extension hot-loads on approval.
    let _ = Command::new("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            "org.gnome.Shell.Extensions",
            "--object-path",
            "/org/gnome/Shell/Extensions",
            "--method",
            "org.gnome.Shell.Extensions.InstallRemoteExtension",
            INSTALL_UUID,
        ])
        .output();
}

fn watcher_present() -> bool {
    Command::new("busctl")
        .args(["--user", "list"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("StatusNotifierWatcher"))
        .unwrap_or(false)
}

fn extension_known(uuid: &str) -> bool {
    Command::new("gnome-extensions")
        .args(["info", uuid])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

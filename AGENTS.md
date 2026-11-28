# Talkist — Agent Guidelines

## Release & Git hygiene
- Follow [RELEASING.md](RELEASING.md) for every release.
- **Never publish a release directly as `--latest`.** [release.yml](.github/workflows/release.yml) creates `--prerelease` for `v*-*` tags and `--draft` for stable `v*` tags; promotion to **Latest** is always a manual step after testing the actual packaged artifacts.
- Do not cut back-to-back public tags to debug packaging or updater issues — test locally or with a prerelease tag + `TALKIST_UPDATE_MANIFEST_URL`.
- **Keep the public repo clean:**
  - Do WIP/debugging locally or on a branch; only push clean, tested commits to `main` (squash noisy commits before merging).
  - Delete `-rc` prereleases and their tags once the corresponding stable release is promoted, and prune any broken/superseded releases so the public Releases page stays tidy.

## Platform architecture & gotchas
- **macOS (`macos/`)** is native Swift/AppKit/SwiftUI; **Linux (`src-tauri/` + `dist/`)** is Tauri + Rust + WebKitGTK. Keep user-facing behavior and visual polish aligned where idiomatic, without forcing non-idiomatic patterns across platforms.
- **Linux Wayland vs. X11:**
  - Wayland shortcuts go through XDG `GlobalShortcuts` (`portal_hotkey.rs`) and pasting goes through `RemoteDesktop` (`paste.rs`). Once setup is complete, clicking `Hotkey:` on Wayland opens the compositor's shortcut dialog directly — do not open the custom X11 hotkey window.
  - X11 uses `tauri-plugin-global-shortcut` and `dist/settings.html`.
- **Linux updater (`src-tauri/src/updater.rs`):**
  - Use PackageKit over D-Bus (`org.freedesktop.PackageKit.Transaction`) with `SetHints(["interactive=true"])` and `InstallFiles(0, [path])`.
  - **Never use `pkcon -y`** — `-y` is an alias for `--noninteractive`, which disables Polkit's graphical password prompt and fails authorization immediately.
- **Linux tray menus:** Avoid rebuilding the DBusMenu (`tray.set_menu`) on frequent ticks (like download %); mutate item text in place and only rebuild on structural changes.
- **Local Linux builds on Fedora Asahi:** Use the `localhost/talkist-builder` podman image mounted at `/src` (`podman run --rm --security-opt label=disable -v "$PWD:/src" -w /src localhost/talkist-builder ...`).

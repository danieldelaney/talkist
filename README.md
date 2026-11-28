# Talkist

Talkist is a local-only push-to-talk dictation utility. Hold a global hotkey,
speak, release it, and the transcript is pasted at the cursor.

Talkist uses NVIDIA Parakeet v3 (25 European languages, automatic language
detection) through sherpa-onnx. There are no accounts, cloud transcription,
agents, or telemetry.

## Install

    curl -fsSL https://danieldelaney.net/talkist/install.sh | sh

Or download a package directly from [GitHub Releases](https://github.com/danieldelaney/talkist/releases/latest).

## Current platforms

- **macOS 13+** (Apple Silicon, Developer ID signed and notarized)
- **Linux** (`x86_64` and `aarch64`):
  - Native `.deb` (Debian 13 / Ubuntu 24.04+) and `.rpm` (Fedora) packages
  - Universal **Flatpak** bundle for any other distro (Arch, openSUSE, Silverblue/Bazzite, SteamOS, Mint, etc.)
  - Supports GNOME (Wayland & X11), KDE Plasma (Wayland & X11), X11 desktops, and wlroots compositors (via `wtype` / `wl-copy`)
- Default hotkey: `F9`

The speech model downloads on first launch and runs entirely on the local
machine. Updates are signed with minisign and installed automatically on macOS
or through PackageKit on Linux.

## Building on Fedora

    sudo dnf install cargo rustc cmake gcc-c++ jq webkit2gtk4.1-devel \
      libayatana-appindicator-gtk3-devel librsvg2-devel \
      openssl-devel alsa-lib-devel pkgconf-pkg-config rpm-build
    scripts/build-rpm.sh

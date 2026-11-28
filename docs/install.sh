#!/bin/sh
# Talkist installer for macOS (Apple Silicon) and Linux (.deb, .rpm, Flatpak).
# Usage: curl -fsSL https://danieldelaney.net/talkist/install.sh | sh
set -eu

REPO="danieldelaney/talkist"
BASE="https://github.com/${REPO}/releases/latest/download"

fail() {
  printf 'talkist: %s\n' "$1" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

json_field() {
  printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    need sudo
    sudo "$@"
  fi
}

need curl

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    [ "$ARCH" = "arm64" ] || fail "macOS builds currently require Apple Silicon (arm64); detected $ARCH"
    MANIFEST_NAME="update-mac.json"
    TARGET="macos"
    ;;
  Linux)
    if [ "${TALKIST_INSTALL_METHOD:-}" = "flatpak" ] || { ! command -v dnf >/dev/null 2>&1 && ! { command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; }; }; then
      command -v flatpak >/dev/null 2>&1 || fail "unsupported Linux distribution (install flatpak, or use Debian/Ubuntu/Fedora)"
      TARGET="flatpak"
      case "$ARCH" in
        x86_64) MANIFEST_NAME="update-flatpak.json" ;;
        aarch64|arm64) MANIFEST_NAME="update-flatpak-aarch64.json" ;;
        *) fail "unsupported Linux architecture: $ARCH" ;;
      esac
    elif command -v dnf >/dev/null 2>&1; then
      TARGET="rpm"
      case "$ARCH" in
        x86_64) MANIFEST_NAME="update-rpm.json" ;;
        aarch64|arm64) MANIFEST_NAME="update-rpm-aarch64.json" ;;
        *) fail "unsupported Linux architecture: $ARCH" ;;
      esac
    else
      TARGET="deb"
      case "$ARCH" in
        x86_64|amd64) MANIFEST_NAME="update.json" ;;
        aarch64|arm64) MANIFEST_NAME="update-arm64.json" ;;
        *) fail "unsupported Linux architecture: $ARCH" ;;
      esac
    fi
    ;;
  *)
    fail "unsupported OS: $OS"
    ;;
esac

printf 'Fetching latest Talkist release metadata...\n'
MANIFEST="$(curl -fsSL "${BASE}/${MANIFEST_NAME}")" || fail "could not fetch ${MANIFEST_NAME}"

VERSION="$(json_field "$MANIFEST" version)"
URL="$(json_field "$MANIFEST" url)"
SHA256="$(json_field "$MANIFEST" sha256)"

[ -n "$VERSION" ] && [ -n "$URL" ] && [ -n "$SHA256" ] || fail "invalid release manifest"
case "$URL" in
  "https://github.com/${REPO}/releases/download/"*) ;;
  *) fail "unexpected download URL: $URL" ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FILE="${URL##*/}"
PKG="${TMP}/${FILE}"

printf 'Downloading Talkist %s (%s)...\n' "$VERSION" "$FILE"
curl -fL --progress-bar "$URL" -o "$PKG"

printf 'Verifying checksum...\n'
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$PKG" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "$PKG" | awk '{print $1}')"
else
  fail "neither sha256sum nor shasum is installed"
fi

[ "$ACTUAL" = "$SHA256" ] || fail "checksum mismatch (expected $SHA256, got $ACTUAL)"

case "$TARGET" in
  macos)
    printf 'Installing Talkist.app to /Applications...\n'
    ditto -x -k "$PKG" "${TMP}/extract"
    APP_SRC="${TMP}/extract/Talkist.app"
    [ -d "$APP_SRC" ] || fail "Talkist.app not found in archive"
    codesign --verify "$APP_SRC" || fail "app signature verification failed"
    pkill -x Talkist 2>/dev/null || true
    sleep 0.5
    if [ -w /Applications ] && { [ ! -e /Applications/Talkist.app ] || [ -w /Applications/Talkist.app ]; }; then
      rm -rf /Applications/Talkist.app
      mv "$APP_SRC" /Applications/Talkist.app
    else
      run_root rm -rf /Applications/Talkist.app
      run_root mv "$APP_SRC" /Applications/Talkist.app
    fi
    printf 'Installed Talkist %s. Opening Talkist...\n' "$VERSION"
    open /Applications/Talkist.app
    ;;
  deb)
    printf 'Installing %s...\n' "$FILE"
    run_root apt-get install -y "$PKG"
    printf '\nTalkist %s installed. Launch it from your app menu or run: talkist\n' "$VERSION"
    ;;
  rpm)
    printf 'Installing %s...\n' "$FILE"
    run_root dnf install -y "$PKG"
    printf '\nTalkist %s installed. Launch it from your app menu or run: talkist\n' "$VERSION"
    ;;
  flatpak)
    printf 'Installing %s via Flatpak...\n' "$FILE"
    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install --user -y "$PKG"
    printf '\nTalkist %s installed. Launch it from your app menu or run: flatpak run com.talkist.app\n' "$VERSION"
    ;;
esac

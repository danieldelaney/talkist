#!/usr/bin/env bash
set -euo pipefail
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(cargo metadata --no-deps --format-version 1 --manifest-path "$root/src-tauri/Cargo.toml" | jq -r '.packages[0].version')"
arch="$(uname -m)"
fp_dir="$root/packaging/flatpak"
stage="$fp_dir/stage"
build_dir="$fp_dir/build-dir"
repo_dir="$fp_dir/repo"
output="$root/talkist-${version}-${arch}.flatpak"

cleanup() {
  rm -rf "$stage" "$build_dir" "$repo_dir" "$fp_dir/.flatpak-builder"
}
trap cleanup EXIT

if [ ! -x "$root/src-tauri/target/release/talkist" ]; then
  cargo build --release --manifest-path "$root/src-tauri/Cargo.toml"
fi

rm -rf "$stage" "$build_dir" "$repo_dir"
mkdir -p "$stage/lib" "$stage/icons"

install -Dm755 "$root/src-tauri/target/release/talkist" "$stage/talkist"
cp "$root/src-tauri/icons/32x32.png" "$stage/icons/32x32.png"
cp "$root/src-tauri/icons/128x128.png" "$stage/icons/128x128.png"
cp "$root/src-tauri/icons/256x256.png" "$stage/icons/256x256.png"

# Bundle libayatana-appindicator3 and its small dbusmenu/indicator deps, which
# are not shipped in org.gnome.Platform.
needed_libs=(
  libayatana-appindicator3.so.1
  libayatana-indicator3.so.7
  libayatana-ido3-0.4.so.0
  libdbusmenu-gtk3.so.4
  libdbusmenu-glib.so.4
)
for soname in "${needed_libs[@]}"; do
  lib_path="$(ldconfig -p | awk -v s="$soname" '$1 == s { print $NF; exit }')"
  if [ -z "$lib_path" ] || [ ! -e "$lib_path" ]; then
    echo "missing required shared library for Flatpak bundle: $soname" >&2
    exit 1
  fi
  cp -L "$lib_path" "$stage/lib/$soname"
done

flatpak-builder \
  --user \
  --force-clean \
  --disable-rofiles-fuse \
  --repo="$repo_dir" \
  "$build_dir" \
  "$fp_dir/com.talkist.app.yml"

flatpak build-bundle \
  "$repo_dir" \
  "$output" \
  com.talkist.app \
  --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo

printf '%s\n' "$output"

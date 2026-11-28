#!/usr/bin/env bash
set -euo pipefail
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(cargo metadata --no-deps --format-version 1 --manifest-path "$root/src-tauri/Cargo.toml" | jq -r '.packages[0].version')"
arch="$(dpkg --print-architecture)"
stage="$root/packaging/debroot"
output="$root/talkist_${version}_${arch}.deb"

cargo build --release --manifest-path "$root/src-tauri/Cargo.toml"
install -Dm755 "$root/src-tauri/target/release/talkist" "$stage/usr/bin/talkist"
sed -i "s/^Version: .*/Version: $version/" "$stage/DEBIAN/control"
sed -i "s/^Architecture: .*/Architecture: $arch/" "$stage/DEBIAN/control"
dpkg-deb --build --root-owner-group "$stage" "$output"
printf '%s\n' "$output"

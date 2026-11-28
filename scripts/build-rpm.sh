#!/usr/bin/env bash
set -euo pipefail
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(cargo metadata --no-deps --format-version 1 --manifest-path "$root/src-tauri/Cargo.toml" | jq -r '.packages[0].version')"
arch="$(uname -m)"
top="$root/packaging/rpmbuild"
output="$root/talkist-$version-1.$arch.rpm"

rm -rf "$top"
cargo build --release --manifest-path "$root/src-tauri/Cargo.toml"
sed -i "s/^Version: .*/Version: $version/" "$root/packaging/talkist.spec"
rpmbuild -bb \
  --define "_topdir $top" \
  --define "_sourcedir $root/packaging" \
  --define "_specdir $root/packaging" \
  --define "_rpmdir $top" \
  --define "talkist_bin $root/src-tauri/target/release/talkist" \
  --define "talkist_payload $root/packaging/debroot" \
  "$root/packaging/talkist.spec"
mv "$top/$arch/talkist-$version-1.$arch.rpm" "$output"
printf '%s\n' "$output"

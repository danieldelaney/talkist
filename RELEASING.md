# Releasing Talkist

Never publish an untested build as **Latest** (`releases/latest` drives every user's in-app updater).

## How releases work

- **CI on `main`** ([ci.yml](.github/workflows/ci.yml)) runs Linux tests/build and macOS unsigned compile on every push and PR.
- **Prerelease tags** (`vX.Y.Z-rc.1`, anything with a `-`) build and publish a GitHub **prerelease** via [release.yml](.github/workflows/release.yml). Prereleases have public download URLs for testing the real in-app updater, but do **not** move `/releases/latest`.
- **Stable tags** (`vX.Y.Z`) build and create a **draft** GitHub release. Users do not see it until you manually publish it as **Latest** in GitHub Releases.

## Release steps

1. **Confirm `main` is green** in GitHub Actions (`CI`).
2. **Bump the version** in all 8 places:
   - `src-tauri/Cargo.toml`
   - `src-tauri/Cargo.lock` (`talkist` package entry)
   - `src-tauri/tauri.conf.json`
   - `packaging/debroot/DEBIAN/control`
   - `packaging/talkist.spec`
   - `packaging/flatpak/com.talkist.app.metainfo.xml` (`<release version="..." date="..." />`)
   - `macos/project.yml` (`MARKETING_VERSION`)
   - `macos/scripts/build.sh` (`VERSION` default)
3. **Cut a release candidate first** when shipping updater, packaging, or risky changes:
   - Tag `vX.Y.Z-rc.1` and wait for `Release` workflow to finish.
   - Test the real in-app updater from the current installed stable build by pointing it at the prerelease manifest:
     ```sh
     # Fedora aarch64 example (use update.json / update-arm64.json / update-rpm.json / update-mac.json as appropriate)
     TALKIST_UPDATE_MANIFEST_URL=https://github.com/danieldelaney/talkist/releases/download/vX.Y.Z-rc.1/update-rpm-aarch64.json talkist
     ```
4. **Tag the stable draft** (`vX.Y.Z`), download the packaged artifacts from the draft release, and run the smoke checklist below.
5. **Smoke-test checklist (actual packaged builds, not `cargo run`):**
   - [ ] **In-app update:** Upgrade from previous stable release → auth prompt appears → installs → relaunches on new version.
   - [ ] **Fresh setup:** Move model dir aside temporarily → launch → tray shows downloading icon/status → downloads, verifies, extracts, loads without crashing or restarting.
   - [ ] **Core flow:** Hold hotkey, speak, release → red recording dot → transcript pastes cleanly at cursor.
   - [ ] **Settings / hotkey:** Change hotkey (X11 custom window / Wayland system dialog / macOS picker) and verify tray menu + app launcher icon.
6. **Promote:** In GitHub Releases, publish the draft as **Latest**.
7. **Clean up:** Delete any `-rc` prerelease(s) and their git tags (`gh release delete vX.Y.Z-rc.1 --cleanup-tag -y`) so the public Releases page only shows clean stable releases.

# Built via scripts/build-rpm.sh, which supplies the Version and points the
# talkist_bin / talkist_payload defines at the release binary and the payload
# tree (packaging/debroot holds the files both package formats ship).
Name:           talkist
Version: 1.0.0
Release:        1
Summary:        Local-only push-to-talk dictation
License:        Proprietary
URL:            https://github.com/danieldelaney/talkist

# Library dependencies (webkit2gtk, gtk, alsa, dbus) are required through
# their ELF sonames, generated automatically from the shipped binary.
# libayatana-appindicator is loaded dynamically at runtime, so it must be
# named explicitly.
Requires:       tar, bzip2, PackageKit, libayatana-appindicator-gtk3
Recommends:     gnome-shell-extension-appindicator

# The release binary is already stripped by cargo; skip the redhat build
# helper scripts so the package builds the same on every host.
%define debug_package %{nil}
%define __os_install_post %{nil}

%description
Push-to-talk voice dictation powered by NVIDIA Parakeet, running fully
offline via sherpa-onnx. Global hotkey records, transcribes, and pastes
the text at your cursor. Tray icon with enable/disable. No cloud, no
accounts, no telemetry.

%install
install -Dm755 "%{talkist_bin}" "%{buildroot}%{_bindir}/talkist"
install -Dm644 "%{talkist_payload}/usr/share/applications/talkist.desktop" "%{buildroot}%{_datadir}/applications/talkist.desktop"
install -Dm644 "%{talkist_payload}/usr/share/applications/com.talkist.app.desktop" "%{buildroot}%{_datadir}/applications/com.talkist.app.desktop"
install -Dm644 "%{talkist_payload}/usr/share/icons/hicolor/32x32/apps/talkist.png" "%{buildroot}%{_datadir}/icons/hicolor/32x32/apps/talkist.png"
install -Dm644 "%{talkist_payload}/usr/share/icons/hicolor/128x128/apps/talkist.png" "%{buildroot}%{_datadir}/icons/hicolor/128x128/apps/talkist.png"
install -Dm644 "%{talkist_payload}/usr/share/icons/hicolor/256x256/apps/talkist.png" "%{buildroot}%{_datadir}/icons/hicolor/256x256/apps/talkist.png"
install -Dm755 "%{talkist_payload}/usr/share/talkist/fetch-model.sh" "%{buildroot}%{_datadir}/talkist/fetch-model.sh"
install -Dm644 "%{talkist_payload}/etc/xdg/autostart/talkist.desktop" "%{buildroot}%{_sysconfdir}/xdg/autostart/talkist.desktop"

%files
%{_bindir}/talkist
%{_datadir}/applications/talkist.desktop
%{_datadir}/applications/com.talkist.app.desktop
%{_datadir}/icons/hicolor/32x32/apps/talkist.png
%{_datadir}/icons/hicolor/128x128/apps/talkist.png
%{_datadir}/icons/hicolor/256x256/apps/talkist.png
%dir %{_datadir}/talkist
%{_datadir}/talkist/fetch-model.sh
%{_sysconfdir}/xdg/autostart/talkist.desktop

%changelog
* Wed Nov 18 2026 dd <dd@localhost> - 0.1.0-1
- Package the prebuilt release binary.

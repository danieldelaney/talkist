import AppKit
import SwiftUI
import ServiceManagement
import CoreGraphics
import AVFoundation
import AVFAudio

enum MicrophonePermission {
    case undetermined, denied, granted
}

final class AppController: ObservableObject {
    @Published var hotkeyText: String = "F9"
    @Published var startAtLogin: Bool = false
    @Published var errorText: String = ""
    @Published var capturing = false
    @Published var updateVersion: String?
    @Published var updateProgressText: String?
    @Published var accessibilityGranted: Bool
    @Published var microphoneStatus: MicrophonePermission
    @Published var inputMonitoringGranted: Bool

    private(set) var config = Config.defaults
    private weak var hotkey: Hotkey?
    private(set) var updater: Updater?
    var showSettings: (() -> Void)?

    init() {
        accessibilityGranted = Paster.trusted
        microphoneStatus = Self.currentMicrophonePermission()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        updateVersion = ProcessInfo.processInfo.environment["TALKIST_PREVIEW_UPDATE"]
    }

    func refreshMicrophoneState() {
        microphoneStatus = Self.currentMicrophonePermission()
    }

    var microphoneGranted: Bool { microphoneStatus == .granted }

    var needsInputMonitoring: Bool {
        hotkeyText == "CapsLock" && !inputMonitoringGranted
    }

    var permissionsReady: Bool {
        accessibilityGranted && microphoneGranted && !needsInputMonitoring
    }

    func refreshInputMonitoringState() {
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    func requestInputMonitoring() {
        if UserDefaults.standard.bool(forKey: "askedInputMonitoring") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        } else {
            UserDefaults.standard.set(true, forKey: "askedInputMonitoring")
            _ = CGRequestListenEventAccess()
        }
        refreshInputMonitoringState()
    }

    func requestMicrophone() {
        switch microphoneStatus {
        case .undetermined:
            NSApp.activate(ignoringOtherApps: true)
            if #available(macOS 14.0, *) {
                AVAudioApplication.requestRecordPermission { [weak self] _ in
                    DispatchQueue.main.async { self?.refreshMicrophoneState() }
                }
            } else {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    DispatchQueue.main.async { self?.refreshMicrophoneState() }
                }
            }
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .granted:
            refreshMicrophoneState()
        }
    }

    private static func currentMicrophonePermission() -> MicrophonePermission {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined: return .undetermined
            case .denied: return .denied
            case .granted: return .granted
            @unknown default: return .denied
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .undetermined
        case .authorized: return .granted
        default: return .denied
        }
    }

    func requestAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        Paster.promptIfNeeded()
    }

    func apply(_ config: Config) {
        self.config = config
        hotkeyText = config.hotkey
        startAtLogin = config.startAtLogin
    }

    func wire(hotkey: Hotkey, updater: Updater) {
        self.hotkey = hotkey
        self.updater = updater
    }

    func relaunch() {
        AppRelaunch.relaunch(replacing: nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func updateAvailable(_ manifest: UpdateManifest) {
        guard updateProgressText == nil else { return }
        updateVersion = manifest.version
    }

    // MARK: hotkey capture

    func beginCapture() {
        guard !capturing, let hotkey else { return }
        errorText = ""
        capturing = true
        hotkey.beginCapture { [weak self] shortcut in
            guard let self else { return }
            self.capturing = false
            if let shortcut { self.applyShortcut(shortcut) }
        }
    }

    func cancelCapture() {
        capturing = false
        hotkey?.cancelCapture()
    }

    private func applyShortcut(_ shortcut: Shortcut) {
        guard let hotkey else { return }
        hotkey.setShortcut(shortcut)
        config.hotkey = shortcut.text
        hotkeyText = shortcut.text
        config.save()
        refreshInputMonitoringState()
    }

    // MARK: start at login

    func setStartAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            config.startAtLogin = enabled
            startAtLogin = enabled
            config.save()
            errorText = ""
        } catch {
            errorText = error.localizedDescription
            startAtLogin = !enabled
        }
    }

    // MARK: updates

    func installUpdate() {
        guard let updater, let manifest = updater.available else { return }
        errorText = ""
        updateProgressText = "Downloading 0%"
        updater.downloadAndInstall(
            manifest: manifest,
            onProgress: { [weak self] pct in self?.updateProgressText = "Downloading \(pct)%" },
            onStage: { [weak self] stage in self?.updateProgressText = stage },
            onError: { [weak self] message in
                self?.errorText = message
                self?.updateProgressText = nil
            }
        )
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                if permissionsMissing {
                    Text("Finish setup")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Talkist needs these permissions to transcribe and paste.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    PermissionRow(
                        title: "Accessibility",
                        granted: controller.accessibilityGranted,
                        action: controller.requestAccessibility
                    )
                    PermissionRow(
                        title: "Microphone",
                        granted: controller.microphoneGranted,
                        buttonTitle: controller.microphoneStatus == .undetermined ? "Allow" : "Open Settings",
                        action: controller.requestMicrophone
                    )
                    if controller.hotkeyText == "CapsLock" {
                        PermissionRow(
                            title: "Input Monitoring",
                            granted: controller.inputMonitoringGranted,
                            buttonTitle: UserDefaults.standard.bool(forKey: "askedInputMonitoring")
                                ? "Open Settings" : "Allow",
                            action: controller.requestInputMonitoring
                        )
                    }
                } else {
                    Text("Push-to-talk hotkey")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(action: controller.beginCapture) {
                        Text(controller.capturing ? "Press shortcut" : controller.hotkeyText)
                    }
                    .buttonStyle(KeycapButtonStyle(capturing: controller.capturing))
                    .disabled(controller.capturing)
                    Text("Hold \(controller.hotkeyText), then release to paste")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.65))
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .bottom) {
                if !controller.errorText.isEmpty {
                    Text(controller.errorText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }

            HStack(spacing: 10) {
                Menu {
                    Toggle("Start at login", isOn: Binding(
                        get: { controller.startAtLogin },
                        set: { controller.setStartAtLogin($0) }
                    ))
                    Divider()
                    Button("Quit Talkist") { controller.quit() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Talkist \(currentVersion)")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                    }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                if let v = controller.updateVersion {
                    Button(controller.updateProgressText ?? "Update to \(v)") {
                        controller.installUpdate()
                    }
                    .buttonStyle(UpdateButtonStyle())
                    .disabled(controller.updateProgressText != nil)
                }
            }
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
            }
        }
        .frame(width: 360, height: 220)
    }

    private var permissionsMissing: Bool {
        !controller.permissionsReady
    }

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}

// MARK: - Keycap button (matches the Linux settings.html #hotkey styling)

struct KeycapButtonStyle: ButtonStyle {
    let capturing: Bool
    private let borderColor = Color(red: 90/255, green: 96/255, blue: 107/255)
    private let borderColorActive = Color(red: 170/255, green: 170/255, blue: 170/255)
    private let textColor = Color(red: 241/255, green: 241/255, blue: 241/255)
    private let topColor = Color(red: 48/255, green: 52/255, blue: 60/255)
    private let bottomColor = Color(red: 37/255, green: 41/255, blue: 48/255)

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let border = capturing ? borderColorActive : borderColor
        return configuration.label
            .font(.system(size: 24, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(textColor)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(minWidth: 140, minHeight: 56)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(border)
                        .offset(y: pressed ? 1 : 2)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [topColor, bottomColor], startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.08), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
            .offset(y: pressed ? 1 : 0)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct UpdateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 64/255, green: 127/255, blue: 238/255)
                        .opacity(configuration.isPressed ? 0.72 : 0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}

// MARK: - Permission checklist

struct PermissionRow: View {
    let title: String
    let granted: Bool
    var buttonTitle = "Allow"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Spacer()
            if granted {
                Text("Allowed")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Button(buttonTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

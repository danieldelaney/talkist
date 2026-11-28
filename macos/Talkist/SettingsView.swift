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
    @Published var capturing: Bool = false
    @Published var captureHint: String?
    @Published var updateVersion: String?
    @Published var updateProgressText: String?
    @Published var updateFailed: Bool = false
    @Published var accessibilityGranted: Bool
    @Published var microphoneStatus: MicrophonePermission
    @Published var inputMonitoringGranted: Bool
    @Published var modelReady: Bool = false
    @Published var modelStatusText: String?
    @Published var modelProgress: Int?
    @Published var modelErrorText: String?
    @Published var modelErrorDetail: String?

    private(set) var config = Config.defaults
    private weak var hotkey: Hotkey?
    private(set) var updater: Updater?
    private var captureTimeout: DispatchWorkItem?
    private var localMonitor: Any?
    private var localPendingModifier: CGKeyCode?

    var onMenuStateChanged: (() -> Void)?
    var onRetryModel: (() -> Void)?

    init() {
        accessibilityGranted = Paster.trusted
        microphoneStatus = Self.currentMicrophonePermission()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        updateVersion = ProcessInfo.processInfo.environment["TALKIST_PREVIEW_UPDATE"]
    }

    var hotkeyDisplayText: String {
        Shortcut.displayText(for: hotkeyText)
    }

    var microphoneGranted: Bool { microphoneStatus == .granted }

    var needsInputMonitoring: Bool {
        hotkeyText == "CapsLock" && !inputMonitoringGranted
    }

    var permissionsReady: Bool {
        accessibilityGranted && microphoneGranted && !needsInputMonitoring
    }

    var isFullyReady: Bool {
        modelReady && permissionsReady
    }

    func refreshMicrophoneState() {
        microphoneStatus = Self.currentMicrophonePermission()
    }

    func refreshInputMonitoringState() {
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    func requestAccessibility() {
        if UserDefaults.standard.bool(forKey: "askedAccessibility") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            NSApp.activate(ignoringOtherApps: true)
            Paster.promptIfNeeded()
        }
    }

    func requestInputMonitoring() {
        if UserDefaults.standard.bool(forKey: "askedInputMonitoring") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        } else {
            UserDefaults.standard.set(true, forKey: "askedInputMonitoring")
            NSApp.activate(ignoringOtherApps: true)
            _ = CGRequestListenEventAccess()
        }
        refreshInputMonitoringState()
        onMenuStateChanged?()
    }

    func requestMicrophone() {
        switch microphoneStatus {
        case .undetermined:
            NSApp.activate(ignoringOtherApps: true)
            if #available(macOS 14.0, *) {
                AVAudioApplication.requestRecordPermission { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.refreshMicrophoneState()
                        self?.onMenuStateChanged?()
                    }
                }
            } else {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.refreshMicrophoneState()
                        self?.onMenuStateChanged?()
                    }
                }
            }
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .granted:
            refreshMicrophoneState()
            onMenuStateChanged?()
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

    func apply(_ config: Config) {
        self.config = config
        hotkeyText = config.hotkey
        startAtLogin = config.startAtLogin
        onMenuStateChanged?()
    }

    func wire(hotkey: Hotkey, updater: Updater) {
        self.hotkey = hotkey
        self.updater = updater
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func retryModel() {
        onRetryModel?()
    }

    func updateAvailable(_ manifest: UpdateManifest) {
        guard updateProgressText == nil else { return }
        updateVersion = manifest.version
        updateFailed = false
        onMenuStateChanged?()
    }

    // MARK: hotkey capture

    func toggleCapture() {
        if capturing {
            cancelCapture()
        } else {
            beginCapture()
        }
    }

    func beginCapture() {
        guard !capturing else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        capturing = true
        captureHint = nil
        localPendingModifier = nil
        onMenuStateChanged?()

        captureTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.cancelCapture()
        }
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)

        let tapActive = hotkey?.isTapActive ?? false
        if tapActive, let hotkey {
            hotkey.beginCapture { [weak self] shortcut in
                self?.finishCapture(shortcut)
            }
        }
        installLocalCaptureMonitor(tapActive: tapActive)
    }

    func cancelCapture() {
        captureTimeout?.cancel()
        captureTimeout = nil
        removeLocalCaptureMonitor()
        localPendingModifier = nil
        guard capturing else { return }
        capturing = false
        captureHint = nil
        hotkey?.cancelCapture()
        onMenuStateChanged?()
    }

    private func finishCapture(_ shortcut: Shortcut?) {
        captureTimeout?.cancel()
        captureTimeout = nil
        removeLocalCaptureMonitor()
        localPendingModifier = nil
        capturing = false
        captureHint = nil
        if let shortcut {
            applyShortcut(shortcut)
        } else {
            onMenuStateChanged?()
        }
    }

    private func installLocalCaptureMonitor(tapActive: Bool) {
        removeLocalCaptureMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .systemDefined]
        ) { [weak self] event in
            guard let self, self.capturing else { return event }
            return self.handleLocalCaptureEvent(event, tapActive: tapActive)
        }
    }

    private func removeLocalCaptureMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleLocalCaptureEvent(_ event: NSEvent, tapActive: Bool) -> NSEvent? {
        if tapActive {
            // Valid shortcuts, Esc, CapsLock, lone modifiers, and media keys are
            // captured by Hotkey's CGEventTap. Any keyDown that still reaches the
            // window is an unsupported key — absorb it with a hint (no beep).
            if event.type == .keyDown {
                captureHint = "Key not supported"
                return nil
            }
            return event
        }

        // Fallback capture when the CGEventTap isn't active yet (e.g. during
        // first-run setup before Accessibility is granted or while downloading).
        switch event.type {
        case .systemDefined:
            guard event.subtype.rawValue == 8 else { return event }
            let mediaKey = (event.data1 & 0xFFFF0000) >> 16
            let state = (event.data1 & 0xFF00) >> 8
            if state == 0xA, let fKey = Shortcut.fKeyCode(forMediaKey: mediaKey) {
                localPendingModifier = nil
                finishCapture(Shortcut.canonical(keyCode: fKey, modifiers: []))
                return nil
            }
            return event
        case .flagsChanged:
            let code = CGKeyCode(event.keyCode)
            if code == Shortcut.capsLockCode {
                localPendingModifier = nil
                finishCapture(Shortcut.canonical(keyCode: Shortcut.capsLockCode, modifiers: []))
                return nil
            }
            if Shortcut.isModifierKey(code) {
                let flags = Self.cgFlags(from: event.modifierFlags)
                if Shortcut.isModifierKeyDown(code: code, flags: flags) {
                    let allMods = CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn])
                    let ownFlag = Shortcut.modifierFlag(for: code) ?? []
                    let otherMods = flags.intersection(allMods).subtracting(ownFlag)
                    if otherMods.isEmpty && localPendingModifier == nil {
                        localPendingModifier = code
                    } else {
                        localPendingModifier = nil
                    }
                } else if localPendingModifier == code {
                    localPendingModifier = nil
                    finishCapture(Shortcut.canonical(keyCode: code, modifiers: []))
                }
            }
            return event
        case .keyDown:
            localPendingModifier = nil
            let code = CGKeyCode(event.keyCode)
            if code == 0x35 { // Escape
                finishCapture(nil)
                return nil
            }
            if Shortcut.keyTable.contains(where: { $0.1 == code }) {
                let mods = Self.cgFlags(from: event.modifierFlags)
                    .intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
                finishCapture(Shortcut.canonical(keyCode: code, modifiers: mods))
                return nil
            }
            captureHint = "Key not supported"
            return nil
        default:
            return event
        }
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }

    private func applyShortcut(_ shortcut: Shortcut) {
        hotkey?.setShortcut(shortcut)
        config.hotkey = shortcut.text
        hotkeyText = shortcut.text
        config.save()
        refreshInputMonitoringState()
        onMenuStateChanged?()
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
        } catch {
            logStderr("start at login failed: \(error.localizedDescription)")
            startAtLogin = !enabled
        }
        onMenuStateChanged?()
    }

    // MARK: updates

    func installUpdate() {
        guard let updater, let manifest = updater.available, updateProgressText == nil else { return }
        updateFailed = false
        updateProgressText = "Downloading 0%"
        onMenuStateChanged?()
        updater.downloadAndInstall(
            manifest: manifest,
            onProgress: { [weak self] pct in
                self?.updateProgressText = "Downloading \(pct)%"
                self?.onMenuStateChanged?()
            },
            onStage: { [weak self] stage in
                self?.updateProgressText = stage
                self?.onMenuStateChanged?()
            },
            onError: { [weak self] message in
                logStderr("update failed: \(message)")
                self?.updateProgressText = nil
                self?.updateFailed = true
                self?.onMenuStateChanged?()
            }
        )
    }
}

// MARK: - Window Content

struct SettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(spacing: 10) {
            if !controller.isFullyReady {
                if !controller.modelReady {
                    ModelSetupRow(controller: controller)
                }
                PermissionRow(
                    title: "Accessibility",
                    subtitle: "Hotkey & pasting",
                    granted: controller.accessibilityGranted,
                    buttonTitle: UserDefaults.standard.bool(forKey: "askedAccessibility") ? "Open Settings" : "Allow",
                    action: controller.requestAccessibility
                )
                PermissionRow(
                    title: "Microphone",
                    subtitle: nil,
                    granted: controller.microphoneGranted,
                    buttonTitle: controller.microphoneStatus == .denied ? "Open Settings" : "Allow",
                    action: controller.requestMicrophone
                )
                if controller.hotkeyText == "CapsLock" {
                    PermissionRow(
                        title: "Input Monitoring",
                        subtitle: "Relaunch after allowing",
                        granted: controller.inputMonitoringGranted,
                        buttonTitle: UserDefaults.standard.bool(forKey: "askedInputMonitoring") ? "Open Settings" : "Allow",
                        action: controller.requestInputMonitoring
                    )
                }
            } else {
                Text("Push-to-talk hotkey")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(action: controller.toggleCapture) {
                    Text(controller.capturing ? "Press key…" : controller.hotkeyDisplayText)
                }
                .buttonStyle(KeycapButtonStyle(capturing: controller.capturing))
                if let hint = controller.captureHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                } else if controller.capturing {
                    Text("Esc to cancel")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Hold \(controller.hotkeyDisplayText), then release to paste")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
        }
        .padding(20)
        .frame(width: 340)
        .fixedSize(horizontal: true, vertical: true)
    }
}

// MARK: - Keycap button (matches Linux settings.html #hotkey)

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
            .font(.system(size: 22, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(textColor)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .frame(minWidth: 150, minHeight: 54)
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

// MARK: - Setup rows

private struct ModelSetupRow: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if controller.modelErrorText != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .frame(width: 16)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
                Text(controller.modelErrorText ?? controller.modelStatusText ?? "Downloading speech model…")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer()
                if controller.modelErrorText != nil {
                    Button("Retry", action: controller.retryModel)
                        .controlSize(.small)
                }
            }
            if let pct = controller.modelProgress, controller.modelErrorText == nil {
                ProgressView(value: Double(pct), total: 100)
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

private struct PermissionRow: View {
    let title: String
    let subtitle: String?
    let granted: Bool
    var buttonTitle = "Allow"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                if let subtitle, !granted {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
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
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

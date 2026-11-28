import AppKit
import SwiftUI

@main
struct TalkistApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // no Dock icon (backup for LSUIElement)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()
    private let statuses = StatusChannel()
    private var hotkey: Hotkey?
    private var audio: AudioCapture?
    private var tray: TrayController?
    private var settingsWindow: SettingsWindow?
    private var modelDownloadInFlight = false
    private var permissionTimer: Timer?
    private var lastInputMonitoringGranted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstance.acquire() else {
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.talkist.app.showSettings"), object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showSettingsRequested),
            name: .init("com.talkist.app.showSettings"), object: nil)

        let config = Config.load()
        controller.apply(config)
        lastInputMonitoringGranted = controller.inputMonitoringGranted
        controller.onMenuStateChanged = { [weak self] in self?.syncTrayMenu() }
        controller.onRetryModel = { [weak self] in self?.retryModelSetup() }

        let tray = TrayController(
            statusChannel: statuses,
            hotkey: controller.hotkeyDisplayText,
            startAtLogin: controller.startAtLogin
        )
        tray.onMenuWillOpen = { [weak self] in self?.refreshAllState() }
        tray.onOpenSettings = { [weak self] in self?.showSettingsWindow() }
        tray.onToggleStartAtLogin = { [weak self] in
            guard let self else { return }
            self.controller.setStartAtLogin(!self.controller.startAtLogin)
        }
        tray.onInstallUpdate = { [weak self] in self?.controller.installUpdate() }
        tray.onQuit = { [weak self] in self?.controller.quit() }
        self.tray = tray

        let modelFilesReady = ModelStore.isReady(at: Paths.modelDir)
        let needsSetup = !modelFilesReady || !controller.permissionsReady

        if !modelFilesReady {
            startModelDownload()
        } else {
            loadModelAndFinishSetup()
        }

        refreshAllState()
        updatePermissionTimer()

        if needsSetup {
            showSettingsWindow()
        }
    }

    private func retryModelSetup() {
        if ModelStore.isReady(at: Paths.modelDir) {
            loadModelAndFinishSetup()
        } else {
            startModelDownload()
        }
    }

    private func loadModelAndFinishSetup() {
        guard !modelDownloadInFlight else { return }
        modelDownloadInFlight = true
        let numThreads = controller.config.numThreads
        controller.modelErrorText = nil
        controller.modelErrorDetail = nil
        controller.modelProgress = nil
        controller.modelStatusText = "Loading speech model…"
        syncTrayMenu()

        let mailbox = BoundedMailbox<[Float]>()
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let ok = Recognizer.spawn(
                modelDir: Paths.modelDir,
                numThreads: numThreads,
                mailbox: mailbox,
                statusChannel: self.statuses
            )
            DispatchQueue.main.async {
                self.modelDownloadInFlight = false
                guard ok else {
                    self.statuses.send(.idle)
                    self.controller.modelStatusText = nil
                    self.controller.modelErrorText = "Model failed to load"
                    self.controller.modelErrorDetail = "Failed to load the Parakeet model."
                    self.syncTrayMenu()
                    return
                }
                self.controller.modelStatusText = nil
                self.controller.modelErrorText = nil
                self.controller.modelErrorDetail = nil
                self.controller.modelReady = true
                self.statuses.send(.idle)
                self.finishSetup(mailbox: mailbox)
            }
        }
    }

    private func finishSetup(mailbox: BoundedMailbox<[Float]>) {
        audio = AudioCapture(asrMailbox: mailbox, statusChannel: statuses)

        let shortcut = Shortcut.parse(controller.config.hotkey) ?? Shortcut.canonical(keyCode: 0x65, modifiers: [])
        let hotkey = Hotkey(shortcut: shortcut)
        hotkey.onPressed = { [weak self] in self?.audio?.send(.start) }
        hotkey.onReleased = { [weak self] in self?.audio?.send(.stopSend) }
        self.hotkey = hotkey

        controller.wire(hotkey: hotkey, updater: Updater())
        controller.updater?.startChecks(onAvailable: { [weak controller] manifest in
            controller?.updateAvailable(manifest)
        })

        hotkey.install()
        refreshAllState()
        updatePermissionTimer()
    }

    private func updatePermissionTimer() {
        if controller.permissionsReady {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.refreshAllState()
            }
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        }
    }

    // MARK: model first run

    private func startModelDownload() {
        guard !modelDownloadInFlight else { return }
        modelDownloadInFlight = true
        statuses.send(.downloading)
        controller.modelReady = false
        controller.modelErrorText = nil
        controller.modelErrorDetail = nil
        controller.modelProgress = nil
        controller.modelStatusText = "Downloading speech model…"
        syncTrayMenu()

        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            do {
                try ModelStore.downloadAndExtract(
                    progress: { [weak self] pct in
                        guard let self else { return }
                        self.controller.modelProgress = pct
                        self.controller.modelStatusText = "Downloading speech model… \(pct)%"
                        self.syncTrayMenu()
                    },
                    onStage: { [weak self] stage in
                        guard let self else { return }
                        self.controller.modelProgress = nil
                        self.controller.modelStatusText = stage
                        self.syncTrayMenu()
                    }
                )
                DispatchQueue.main.async {
                    self.modelDownloadInFlight = false
                    self.loadModelAndFinishSetup()
                }
            } catch {
                logStderr("model download failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.modelDownloadInFlight = false
                    self.statuses.send(.idle)
                    self.controller.modelStatusText = nil
                    self.controller.modelProgress = nil
                    self.controller.modelErrorText = Self.shortModelError(error)
                    self.controller.modelErrorDetail = error.localizedDescription
                    self.syncTrayMenu()
                }
            }
        }
    }

    private static func shortModelError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "Offline"
            case .timedOut:
                return "Download timed out"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Can’t reach server"
            default:
                break
            }
        }
        if let modelError = error as? ModelError {
            switch modelError {
            case .checksum: return "Checksum mismatch"
            case .extraction: return "Extract failed"
            case .missingFiles: return "Incomplete model"
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return "Disk full"
        }
        let text = error.localizedDescription
        return text.count > 44 ? String(text.prefix(43)) + "…" : text
    }

    // MARK: permissions, menu & window

    private func refreshAllState() {
        let trusted = Paster.trusted
        controller.accessibilityGranted = trusted
        if trusted { hotkey?.upgradeToSuppressingTap() }
        controller.refreshMicrophoneState()
        controller.refreshInputMonitoringState()
        if controller.inputMonitoringGranted && !lastInputMonitoringGranted {
            hotkey?.refreshCapsLockHold()
        }
        lastInputMonitoringGranted = controller.inputMonitoringGranted
        syncTrayMenu()
    }

    private func syncTrayMenu() {
        tray?.updateMenu(
            hotkey: controller.hotkeyDisplayText,
            startAtLogin: controller.startAtLogin,
            isFullyReady: controller.isFullyReady,
            modelStatus: controller.modelStatusText,
            modelError: controller.modelErrorText,
            updateVersion: controller.updateVersion,
            updateProgress: controller.updateProgressText,
            updateFailed: controller.updateFailed
        )
        updatePermissionTimer()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshAllState()
    }

    @objc private func showSettingsRequested() {
        DispatchQueue.main.async { [weak self] in self?.showSettingsWindow() }
    }

    private func showSettingsWindow() {
        refreshAllState()
        let window: SettingsWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            let created = SettingsWindow(rootView: SettingsView(controller: controller))
            created.onDeactivateOrClose = { [weak self] in
                self?.controller.cancelCapture()
            }
            created.center()
            settingsWindow = created
            window = created
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
    }
}

private final class SettingsWindow: NSWindow, NSWindowDelegate {
    var onDeactivateOrClose: (() -> Void)?

    init(rootView: SettingsView) {
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 155),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Talkist"
        isReleasedWhenClosed = false
        contentViewController = hosting
        delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onDeactivateOrClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        onDeactivateOrClose?()
    }
}

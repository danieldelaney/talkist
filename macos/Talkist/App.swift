import AppKit
import SwiftUI
import AVFoundation

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
    private var hotkey: Hotkey?
    private var audio: AudioCapture?
    private var tray: TrayController?
    private var settingsPopover: NSPopover?

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
        controller.showSettings = { [weak self] in self?.showSettings() }

        if !ModelStore.isReady(at: Paths.modelDir) {
            startModelDownload()
            return
        }
        finishSetup(config)
    }

    private func finishSetup(_ config: Config) {
        let mailbox = BoundedMailbox<[Float]>()
        let statuses = StatusChannel()

        guard Recognizer.spawn(modelDir: Paths.modelDir, numThreads: config.numThreads,
                               mailbox: mailbox, statusChannel: statuses) else {
            showModelError("failed to load the Parakeet model")
            return
        }
        audio = AudioCapture(asrMailbox: mailbox, statusChannel: statuses)

        let shortcut = Shortcut.parse(config.hotkey) ?? Shortcut.canonical(keyCode: 0x65, modifiers: [])
        let hotkey = Hotkey(shortcut: shortcut)
        hotkey.onPressed = { [weak self] in self?.audio?.send(.start) }
        hotkey.onReleased = { [weak self] in self?.audio?.send(.stopSend) }
        self.hotkey = hotkey

        let tray = TrayController(statusChannel: statuses)
        tray.onSettings = { [weak self] in self?.showSettings() }
        self.tray = tray

        controller.wire(hotkey: hotkey, updater: Updater())
        controller.updater?.startChecks(onAvailable: { [weak controller] manifest in
            controller?.updateAvailable(manifest)
        })

        hotkey.install()
        refreshAccessibilityState()
        controller.refreshMicrophoneState()
        controller.refreshInputMonitoringState()
        if !controller.permissionsReady {
            showSettings()
        }
    }

    // MARK: model first run

    private func startModelDownload() {
        let panel = SetupPanel()
        panel.show()
        Thread.detachNewThread {
            do {
                try ModelStore.downloadAndExtract { pct in
                    DispatchQueue.main.async { panel.setProgress(pct) }
                }
                AppRelaunch.relaunch(replacing: nil) // same restart pattern as Linux
            } catch {
                DispatchQueue.main.async { panel.showError(error.localizedDescription) }
            }
        }
    }

    private func showModelError(_ message: String) {
        let panel = SetupPanel()
        panel.show()
        panel.showError(message)
    }

    // MARK: accessibility follow-up

    private func refreshAccessibilityState() {
        let trusted = Paster.trusted
        controller.accessibilityGranted = trusted
        if trusted { hotkey?.upgradeToSuppressingTap() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshMicrophoneState()
        controller.refreshInputMonitoringState()
        hotkey?.refreshCapsLockHold()
        refreshAccessibilityState()
    }

    // MARK: windows

    @objc private func showSettingsRequested() {
        DispatchQueue.main.async { [weak self] in self?.showSettings() }
    }

    private func showSettings() {
        guard let tray else { return }
        if settingsPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 360, height: 220)
            let host = NSHostingController(rootView: SettingsView(controller: controller))
            host.view.wantsLayer = true
            host.view.layer?.backgroundColor = NSColor.clear.cgColor
            popover.contentViewController = host
            popover.delegate = self
            settingsPopover = popover
        }
        NSApp.activate(ignoringOtherApps: true)
        tray.toggle(settingsPopover!)
        DispatchQueue.main.async { [weak self] in
            self?.settingsPopover?.contentViewController?.view.window?.makeKey()
        }
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        controller.cancelCapture()
    }
}

/// Borderless 400x120 panel used while the speech model downloads (the macOS
/// equivalent of the Linux setup window over index.html).
final class SetupPanel: NSPanel {
    private var content = SetupPanelContent()
    private var hostView: NSHostingView<SetupPanelView>?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        contentView = NSHostingView(rootView: SetupPanelView(content: content))
        center()
    }

    private var host: NSHostingView<SetupPanelView>? {
        contentView as? NSHostingView<SetupPanelView>
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setProgress(_ pct: Int) {
        content = SetupPanelContent(progress: pct, error: content.error)
        host?.rootView = SetupPanelView(content: content)
    }

    func showError(_ message: String) {
        content = SetupPanelContent(progress: content.progress, error: message)
        host?.rootView = SetupPanelView(content: content)
    }
}

struct SetupPanelContent {
    var progress: Int = -1
    var error: String?
}

struct SetupPanelView: View {
    var content: SetupPanelContent

    var body: some View {
        VStack(spacing: 12) {
            if let error = content.error {
                Text("Model download failed").font(.headline)
                Text(error).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if content.progress >= 0 {
                Text("Downloading speech model… \(content.progress)%").font(.headline)
                ProgressView(value: Double(content.progress), total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 300)
            } else {
                Text("Downloading speech model…").font(.headline)
                ProgressView()
            }
        }
        .padding(24)
        .frame(width: 400, height: 120)
        .background(VisualEffectView())
    }
}

private struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

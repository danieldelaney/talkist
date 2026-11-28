import AppKit

/// NSStatusItem + NSMenu + tray status state machine, ported from
/// run_tray_status_loop (main.rs): Transcribing is delayed 150 ms so fast
/// recognitions never flicker, and once shown it stays for at least 400 ms.
final class TrayController: NSObject, NSMenuDelegate {
    private static let transcribingDelay = 0.15
    private static let minTranscribingTime = 0.4

    private let item: NSStatusItem
    private let statusChannel: StatusChannel
    private let menu = NSMenu()
    private let versionItem: NSMenuItem
    private let statusItem: NSMenuItem
    private let updateItem: NSMenuItem
    private let separator = NSMenuItem.separator()
    private let settingsItem: NSMenuItem
    private let startAtLoginItem: NSMenuItem
    private let quitItem: NSMenuItem
    private var thread: Thread?

    var onMenuWillOpen: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onToggleStartAtLogin: (() -> Void)?
    var onInstallUpdate: (() -> Void)?
    var onQuit: (() -> Void)?

    init(statusChannel: StatusChannel, hotkey: String, startAtLogin: Bool) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusChannel = statusChannel

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        versionItem = NSMenuItem(title: "Talkist \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false

        statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.isHidden = true

        updateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        updateItem.isHidden = true

        settingsItem = NSMenuItem(title: "Hotkey: \(hotkey)", action: nil, keyEquivalent: "")
        startAtLoginItem = NSMenuItem(title: "Start at login", action: nil, keyEquivalent: "")
        startAtLoginItem.state = startAtLogin ? .on : .off
        quitItem = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "")

        super.init()

        updateItem.target = self
        updateItem.action = #selector(updateAction)
        settingsItem.target = self
        settingsItem.action = #selector(settingsAction)
        startAtLoginItem.target = self
        startAtLoginItem.action = #selector(startAtLoginAction)
        quitItem.target = self
        quitItem.action = #selector(quitAction)

        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(versionItem)
        menu.addItem(statusItem)
        menu.addItem(updateItem)
        menu.addItem(separator)
        menu.addItem(settingsItem)
        menu.addItem(startAtLoginItem)
        menu.addItem(quitItem)

        item.button?.image = Self.image(for: .idle)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Talkist"
        item.menu = menu

        let thread = Thread { [weak self] in self?.runTrayStatusLoop() }
        thread.name = "tray-status"
        self.thread = thread
        thread.start()
    }

    deinit {
        thread?.cancel()
    }

    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
    }

    func updateMenu(
        hotkey: String,
        startAtLogin: Bool,
        isFullyReady: Bool,
        modelStatus: String?,
        modelError: String?,
        updateVersion: String?,
        updateProgress: String?,
        updateFailed: Bool
    ) {
        if let modelStatus {
            statusItem.title = modelStatus
            statusItem.isHidden = false
            settingsItem.title = "Finish Setup…"
        } else if let modelError {
            statusItem.title = "Setup error: \(modelError)"
            statusItem.isHidden = false
            settingsItem.title = "Finish Setup…"
        } else if !isFullyReady {
            statusItem.isHidden = true
            settingsItem.title = "Finish Setup…"
        } else {
            statusItem.isHidden = true
            settingsItem.title = "Hotkey: \(hotkey)"
        }

        startAtLoginItem.state = startAtLogin ? .on : .off

        if let progress = updateProgress {
            updateItem.title = progress
            updateItem.isEnabled = false
            updateItem.isHidden = false
        } else if let version = updateVersion {
            updateItem.title = updateFailed ? "Update to \(version) (retry)" : "Update to \(version)"
            updateItem.isEnabled = true
            updateItem.isHidden = false
        } else {
            updateItem.isHidden = true
        }
    }

    @objc private func settingsAction() { onOpenSettings?() }
    @objc private func startAtLoginAction() { onToggleStartAtLogin?() }
    @objc private func updateAction() { onInstallUpdate?() }
    @objc private func quitAction() { onQuit?() }

    private static func image(for status: Status) -> NSImage? {
        let name: String
        switch status {
        case .idle: name = "StatusIdle"
        case .recording: name = "StatusRecording"
        case .transcribing: name = "StatusTranscribing"
        case .downloading: name = "StatusDownloading"
        }
        let img = NSImage(named: name)
        img?.isTemplate = true
        return img
    }

    private static func recordingImage(for appearance: NSAppearance?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let draw = {
                let s: CGFloat = 18
                let outer = CGRect(x: s * 0.10, y: s * 0.16, width: s * 0.80, height: s * 0.68)
                let inner = outer.insetBy(dx: s * 0.075, dy: s * 0.075)
                let frame = NSBezierPath(roundedRect: outer, xRadius: s * 0.19, yRadius: s * 0.19)
                frame.append(NSBezierPath(roundedRect: inner, xRadius: s * 0.13, yRadius: s * 0.13))
                frame.windingRule = .evenOdd
                NSColor.labelColor.setFill()
                frame.fill()

                let r = s * 0.135
                let dot = CGRect(x: outer.midX - r, y: outer.midY - r, width: r * 2, height: r * 2)
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            if let appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private func setTrayStatus(_ status: Status) {
        let tooltip: String
        switch status {
        case .idle: tooltip = "Talkist"
        case .recording: tooltip = "Recording..."
        case .transcribing: tooltip = "Transcribing..."
        case .downloading: tooltip = "Downloading speech model..."
        }
        DispatchQueue.main.async { [item] in
            if status == .recording {
                item.button?.image = Self.recordingImage(for: item.button?.effectiveAppearance)
            } else {
                item.button?.image = Self.image(for: status)
            }
            item.button?.toolTip = tooltip
        }
    }

    private func runTrayStatusLoop() {
        var displayed = Status.idle
        var pending: (Status, Date)?
        var transcribingSince: Date?

        while true {
            var event: Status?
            var timedOut = false
            if let (_, deadline) = pending {
                let wait = max(0, deadline.timeIntervalSinceNow)
                if let status = statusChannel.recv(timeout: wait) { event = status } else { timedOut = true }
            } else {
                guard let status = statusChannel.recv(timeout: nil) else { break }
                event = status
            }

            if let status = event {
                let now = Date()
                switch status {
                case .recording, .downloading:
                    pending = nil
                    transcribingSince = nil
                    if displayed != status {
                        setTrayStatus(status)
                        displayed = status
                    }
                case .transcribing:
                    if displayed != .transcribing {
                        pending = (status, now.addingTimeInterval(Self.transcribingDelay))
                    }
                case .idle:
                    if pending?.0 == .transcribing {
                        pending = nil
                        transcribingSince = nil
                    } else if displayed == .transcribing {
                        let deadline = (transcribingSince ?? now).addingTimeInterval(Self.minTranscribingTime)
                        if deadline > now {
                            pending = (status, deadline)
                            continue
                        }
                    } else {
                        pending = nil
                    }
                    if displayed != status {
                        setTrayStatus(status)
                        displayed = status
                    }
                }
                continue
            }

            guard timedOut, let (status, _) = pending else { continue }
            pending = nil
            setTrayStatus(status)
            displayed = status
            transcribingSince = (status == .transcribing) ? Date() : nil
        }
    }
}

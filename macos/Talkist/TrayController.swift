import AppKit

/// NSStatusItem + the tray status state machine, ported from
/// run_tray_status_loop (main.rs): Transcribing is delayed 150 ms so fast
/// recognitions never flicker, and once shown it stays for at least 400 ms.
final class TrayController: NSObject {
    private static let transcribingDelay = 0.15
    private static let minTranscribingTime = 0.4

    private let item: NSStatusItem
    private let statusChannel: StatusChannel
    private var thread: Thread?

    var onSettings: (() -> Void)?

    init(statusChannel: StatusChannel) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusChannel = statusChannel
        super.init()

        item.button?.image = Self.image(for: .idle)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Talkist"
        item.button?.target = self
        item.button?.action = #selector(settingsAction)

        let thread = Thread { [weak self] in self?.runTrayStatusLoop() }
        thread.name = "tray-status"
        self.thread = thread
        thread.start()
    }

    deinit {
        thread?.cancel()
    }

    @objc private func settingsAction() { onSettings?() }

    func toggle(_ popover: NSPopover) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
            let appearance = NSAppearance(named: name)
            popover.appearance = appearance
            popover.contentViewController?.view.appearance = appearance
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private static func image(for status: Status) -> NSImage? {
        let name: String
        switch status {
        case .idle: name = "StatusIdle"
        case .recording: name = "StatusRecording"
        case .transcribing: name = "StatusTranscribing"
        }
        let img = NSImage(named: name)
        img?.isTemplate = true
        return img
    }

    private func setTrayStatus(_ status: Status) {
        let image = Self.image(for: status)
        let tooltip: String
        switch status {
        case .idle: tooltip = "Talkist"
        case .recording: tooltip = "Recording..."
        case .transcribing: tooltip = "Transcribing..."
        }
        DispatchQueue.main.async { [item] in
            item.button?.image = image
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
                case .recording:
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

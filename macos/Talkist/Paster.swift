import AppKit
import CoreGraphics

/// Clipboard handle + key synthesizer. Snapshots the user's clipboard, copies
/// the transcript, posts a synthetic Cmd+V at the cursor (requires
/// Accessibility), and restores the previous clipboard contents.
enum Paster {
    static var trusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptIfNeeded() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    @discardableResult
    static func paste(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else {
            logStderr("paste skipped: accessibility permission not granted")
            return false
        }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        let pasteChangeCount = pb.changeCount

        Thread.sleep(forTimeInterval: 0.02)
        let v = CGKeyCode(0x09) // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: false) else {
            restore(saved, to: pb, expectedChangeCount: pasteChangeCount)
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)

        // Give the target app time to read the pasted string before restoring
        // the previous clipboard; skip if something else wrote to it since.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            restore(saved, to: pb, expectedChangeCount: pasteChangeCount)
        }
        return true
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var map: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type] = data
                }
            }
            return map
        }
    }

    private static func restore(
        _ saved: [[NSPasteboard.PasteboardType: Data]],
        to pb: NSPasteboard,
        expectedChangeCount: Int
    ) {
        guard pb.changeCount == expectedChangeCount else { return }
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.compactMap { map in
            guard !map.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in map {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pb.writeObjects(items)
        }
    }
}

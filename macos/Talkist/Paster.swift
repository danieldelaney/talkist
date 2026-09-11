import AppKit
import CoreGraphics

/// Clipboard handle + key synthesizer. Copy the text, then post a synthetic
/// Cmd+V at the cursor (requires Accessibility for the user process).
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Thread.sleep(forTimeInterval: 0.02)
        let v = CGKeyCode(0x09) // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        return true
    }
}
import AppKit
import CoreGraphics
import IOKit
import IOKit.hid

// Global shortcut + push-to-talk edge detection.
//
// The tap listens for keyDown/keyUp/flagsChanged/systemDefined:
// - Regular keys: keyDown starts, keyUp releases.
// - CapsLock (kVK_CapsLock): macOS reports only flagsChanged events, and the
//   flags field carries the caps *state*, which never changes once the event
//   is suppressed. Since CapsLock never autorepeats, every physical press is
//   exactly one make + one break event, so direction is recovered by
//   alternation (first event = press, second = release). Suppression
//   (returning nil) keeps the OS from toggling the caps state/LED.
// - F-keys in media mode: with "Use F1, F2 as standard function keys" off,
//   bare F9 emits an NX media systemDefined event (NX_KEYTYPE_FAST), not
//   kVK_F9. Those are mapped too so the default hotkey works on stock macOS.
struct Shortcut: Equatable {
    static let capsLockCode: CGKeyCode = 0x39

    static let modifierOrder: [(String, CGEventFlags)] = [
        ("Ctrl", .maskControl), ("Alt", .maskAlternate), ("Shift", .maskShift), ("Super", .maskCommand),
    ]

    static let keyTable: [(String, CGKeyCode)] = [
        ("F1", 0x7A), ("F2", 0x78), ("F3", 0x63), ("F4", 0x76), ("F5", 0x60),
        ("F6", 0x61), ("F7", 0x62), ("F8", 0x64), ("F9", 0x65), ("F10", 0x6D),
        ("F11", 0x67), ("F12", 0x6F),
        ("CapsLock", 0x39), ("Space", 0x31),
        ("A", 0x00), ("S", 0x01), ("D", 0x02), ("F", 0x03), ("H", 0x04), ("G", 0x05),
        ("Z", 0x06), ("X", 0x07), ("C", 0x08), ("V", 0x09), ("B", 0x0B), ("Q", 0x0C),
        ("W", 0x0D), ("E", 0x0E), ("R", 0x0F), ("Y", 0x10), ("T", 0x11),
        ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16), ("5", 0x17),
        ("9", 0x19), ("7", 0x1A), ("8", 0x1C), ("0", 0x1D),
        ("O", 0x1F), ("U", 0x20), ("I", 0x22), ("P", 0x23), ("L", 0x25), ("J", 0x26),
        ("K", 0x28), ("N", 0x2D), ("M", 0x2E),
    ]

    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
    let text: String

    static func parse(_ string: String) -> Shortcut? {
        let parts = string.split(separator: "+").map(String.init)
        guard let keyPart = parts.last, !parts.isEmpty else { return nil }
        var modifiers: CGEventFlags = []
        var mods = 0
        for part in parts.dropLast() {
            guard let idx = modifierOrder.firstIndex(where: { $0.0 == part }), idx >= mods else { return nil }
            modifiers.insert(modifierOrder[idx].1)
            mods += 1
        }
        guard let (_, code) = keyTable.first(where: { $0.0 == keyPart }) else { return nil }
        return canonical(keyCode: code, modifiers: modifiers)
    }

    static func canonical(keyCode: CGKeyCode, modifiers: CGEventFlags) -> Shortcut {
        let keyName = keyTable.first(where: { $0.1 == keyCode })?.0 ?? "Key\(keyCode)"
        var names: [String] = []
        var mods: CGEventFlags = []
        for (name, flag) in modifierOrder where modifiers.contains(flag) {
            names.append(name)
            mods.insert(flag)
        }
        names.append(keyName)
        return Shortcut(keyCode: keyCode, modifiers: mods, text: names.joined(separator: "+"))
    }

    static func keyName(forCode code: CGKeyCode) -> String? {
        keyTable.first(where: { $0.1 == code })?.0
    }

    /// NX media keycode (IOKit ev_keymap.h) matching this shortcut's F-key,
    /// if any. Bare F-keys arrive as these events when the fn-row is in
    /// media mode (the macOS default).
    var mediaKeyCode: Int? {
        switch keyCode {
        case 0x7A: return 3   // F1 -> brightness down
        case 0x78: return 2   // F2 -> brightness up
        case 0x62: return 20  // F7 -> rewind
        case 0x64: return 16  // F8 -> play
        case 0x65: return 19  // F9 -> fast
        case 0x6D: return 7   // F10 -> mute
        case 0x67: return 1   // F11 -> sound down
        case 0x6F: return 0   // F12 -> sound up
        default: return nil
        }
    }
}

final class Hotkey {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var shortcut: Shortcut
    private var capsArmed = false
    private var capsHold: CapsLockHold?
    private var suppresses = false
    private var captureHandler: ((Shortcut?) -> Void)?

    private static let NXSystemDefined: CGEventType = CGEventType(rawValue: 14)!

    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
    }

    /// Installs the tap. Returns false if even a listen-only tap failed.
    /// A listen-only tap still delivers press/release (PTT works) but cannot
    /// swallow CapsLock or media events; it is upgraded once Accessibility is
    /// granted (`upgradeToSuppressingTap`).
    @discardableResult
    func install() -> Bool {
        startCapsHoldIfNeeded()
        if installTap(options: .defaultTap) {
            suppresses = true
            return true
        }
        return installTap(options: .listenOnly)
    }

    @discardableResult
    func upgradeToSuppressingTap() -> Bool {
        guard !suppresses else { return true }
        guard installTap(options: .defaultTap) else { return false }
        suppresses = true
        return true
    }

    private func installTap(options: CGEventTapOptions) -> Bool {
        uninstall()
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << 14) // NX_SYSTEMDEFINED (media events)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Hotkey.trampoline(type: type, event: event, refcon: refcon)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func uninstall() {
        capsHold?.stop()
        capsHold = nil
        capsArmed = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
    }

    func beginCapture(_ handler: @escaping (Shortcut?) -> Void) {
        captureHandler = handler
        capsArmed = false
    }

    func cancelCapture() {
        captureHandler = nil
    }

    func setShortcut(_ shortcut: Shortcut) {
        capsHold?.stop()
        capsHold = nil
        self.shortcut = shortcut
        capsArmed = false
        startCapsHoldIfNeeded()
    }

    func refreshCapsLockHold() {
        guard shortcut.keyCode == Shortcut.capsLockCode else { return }
        capsHold?.stop()
        startCapsHoldIfNeeded()
    }

    private static func trampoline(type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue()
        return me.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system can disable a tap on timeout; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if captureHandler != nil {
            if type == .flagsChanged, code == Int64(Shortcut.capsLockCode) {
                finishCapture(Shortcut.canonical(keyCode: Shortcut.capsLockCode, modifiers: []))
                return suppresses ? nil : Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                if code == 0x35 { // Escape
                    finishCapture(nil)
                    return suppresses ? nil : Unmanaged.passUnretained(event)
                }
                let keyCode = CGKeyCode(code)
                if Shortcut.keyName(forCode: keyCode) != nil {
                    let relevant = CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand])
                    finishCapture(Shortcut.canonical(keyCode: keyCode, modifiers: event.flags.intersection(relevant)))
                    return suppresses ? nil : Unmanaged.passUnretained(event)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == Hotkey.NXSystemDefined, let media = shortcut.mediaKeyCode {
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = (ns.data1 & 0xFFFF0000) >> 16
            let state = (ns.data1 & 0xFF00) >> 8
            guard keyCode == media else { return Unmanaged.passUnretained(event) }
            if state == 0xA { firePressed() } else if state == 0xB { fireReleased() }
            return suppresses ? nil : Unmanaged.passUnretained(event)
        }

        guard code == Int64(shortcut.keyCode) else { return Unmanaged.passUnretained(event) }

        if shortcut.keyCode == Shortcut.capsLockCode {
            CapsLockHold.forceCapsLockOff()
            return suppresses ? nil : Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            if modifiersMatch(event) { firePressed() }
            return Unmanaged.passUnretained(event)
        case .keyUp:
            if modifiersMatch(event) { fireReleased() }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func modifiersMatch(_ event: CGEvent) -> Bool {
        let relevant = CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        return event.flags.intersection(relevant) == shortcut.modifiers.intersection(relevant)
    }

    private func firePressed() {
        DispatchQueue.main.async { [weak self] in self?.onPressed?() }
    }

    private func fireReleased() {
        DispatchQueue.main.async { [weak self] in self?.onReleased?() }
    }

    private func finishCapture(_ shortcut: Shortcut?) {
        let handler = captureHandler
        captureHandler = nil
        DispatchQueue.main.async { handler?(shortcut) }
    }

    private func startCapsHoldIfNeeded() {
        guard shortcut.keyCode == Shortcut.capsLockCode else { return }
        let hold = CapsLockHold(onPress: { [weak self] in self?.onPressed?() },
                                onRelease: { [weak self] in self?.onReleased?() })
        capsHold = hold
        hold.start()
    }
}

final class CapsLockHold {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var manager: IOHIDManager?
    private var down = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        stop()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(
            manager, CapsLockHold.valueCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            logStderr("CapsLock: IOHIDManagerOpen failed (\(result)); Input Monitoring required")
        }
        self.manager = manager
        Self.forceCapsLockOff()
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(
                manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        if down {
            down = false
            onRelease()
        }
    }

    private static let valueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let me = Unmanaged<CapsLockHold>.fromOpaque(context).takeUnretainedValue()
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
              IOHIDElementGetUsage(element) == UInt32(kHIDUsage_KeyboardCapsLock) else { return }
        me.handle(pressed: IOHIDValueGetIntegerValue(value) != 0)
    }

    private func handle(pressed: Bool) {
        Self.forceCapsLockOff()
        if pressed, !down {
            down = true
            DispatchQueue.main.async { [onPress] in onPress() }
        } else if !pressed, down {
            down = false
            DispatchQueue.main.async { [onRelease] in onRelease() }
        }
    }

    static func forceCapsLockOff() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let result = IOServiceOpen(
            service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection)
        guard result == kIOReturnSuccess else { return }
        defer { IOServiceClose(connection) }
        IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false)
    }
}

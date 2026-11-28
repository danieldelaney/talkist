import AppKit
import CoreGraphics
import IOKit
import IOKit.hid

// Global shortcut + push-to-talk edge detection.
//
// The tap listens for keyDown/keyUp/flagsChanged/systemDefined:
// - Regular keys (including punctuation): keyDown starts, keyUp releases.
// - Lone modifier keys (Fn/Globe, Right/Left Option, Command, Control, Shift):
//   flagsChanged press starts, flagsChanged release stops.
// - CapsLock (kVK_CapsLock): IOKit HID hold detection + lock-state reset so
//   CapsLock never toggles caps on.
// - F-keys in media mode: with "Use F1, F2 as standard function keys" off,
//   bare F9 emits an NX media systemDefined event (NX_KEYTYPE_FAST), not
//   kVK_F9. Those are mapped too so the default hotkey works on stock macOS.
struct Shortcut: Equatable {
    static let capsLockCode: CGKeyCode = 0x39

    struct ModifierKeyEntry {
        let name: String
        let displayName: String
        let code: CGKeyCode
        let flag: CGEventFlags
        let deviceBit: UInt64
        let pairMask: UInt64
    }

    static let modifierOrder: [(String, CGEventFlags)] = [
        ("Ctrl", .maskControl), ("Alt", .maskAlternate), ("Shift", .maskShift), ("Super", .maskCommand),
    ]

    static let displayModifierOrder: [(String, CGEventFlags)] = [
        ("Control", .maskControl), ("Option", .maskAlternate), ("Shift", .maskShift), ("Command", .maskCommand),
    ]

    static let modifierKeyTable: [ModifierKeyEntry] = [
        ModifierKeyEntry(name: "Fn", displayName: "Fn", code: 0x3F, flag: .maskSecondaryFn, deviceBit: 0, pairMask: 0),
        ModifierKeyEntry(name: "RightOption", displayName: "Right Option", code: 0x3D, flag: .maskAlternate, deviceBit: 0x40, pairMask: 0x20 | 0x40),
        ModifierKeyEntry(name: "LeftOption", displayName: "Left Option", code: 0x3A, flag: .maskAlternate, deviceBit: 0x20, pairMask: 0x20 | 0x40),
        ModifierKeyEntry(name: "RightCommand", displayName: "Right Command", code: 0x36, flag: .maskCommand, deviceBit: 0x10, pairMask: 0x08 | 0x10),
        ModifierKeyEntry(name: "LeftCommand", displayName: "Left Command", code: 0x37, flag: .maskCommand, deviceBit: 0x08, pairMask: 0x08 | 0x10),
        ModifierKeyEntry(name: "RightControl", displayName: "Right Control", code: 0x3E, flag: .maskControl, deviceBit: 0x2000, pairMask: 0x01 | 0x2000),
        ModifierKeyEntry(name: "LeftControl", displayName: "Left Control", code: 0x3B, flag: .maskControl, deviceBit: 0x01, pairMask: 0x01 | 0x2000),
        ModifierKeyEntry(name: "RightShift", displayName: "Right Shift", code: 0x3C, flag: .maskShift, deviceBit: 0x04, pairMask: 0x02 | 0x04),
        ModifierKeyEntry(name: "LeftShift", displayName: "Left Shift", code: 0x38, flag: .maskShift, deviceBit: 0x02, pairMask: 0x02 | 0x04),
    ]

    static let fKeyCodes: Set<CGKeyCode> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
    ]

    static let keyTable: [(String, CGKeyCode)] = [
        ("F1", 0x7A), ("F2", 0x78), ("F3", 0x63), ("F4", 0x76), ("F5", 0x60),
        ("F6", 0x61), ("F7", 0x62), ("F8", 0x64), ("F9", 0x65), ("F10", 0x6D),
        ("F11", 0x67), ("F12", 0x6F),
        ("CapsLock", 0x39), ("Space", 0x31),
        ("`", 0x32), ("-", 0x1B), ("=", 0x18), ("[", 0x21), ("]", 0x1E),
        ("\\", 0x2A), (";", 0x29), ("'", 0x27), (",", 0x2B), (".", 0x2F), ("/", 0x2C),
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

    var isModifierKey: Bool {
        Self.isModifierKey(keyCode)
    }

    var displayText: String {
        if let entry = Self.modifierKeyTable.first(where: { $0.code == keyCode }) {
            return entry.displayName
        }
        let keyName: String
        if keyCode == Self.capsLockCode {
            keyName = "Caps Lock"
        } else {
            keyName = Self.keyTable.first(where: { $0.1 == keyCode })?.0 ?? "Key\(keyCode)"
        }
        var names: [String] = []
        for (name, flag) in Self.displayModifierOrder where modifiers.contains(flag) {
            names.append(name)
        }
        names.append(keyName)
        return names.joined(separator: "+")
    }

    static func displayText(for stored: String) -> String {
        parse(stored)?.displayText ?? stored
    }

    static func isFKey(_ code: CGKeyCode) -> Bool {
        fKeyCodes.contains(code)
    }

    static func isModifierKey(_ code: CGKeyCode) -> Bool {
        modifierKeyTable.contains(where: { $0.code == code })
    }

    static func modifierFlag(for code: CGKeyCode) -> CGEventFlags? {
        modifierKeyTable.first(where: { $0.code == code })?.flag
    }

    static func isModifierKeyDown(code: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let entry = modifierKeyTable.first(where: { $0.code == code }) else { return false }
        if entry.pairMask != 0 && (flags.rawValue & entry.pairMask) != 0 {
            return (flags.rawValue & entry.deviceBit) != 0
        }
        return flags.contains(entry.flag)
    }

    static func parse(_ string: String) -> Shortcut? {
        if let entry = modifierKeyTable.first(where: { $0.name == string }) {
            return canonical(keyCode: entry.code, modifiers: [])
        }
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
        if let entry = modifierKeyTable.first(where: { $0.code == keyCode }) {
            return Shortcut(keyCode: keyCode, modifiers: [], text: entry.name)
        }
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
            ?? modifierKeyTable.first(where: { $0.code == code })?.name
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

    static func fKeyCode(forMediaKey mediaKey: Int) -> CGKeyCode? {
        switch mediaKey {
        case 3:  return 0x7A // F1
        case 2:  return 0x78 // F2
        case 20: return 0x62 // F7
        case 16: return 0x64 // F8
        case 19: return 0x65 // F9
        case 7:  return 0x6D // F10
        case 1:  return 0x67 // F11
        case 0:  return 0x6F // F12
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
    private var keyDown = false
    private var pendingTapFlags: CGEventFlags?
    private var holdTimer: DispatchWorkItem?
    private var passThroughKeyUp = false
    private var modifierDown = false
    private var pendingModifierCapture: CGKeyCode?
    private var swallowKeyUpCode: CGKeyCode?
    private var suppresses = false
    private var captureHandler: ((Shortcut?) -> Void)?

    private static let NXSystemDefined: CGEventType = CGEventType(rawValue: 14)!
    private static let holdThreshold: TimeInterval = 0.2
    private static let replayTag: Int64 = 0x54414C4B // "TALK"

    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?
    var isTapActive: Bool { tap != nil }

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

    private func resetKeyState() {
        holdTimer?.cancel()
        holdTimer = nil
        pendingTapFlags = nil
        passThroughKeyUp = false
        if keyDown {
            keyDown = false
            fireReleased()
        }
    }

    func uninstall() {
        capsHold?.stop()
        capsHold = nil
        capsArmed = false
        resetKeyState()
        if modifierDown {
            modifierDown = false
            fireReleased()
        }
        pendingModifierCapture = nil
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
        pendingModifierCapture = nil
        resetKeyState()
        if modifierDown {
            modifierDown = false
            fireReleased()
        }
    }

    func cancelCapture() {
        captureHandler = nil
        pendingModifierCapture = nil
    }

    func setShortcut(_ shortcut: Shortcut) {
        capsHold?.stop()
        capsHold = nil
        resetKeyState()
        if modifierDown {
            modifierDown = false
            fireReleased()
        }
        pendingModifierCapture = nil
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

        // Let our own replayed tap events pass straight through.
        if event.getIntegerValueField(.eventSourceUserData) == Hotkey.replayTag {
            return Unmanaged.passUnretained(event)
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, let swallow = swallowKeyUpCode, code == Int64(swallow) {
            swallowKeyUpCode = nil
            return suppresses ? nil : Unmanaged.passUnretained(event)
        }
        if captureHandler != nil {
            if type == Hotkey.NXSystemDefined {
                guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                    return Unmanaged.passUnretained(event)
                }
                let mediaKey = (ns.data1 & 0xFFFF0000) >> 16
                let state = (ns.data1 & 0xFF00) >> 8
                if state == 0xA, let fKey = Shortcut.fKeyCode(forMediaKey: mediaKey) {
                    pendingModifierCapture = nil
                    finishCapture(Shortcut.canonical(keyCode: fKey, modifiers: []))
                    return suppresses ? nil : Unmanaged.passUnretained(event)
                }
                return Unmanaged.passUnretained(event)
            }
            if type == .flagsChanged {
                if code == Int64(Shortcut.capsLockCode) {
                    pendingModifierCapture = nil
                    finishCapture(Shortcut.canonical(keyCode: Shortcut.capsLockCode, modifiers: []))
                    return suppresses ? nil : Unmanaged.passUnretained(event)
                }
                let keyCode = CGKeyCode(code)
                if Shortcut.isModifierKey(keyCode) {
                    if Shortcut.isModifierKeyDown(code: keyCode, flags: event.flags) {
                        let allMods = CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn])
                        let ownFlag = Shortcut.modifierFlag(for: keyCode) ?? []
                        let otherMods = event.flags.intersection(allMods).subtracting(ownFlag)
                        if otherMods.isEmpty && pendingModifierCapture == nil {
                            pendingModifierCapture = keyCode
                        } else {
                            pendingModifierCapture = nil
                        }
                    } else if pendingModifierCapture == keyCode {
                        pendingModifierCapture = nil
                        finishCapture(Shortcut.canonical(keyCode: keyCode, modifiers: []))
                    }
                    return Unmanaged.passUnretained(event)
                }
            }
            if type == .keyDown {
                pendingModifierCapture = nil
                if code == 0x35 { // Escape
                    swallowKeyUpCode = 0x35
                    finishCapture(nil)
                    return suppresses ? nil : Unmanaged.passUnretained(event)
                }
                let keyCode = CGKeyCode(code)
                if Shortcut.keyTable.contains(where: { $0.1 == keyCode }) {
                    let relevant = CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand])
                    swallowKeyUpCode = keyCode
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

        // Rollover typing: if another key is pressed before the hold threshold
        // expires, treat the pending hotkey press as a normal tap immediately.
        if type == .keyDown, let flags = pendingTapFlags, code != Int64(shortcut.keyCode) {
            holdTimer?.cancel()
            holdTimer = nil
            pendingTapFlags = nil
            passThroughKeyUp = true
            postKeyEvent(code: shortcut.keyCode, flags: flags, keyDown: true)
            return Unmanaged.passUnretained(event)
        }

        guard code == Int64(shortcut.keyCode) else { return Unmanaged.passUnretained(event) }

        if shortcut.keyCode == Shortcut.capsLockCode {
            CapsLockHold.forceCapsLockOff()
            return suppresses ? nil : Unmanaged.passUnretained(event)
        }

        if shortcut.isModifierKey {
            guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            let down = Shortcut.isModifierKeyDown(code: shortcut.keyCode, flags: event.flags)
            if down, !modifierDown {
                modifierDown = true
                firePressed()
            } else if !down, modifierDown {
                modifierDown = false
                fireReleased()
            }
            return Unmanaged.passUnretained(event)
        }

        if !suppresses {
            switch type {
            case .keyDown:
                if modifiersMatch(event), !keyDown {
                    keyDown = true
                    firePressed()
                }
            case .keyUp:
                if keyDown {
                    keyDown = false
                    fireReleased()
                }
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            if keyDown || pendingTapFlags != nil {
                return nil
            }
            if modifiersMatch(event) {
                passThroughKeyUp = false
                pendingTapFlags = event.flags
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.pendingTapFlags != nil else { return }
                    self.pendingTapFlags = nil
                    self.holdTimer = nil
                    self.keyDown = true
                    self.firePressed()
                }
                holdTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Hotkey.holdThreshold, execute: work)
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .keyUp:
            if passThroughKeyUp {
                passThroughKeyUp = false
                return Unmanaged.passUnretained(event)
            }
            if let flags = pendingTapFlags {
                holdTimer?.cancel()
                holdTimer = nil
                pendingTapFlags = nil
                postKeyEvent(code: shortcut.keyCode, flags: flags, keyDown: true)
                postKeyEvent(code: shortcut.keyCode, flags: event.flags, keyDown: false)
                return nil
            }
            if keyDown {
                keyDown = false
                fireReleased()
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func postKeyEvent(code: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: keyDown) else { return }
        ev.flags = flags
        ev.setIntegerValueField(.eventSourceUserData, value: Hotkey.replayTag)
        ev.post(tap: .cgSessionEventTap)
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
        pendingModifierCapture = nil
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

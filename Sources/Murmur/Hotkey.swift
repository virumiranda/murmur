import AppKit
import CoreGraphics

/// Marks events Murmur posts itself (the synthetic Cmd-V) so the tap ignores them.
let murmurEventTag: Int64 = 0x4D55524D // "MURM"

struct HotkeySpec: Equatable {
    enum Kind: Equatable {
        /// A lone modifier key, detected through its device-specific flag bit.
        case modifier(mask: UInt64)
        /// A regular key plus exact modifiers. Swallowed so it never reaches the focused app.
        case combo(keyCode: Int64, modifiers: CGEventFlags)
    }

    let kind: Kind
    let display: String

    struct ParseError: LocalizedError {
        let input: String
        var errorDescription: String? { "Unknown hotkey \"\(input)\"" }
    }

    // Device-dependent modifier bits (NX_DEVICE*KEYMASK) tell left from right.
    private static let modifierKeys: [String: (mask: UInt64, display: String)] = [
        "fn": (CGEventFlags.maskSecondaryFn.rawValue, "fn"),
        "globe": (CGEventFlags.maskSecondaryFn.rawValue, "fn"),
        "rightcommand": (0x10, "Right ⌘"), "rightcmd": (0x10, "Right ⌘"),
        "leftcommand": (0x08, "Left ⌘"), "leftcmd": (0x08, "Left ⌘"),
        "rightoption": (0x40, "Right ⌥"), "rightopt": (0x40, "Right ⌥"), "rightalt": (0x40, "Right ⌥"),
        "leftoption": (0x20, "Left ⌥"), "leftopt": (0x20, "Left ⌥"), "leftalt": (0x20, "Left ⌥"),
        "rightcontrol": (0x2000, "Right ⌃"), "rightctrl": (0x2000, "Right ⌃"),
        "leftcontrol": (0x01, "Left ⌃"), "leftctrl": (0x01, "Left ⌃"),
        "rightshift": (0x04, "Right ⇧"), "leftshift": (0x02, "Left ⇧"),
    ]

    private static let comboModifiers: [String: (flag: CGEventFlags, display: String)] = [
        "cmd": (.maskCommand, "⌘"), "command": (.maskCommand, "⌘"),
        "ctrl": (.maskControl, "⌃"), "control": (.maskControl, "⌃"),
        "opt": (.maskAlternate, "⌥"), "option": (.maskAlternate, "⌥"), "alt": (.maskAlternate, "⌥"),
        "shift": (.maskShift, "⇧"),
        "fn": (.maskSecondaryFn, "fn "),
    ]

    // Physical (ANSI) key codes.
    private static let keyCodes: [String: Int64] = {
        var map: [String: Int64] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
            "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "grave": 50,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let fKeys: [Int64] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                              105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in fKeys.enumerated() { map["f\(i + 1)"] = code }
        return map
    }()

    static func parse(_ raw: String) throws -> HotkeySpec {
        let s = raw.lowercased().replacingOccurrences(of: " ", with: "")
        let flat = s.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        if let m = modifierKeys[flat] {
            return HotkeySpec(kind: .modifier(mask: m.mask), display: m.display)
        }
        let parts = s.split(separator: "+").map(String.init)
        guard let keyName = parts.last, let code = keyCodes[keyName] else {
            throw ParseError(input: raw)
        }
        var flags: CGEventFlags = []
        var display = ""
        for name in parts.dropLast() {
            guard let m = comboModifiers[name] else { throw ParseError(input: raw) }
            flags.insert(m.flag)
            display += m.display
        }
        display += keyName.count == 1 ? keyName.uppercased() : keyName.capitalized
        return HotkeySpec(kind: .combo(keyCode: code, modifiers: flags), display: display)
    }

    var isModifierOnly: Bool {
        if case .modifier = kind { return true }
        return false
    }
}

enum HotkeyEvent {
    case down, up
    /// Another key was pressed while a modifier hotkey was held: it's a shortcut, not dictation.
    case chord
    case escape
}

/// Watches the keyboard through a CGEvent tap on its own thread.
/// Modifier hotkeys (like fn) use a listen-only tap, so nothing is ever intercepted.
/// Combo hotkeys need an active tap to swallow the combo; every other key, including Esc, passes through untouched.
final class HotkeyMonitor {
    let spec: HotkeySpec
    private let onEvent: (HotkeyEvent) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    // Only touched on the tap thread.
    private var held = false
    private var chordSent = false
    private var comboDown = false
    /// Whether fn is physically down. macOS also sets the fn flag on arrows, F-keys and Home/End,
    /// so combos read fn from flagsChanged instead of from the key event.
    private var fnHeld = false
    private var lastFlags: UInt64 = 0

    private static let relevantComboFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
    private static let anyModifier: UInt64 = CGEventFlags([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).rawValue

    init(spec: HotkeySpec, onEvent: @escaping (HotkeyEvent) -> Void) {
        self.spec = spec
        self.onEvent = onEvent
    }

    /// Returns false if macOS refused the tap (Accessibility / Input Monitoring not granted yet).
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(info!).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: spec.isModifierOnly ? .listenOnly : .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(self.runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "murmur.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        ready.wait()
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    private func emit(_ e: HotkeyEvent) {
        DispatchQueue.main.async { self.onEvent(e) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == murmurEventTag { return pass }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type == .keyDown, keyCode == 53, !isRepeat {
            emit(.escape)
            return pass
        }

        switch spec.kind {
        case .modifier(let mask):
            let flags = event.flags.rawValue
            if type == .flagsChanged {
                let nowHeld = flags & mask != 0
                if nowHeld != held {
                    held = nowHeld
                    chordSent = false
                    emit(nowHeld ? .down : .up)
                } else if held, (flags & ~lastFlags) & Self.anyModifier != 0 {
                    sendChord() // another modifier joined, e.g. fn+ctrl
                }
                lastFlags = flags
            } else if type == .keyDown, held, !isRepeat {
                sendChord()
            }
            return pass

        case .combo(let code, let modifiers):
            if type == .flagsChanged {
                fnHeld = event.flags.contains(.maskSecondaryFn)
                return pass
            }
            guard keyCode == code else { return pass }
            if type == .keyDown {
                var active = event.flags.intersection(Self.relevantComboFlags).subtracting(.maskSecondaryFn)
                if fnHeld { active.insert(.maskSecondaryFn) }
                if active == modifiers || (comboDown && isRepeat) {
                    if !isRepeat, !comboDown {
                        comboDown = true
                        emit(.down)
                    }
                    return nil
                }
            } else if type == .keyUp, comboDown {
                comboDown = false
                emit(.up)
                return nil
            }
            return pass
        }
    }

    private func sendChord() {
        guard !chordSent else { return }
        chordSent = true
        emit(.chord)
    }
}

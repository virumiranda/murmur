import AppKit
import AVFoundation
import ApplicationServices
import os
import ServiceManagement

/// Interface text: Spanish when the Mac's preferred language is Spanish, English otherwise.
func L(_ english: String, _ spanish: String) -> String { UILanguage.spanish ? spanish : english }

enum UILanguage {
    static let spanish = Locale.preferredLanguages.first?.hasPrefix("es") ?? false
}

enum Log {
    private static let logger = Logger(subsystem: "local.murmur", category: "app")
    /// Also print to stderr (CLI modes).
    static var echo = false

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        if echo { FileHandle.standardError.write(Data("\(message)\n".utf8)) }
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        if echo { FileHandle.standardError.write(Data("error: \(message)\n".utf8)) }
    }
}

enum Permissions {
    /// Needed to post Cmd-V / keystrokes, and for the active tap a combo hotkey uses.
    static var accessibility: Bool { AXIsProcessTrusted() }
    /// Needed for the listen-only keyboard tap (fn, Esc).
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Triggers the system prompts for anything not yet granted.
    static func requestMissing() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !inputMonitoring { CGRequestListenEventAccess() }
        if !accessibility {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case microphone = "Privacy_Microphone"
    }

    static func open(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            Log.error("Launch at login: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = L("Couldn't change Launch at Login", "No se pudo cambiar \"Abrir al iniciar sesión\"")
            alert.informativeText = "\(error.localizedDescription)\n\n" + L("Move Murmur.app to /Applications or ~/Applications and try again.",
                                                                     "Mové Murmur.app a Aplicaciones y probá de nuevo.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

/// Polls a file's modification date. Editors save in place or atomically; polling catches both.
final class FileWatcher {
    private var timer: Timer?
    private var lastStamp: Date?

    init(url: URL, interval: TimeInterval = 1.5, onChange: @escaping () -> Void) {
        func stamp() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        lastStamp = stamp()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = stamp()
            if now != self.lastStamp {
                self.lastStamp = now
                onChange()
            }
        }
    }

    deinit { timer?.invalidate() }
}

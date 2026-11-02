import AppKit
import SwiftUI

/// What the window shows about the app itself: hotkey, on/off, missing permissions, AI availability.
final class AppStatus: ObservableObject {
    @Published var hotkey = "fn"
    @Published var enabled = true
    @Published var listening = false
    @Published var missing: [Permissions.Pane] = []
    /// The vocabulary list in config.json (shown read-only in the dictionary).
    @Published var configVocabulary: [String] = []
    /// Name of the AI used for cleanup, Transforms and summaries; nil when there's no key.
    @Published var aiName: String?
}

/// Everything the window's sections work with.
struct AppModels {
    let history: HistoryStore
    let personalization: PersonalizationStore
    let notes: NotesStore
    let meeting: MeetingRecorder
    let transforms: TransformRunner
    let status: AppStatus
}

enum Section: String, CaseIterable, Identifiable, Hashable {
    case home, dictionary, style, transforms, scratchpad, notetaker
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L("Home", "Inicio")
        case .dictionary: return L("Dictionary", "Diccionario")
        case .style: return L("Style", "Estilo")
        case .transforms: return "Transforms"
        case .scratchpad: return L("Scratchpad", "Bloc de notas")
        case .notetaker: return L("Notetaker", "Tomador de notas")
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .dictionary: return "character.book.closed"
        case .style: return "textformat"
        case .transforms: return "wand.and.stars"
        case .scratchpad: return "note.text"
        case .notetaker: return "person.2.wave.2"
        }
    }
}

final class Navigation: ObservableObject {
    @Published var section: Section? = .home
}

/// Murmur's main window. While it's open Murmur shows in the Dock; closing it leaves just the menu bar icon.
final class MainWindow: NSObject, NSWindowDelegate {
    let models: AppModels
    let navigation = Navigation()
    /// Called when the window comes to the front (to refresh permission status).
    var onFocus: (() -> Void)?
    private var window: NSWindow?

    init(models: AppModels) {
        self.models = models
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ section: Section? = nil) {
        if let section { navigation.section = section }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onFocus?()
    }

    private func makeWindow() -> NSWindow {
        let root = MainView(models: models, navigation: navigation)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: root)
        window.title = "Murmur"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.setContentSize(NSSize(width: 980, height: 680))
        window.delegate = self
        if !window.setFrameUsingName("MurmurMain") { window.center() }
        window.setFrameAutosaveName("MurmurMain")
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) { onFocus?() }

    func windowWillClose(_ notification: Notification) {
        models.notes.flush()
        // Back to a menu bar app, and hand the focus to whatever was in front before.
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { NSApp.deactivate() }
    }

    /// The menu bar shown while the window is in front. The Edit menu makes copy, paste and undo work in text fields.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("About Murmur", "Acerca de Murmur"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide Murmur", "Ocultar Murmur"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: L("Hide Others", "Ocultar otros"),
                                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L("Show All", "Mostrar todo"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit Murmur", "Salir de Murmur"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "Murmur")

        let edit = NSMenu(title: L("Edit", "Edición"))
        edit.addItem(withTitle: L("Undo", "Deshacer"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo", "Rehacer"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut", "Cortar"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy", "Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste", "Pegar"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All", "Seleccionar todo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: edit.title)

        let windowMenu = NSMenu(title: L("Window", "Ventana"))
        windowMenu.addItem(withTitle: L("Close", "Cerrar"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L("Minimize", "Minimizar"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: windowMenu, title: windowMenu.title)
        NSApp.windowsMenu = windowMenu
        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

// MARK: - Root view

struct MainView: View {
    let models: AppModels
    @ObservedObject var navigation: Navigation
    @ObservedObject private var status: AppStatus
    @ObservedObject private var meeting: MeetingRecorder

    init(models: AppModels, navigation: Navigation) {
        self.models = models
        self.navigation = navigation
        self.status = models.status
        self.meeting = models.meeting
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.section) {
                ForEach(Section.allCases) { section in
                    Label {
                        HStack {
                            Text(section.title)
                            if section == .notetaker, meeting.isActive {
                                Spacer()
                                Circle().fill(Color.red).frame(width: 7, height: 7)
                            }
                        }
                    } icon: {
                        Image(systemName: section.icon)
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { SidebarStatus(status: status) }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.section ?? .home {
        case .home: HomeView(history: models.history, status: status)
        case .dictionary: DictionaryView(store: models.personalization, status: status)
        case .style: StyleView(store: models.personalization)
        case .transforms: TransformsView(store: models.personalization, runner: models.transforms, status: status)
        case .scratchpad: ScratchpadView(store: models.notes, status: status)
        case .notetaker: NotetakerView(recorder: models.meeting, notes: models.notes, status: status)
        }
    }
}

private struct SidebarStatus: View {
    @ObservedObject var status: AppStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 4)
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.system(size: 12, weight: .medium))
            }
            if status.enabled, status.missing.isEmpty, status.listening {
                Text(L("Hold \(status.hotkey) to dictate", "Mantené \(status.hotkey) para dictar"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else if let pane = status.missing.first {
                Button(L("Grant permissions…", "Dar permisos…")) { Permissions.open(pane) }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var color: Color {
        if !status.enabled { return .gray }
        return status.missing.isEmpty && status.listening ? .green : .orange
    }

    private var label: String {
        if !status.enabled { return L("Murmur is off", "Murmur está apagado") }
        if !status.missing.isEmpty || !status.listening { return L("Needs permissions", "Faltan permisos") }
        return L("Ready", "Listo")
    }
}

// MARK: - Shared building blocks

/// A section page: big title, a line of explanation, then the content, centered with a comfortable width.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: title, subtitle: subtitle)
                content
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 30)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 28, weight: .semibold, design: .serif))
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }
}

extension View {
    /// A rounded white (or dark gray) card.
    func card(padding: CGFloat = 0) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// A yellow strip explaining what's missing, with a button to fix it.
struct Notice: View {
    let text: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

/// A small icon button that shows a checkmark for a moment after copying.
struct CopyButton: View {
    let text: () -> String
    var label: String?
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            if let label {
                Label(copied ? L("Copied", "Copiado") : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
        }
        .help(L("Copy", "Copiar"))
    }
}

func searchField(_ text: Binding<String>, prompt: String) -> some View {
    HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
        TextField(prompt, text: text).textFieldStyle(.plain)
        if !text.wrappedValue.isEmpty {
            Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                .buttonStyle(.plain)
        }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
}

extension String {
    /// Case- and accent-insensitive "contains", for search boxes.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

enum Format {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    static let dayWithYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy")
        return f
    }()

    static let short: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM HH:mm")
        return f
    }()

    /// "Today", "Yesterday", "Monday 26 October".
    static func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("Today", "Hoy") }
        if cal.isDateInYesterday(date) { return L("Yesterday", "Ayer") }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        return (sameYear ? day : dayWithYear).string(from: date).capitalizedFirst
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func number(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

import AppKit
import NaturalLanguage

/// What you teach Murmur from its window: dictionary words, writing style per kind of app, and Transforms.
/// Saved in ~/.config/murmur/personalization.json. Main thread only.
final class PersonalizationStore: ObservableObject {
    struct Word: Codable, Identifiable, Equatable {
        var id = UUID()
        /// How it must be written: "Wispr Flow", "Mar del Plata", "juan.perez@gmail.com".
        var text: String
        /// Optional: what to replace with `text` when it shows up in a dictation ("wisper flow", "mi mail").
        var replaces: String?
        /// Picked up from one of your corrections rather than added by hand.
        var learned = false
        var date = Date()
    }

    enum Tone: String, Codable, CaseIterable, Identifiable {
        case formal, casual, veryCasual, excited
        var id: String { rawValue }

        var title: String {
            switch self {
            case .formal: return L("Formal", "Formal")
            case .casual: return L("Casual", "Casual")
            case .veryCasual: return L("Very casual", "Muy casual")
            case .excited: return L("Excited", "Entusiasta")
            }
        }

        var detail: String {
            switch self {
            case .formal: return L("Capitals and full punctuation", "Mayúsculas y puntuación completa")
            case .casual: return L("Capitals, no final period", "Mayúsculas, sin punto final")
            case .veryCasual: return L("No capitals, no final period", "Sin mayúsculas ni punto final")
            case .excited: return L("Ends with an exclamation", "Termina con exclamación")
            }
        }
    }

    enum AppKind: String, Codable, CaseIterable, Identifiable {
        case personal, work, email, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .personal: return L("Personal messages", "Mensajes personales")
            case .work: return L("Work messages", "Mensajes de trabajo")
            case .email: return L("Email", "Mail")
            case .other: return L("Everything else", "Todas las demás apps")
            }
        }

        var examples: String {
            switch self {
            case .personal: return "WhatsApp, " + L("Messages", "Mensajes") + ", Telegram, Signal"
            case .work: return "Slack, Teams, Discord"
            case .email: return "Mail, Outlook, Gmail, Spark"
            case .other: return L("Notes, documents, AI chats, code…", "Notas, documentos, chats de IA, código…")
            }
        }
    }

    struct Transform: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var instructions: String
        /// The shortcut is ⌃⌥ plus this digit (1–9). 0 = no shortcut.
        var key: Int
        /// "polish", "prompt" or "english" for the ones Murmur comes with (they can be reset).
        var builtin: String?

        var shortcut: String { key > 0 ? "⌃⌥\(key)" : "" }
    }

    @Published var words: [Word] = [] { didSet { changed() } }
    @Published var learnWords = true { didSet { changed() } }
    @Published var tones: [AppKind: Tone] = [:] { didSet { changed() } }
    @Published var transformsEnabled = true { didSet { changed() } }
    @Published var transforms: [Transform] = [] { didSet { changed() } }

    /// Called after any change (to refresh the vocabulary and the Transform shortcuts).
    var onChange: (() -> Void)?

    private let url: URL
    private var loading = true

    init(url: URL = Paths.configDir.appendingPathComponent("personalization.json")) {
        self.url = url
        let file = PrivateFile.load(File.self, from: url) ?? File()
        words = file.words
        learnWords = file.learnWords
        tones = Dictionary(uniqueKeysWithValues: file.tones.compactMap { key, value in
            AppKind(rawValue: key).flatMap { kind in Tone(rawValue: value).map { (kind, $0) } }
        })
        transformsEnabled = file.transformsEnabled
        transforms = file.transforms ?? Self.defaultTransforms
        loading = false
    }

    func tone(for kind: AppKind) -> Tone { tones[kind] ?? .formal }

    // MARK: Dictionary

    /// Adds a word unless it's already there. Returns false for duplicates.
    @discardableResult
    func addWord(_ text: String, replaces: String? = nil, learned: Bool = false) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaces = replaces?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let key = (replaces?.isEmpty == false ? replaces! : text).lowercased()
        guard !words.contains(where: { ($0.replaces ?? $0.text).lowercased() == key }) else { return false }
        words.insert(Word(text: text, replaces: replaces?.isEmpty == false ? replaces : nil, learned: learned), at: 0)
        return true
    }

    func removeWord(_ id: Word.ID) { words.removeAll { $0.id == id } }

    func knows(_ text: String) -> Bool {
        let key = text.lowercased()
        return words.contains { $0.text.lowercased() == key }
    }

    /// Your config.json vocabulary plus the dictionary, newest first, kept short enough for Whisper's prompt.
    func vocabulary(base: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var length = 0
        let mine = words.filter { !$0.learned } + words.filter(\.learned)
        // Replacements help Whisper only when they're names, not addresses or long snippets.
        let useful = mine.filter { $0.replaces == nil || ($0.text.wordCount <= 4 && !$0.text.contains("@") && !$0.text.contains("://")) }
        let candidates = base + useful.map(\.text)
        for word in candidates {
            let key = word.lowercased()
            guard !seen.contains(key), length + word.count <= 700 else { continue }
            seen.insert(key)
            length += word.count + 2
            out.append(word)
        }
        return out
    }

    /// Swaps every "replaces" phrase for its written form (whole words, any capitalization).
    func applyReplacements(_ text: String) -> String {
        var out = text
        for word in words {
            guard let from = word.replaces, !from.isEmpty else { continue }
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: from) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: NSRegularExpression.escapedTemplate(for: word.text))
        }
        return out
    }

    // MARK: Transforms

    static var defaultTransforms: [Transform] {
        [
            Transform(name: L("Polish", "Pulir"), instructions: builtinInstructions("polish"), key: 1, builtin: "polish"),
            Transform(name: L("AI prompt", "Prompt para IA"), instructions: builtinInstructions("prompt"), key: 2, builtin: "prompt"),
            Transform(name: L("Translate to English", "Traducir al inglés"), instructions: builtinInstructions("english"), key: 3, builtin: "english"),
        ]
    }

    static func builtinInstructions(_ id: String) -> String {
        switch id {
        case "polish":
            return L("Improve the text without changing what it says or its tone: make it clearer and more concise, reorder ideas so it reads better, fix mistakes and, where it helps, add structure (paragraphs or a list). Keep the language and the way the person talks.",
                     "Mejorá el texto sin cambiar lo que dice ni el tono: hacelo más claro y conciso, ordená las ideas para que se lea mejor, corregí errores y, si ayuda, dale estructura (párrafos o una lista). Mantené el idioma y la forma de hablar (por ejemplo, el voseo).")
        case "prompt":
            return L("Turn these loose thoughts into a clear, well-structured prompt for an AI assistant: the goal, the context it needs, concrete steps or requirements, and the expected output format. Don't invent requirements that aren't in the text. Write it in the same language.",
                     "Convertí estas ideas sueltas en un prompt claro y bien estructurado para un asistente de IA: el objetivo, el contexto que necesita, los pasos o requisitos concretos y el formato de respuesta esperado. No inventes requisitos que no estén en el texto. Escribilo en el mismo idioma.")
        case "english":
            return L("Translate the text into natural English with the same tone. Keep names, code and formatting.",
                     "Traducí el texto al inglés, natural y con el mismo tono. Mantené nombres, código y formato.")
        default:
            return ""
        }
    }

    func transform(forKey key: Int) -> Transform? {
        transforms.first { $0.key == key && !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The lowest free digit for a new Transform's shortcut, or 0 if all nine are taken.
    var freeKey: Int { (1...9).first { k in !transforms.contains { $0.key == k } } ?? 0 }

    // MARK: Saving

    private struct File: Codable {
        var words: [Word] = []
        var learnWords = true
        var tones: [String: String] = [:]
        var transformsEnabled = true
        var transforms: [Transform]?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            words = try c.decodeIfPresent([Word].self, forKey: .words) ?? []
            learnWords = try c.decodeIfPresent(Bool.self, forKey: .learnWords) ?? true
            tones = try c.decodeIfPresent([String: String].self, forKey: .tones) ?? [:]
            transformsEnabled = try c.decodeIfPresent(Bool.self, forKey: .transformsEnabled) ?? true
            transforms = try c.decodeIfPresent([Transform].self, forKey: .transforms)
        }
    }

    private func changed() {
        guard !loading else { return }
        var file = File()
        file.words = words
        file.learnWords = learnWords
        file.tones = Dictionary(uniqueKeysWithValues: tones.map { ($0.key.rawValue, $0.value.rawValue) })
        file.transformsEnabled = transformsEnabled
        file.transforms = transforms
        PrivateFile.save(file, to: url)
        onChange?()
    }
}

// MARK: - Style

/// Writing style applied after cleanup, by rules (no extra AI call, no extra wait).
enum Style {
    static func apply(_ tone: PersonalizationStore.Tone, to text: String, keep names: [String] = []) -> String {
        switch tone {
        case .formal:
            return text
        case .casual:
            return dropFinalPeriod(text)
        case .veryCasual:
            return lowercaseSentenceStarts(dropFinalPeriod(text), keep: names)
        case .excited:
            return exclaim(text)
        }
    }

    private static func endsWithPeriod(_ text: String) -> Bool {
        text.hasSuffix(".") && !text.hasSuffix("..")
    }

    static func dropFinalPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endsWithPeriod(trimmed) else { return text }
        // Not after an abbreviation-like single letter or a URL/email ("etc." is fine either way).
        return String(trimmed.dropLast())
    }

    /// "Nos vemos. Llevá las fotos" → "nos vemos. llevá las fotos". Names, acronyms and "I" stay as they are.
    static func lowercaseSentenceStarts(_ text: String, keep names: [String]) -> String {
        let protected = Set(names.flatMap { $0.split(separator: " ").map { String($0) } })
        var out = ""
        out.reserveCapacity(text.count)
        var atStart = true
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter {
                var end = i
                while end < text.endIndex, text[end].isLetter || text[end] == "'" || text[end] == "’" { end = text.index(after: end) }
                let word = String(text[i..<end])
                if atStart, shouldLowercase(word), !protected.contains(word) {
                    out += word.prefix(1).lowercased() + word.dropFirst()
                } else {
                    out += word
                }
                atStart = false
                i = end
                continue
            }
            if ".!?\n".contains(c) {
                atStart = true
            } else if c.isNumber {
                atStart = false
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }

    private static func shouldLowercase(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return false }
        // "ChatGPT", "API", "McDonald": not a plain capitalized word.
        return !word.dropFirst().contains { $0.isUppercase }
    }

    /// Final period → "!" (with the opening "¡" in Spanish).
    static func exclaim(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endsWithPeriod(trimmed) else { return text }
        var body = String(trimmed.dropLast())
        if NLLanguageRecognizer.dominantLanguage(for: body) == .spanish {
            // Start of the last sentence.
            var start = body.startIndex
            if let boundary = body.lastIndex(where: { ".!?\n:".contains($0) }) {
                start = body.index(after: boundary)
            }
            while start < body.endIndex, body[start].isWhitespace { start = body.index(after: start) }
            let sentence = body[start...]
            if !sentence.contains("¡"), !sentence.contains("¿"), start < body.endIndex {
                body.insert("¡", at: start)
            }
        }
        return body + "!"
    }
}

// MARK: - Which kind of app is in front

enum AppContext {
    struct Front {
        let name: String?
        let kind: PersonalizationStore.AppKind
    }

    private static let personal: Set<String> = [
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.MobileSMS", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "com.tdesktop.Telegram", "org.whispersystems.signal-desktop", "com.facebook.archon", "com.facebook.archon.developerID",
    ]
    private static let work: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.microsoft.teams2", "com.hnc.Discord", "com.discord.Discord",
        "us.zoom.xos", "com.google.Chat",
    ]
    private static let email: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.readdle.SparkDesktop",
        "com.superhuman.electron", "com.mimestream.Mimestream", "it.bloop.airmail2", "com.airmailapp.airmail",
        "com.canarymail.mac", "com.edisonmail.edisonmail",
    ]
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "company.thebrowser.dia", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
    ]

    /// The frontmost app and what kind it is. In a browser, the window title decides (Gmail, WhatsApp Web…).
    static func front() -> Front {
        guard let app = NSWorkspace.shared.frontmostApplication else { return Front(name: nil, kind: .other) }
        let id = app.bundleIdentifier ?? ""
        let name = app.localizedName
        if personal.contains(id) { return Front(name: name, kind: .personal) }
        if work.contains(id) { return Front(name: name, kind: .work) }
        if email.contains(id) { return Front(name: name, kind: .email) }
        if browsers.contains(id), let title = windowTitle(pid: app.processIdentifier)?.lowercased() {
            if ["gmail", "outlook", "yahoo mail", "proton mail", "icloud mail", "bandeja de entrada", "inbox"].contains(where: title.contains) {
                return Front(name: name, kind: .email)
            }
            if ["whatsapp", "messenger", "telegram", "instagram"].contains(where: title.contains) {
                return Front(name: name, kind: .personal)
            }
            if ["slack", "microsoft teams", "discord", "google chat"].contains(where: title.contains) {
                return Front(name: name, kind: .work)
            }
        }
        return Front(name: name, kind: .other)
    }

    private static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}

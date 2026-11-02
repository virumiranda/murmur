import Foundation

/// User settings, stored as JSON at ~/.config/murmur/config.json.
/// Missing keys fall back to the defaults below, so a config file may be partial.
struct Config: Codable, Equatable {
    /// "fn", "rightoption", "rightcommand", "ctrl+option+space", "f13", ...
    var hotkey = "fn"
    /// A press shorter than this counts as a tap (for double-tap detection).
    var tapMaxMs = 300
    /// Max gap between the two taps of a double-tap.
    var doubleTapWindowMs = 350
    /// Any recording (hold or hands-free) is stopped and transcribed after this.
    var maxRecordingSeconds = 300
    /// Words or names to spell exactly; fed to Whisper as a prompt and to the cleanup LLM.
    var vocabulary: [String] = []
    var playSounds = false
    var showPill = true
    /// Keep the text of your dictations (never the audio) in history.json, to find and copy them in Murmur's window.
    var saveHistory = true
    /// While a VPN is on, send Murmur's own API requests over Wi-Fi/Ethernet directly, because Groq blocks VPN
    /// addresses. The rest of the Mac stays in the VPN; the API provider sees your real IP for these requests.
    var bypassVPN = false

    var transcription = Transcription()
    var cleanup = Cleanup()
    var insertion = Insertion()

    struct Transcription: Codable, Equatable {
        /// "auto" (Groq if GROQ_API_KEY is set, else OpenAI if OPENAI_API_KEY is set, else local),
        /// "local" (whisper.cpp, offline), "groq" or "openai".
        var provider = "auto"
        /// "auto" or an ISO code like "en" / "es". A fixed language is faster and more accurate.
        var language = "auto"
        /// Model name ("large-v3-turbo-q5_0", "small", "medium", ...) resolved to models/ggml-<name>.bin, or a path to a .bin file.
        var localModel = "large-v3-turbo-q5_0"
        /// Free the local model's memory after this many idle minutes (0 = keep it loaded).
        var unloadModelAfterMinutes = 15
        var groqModel = "whisper-large-v3-turbo"
        var openaiModel = "whisper-1"
        /// Override the API base URL (a proxy, or a self-hosted OpenAI-compatible Whisper server). Empty = provider default.
        var apiBaseURL = ""
        /// If the API call fails (offline, no key), retry with the local model.
        var fallbackToLocal = true
    }

    struct Cleanup: Codable, Equatable {
        var enabled = true
        /// "auto" (first key found: groq, openai, anthropic), "groq", "openai", "anthropic",
        /// "ollama" (local, http://localhost:11434/v1) or "custom" (any OpenAI-compatible baseURL).
        var provider = "auto"
        /// Empty = provider default.
        var model = ""
        /// Override the API base URL (required for "custom"). Empty = provider default.
        var baseURL = ""
        /// "sentence" (normal typed prose) or "lowercase" (casual chat style).
        var casing = "sentence"
        var timeoutSeconds = 8.0
        /// Skip the LLM when the transcript has nothing it would change (no filler, lists, corrections,
        /// layout commands, spoken addresses or spelled-out numbers). Saves a round trip on clean sentences.
        var skipWhenClean = true
    }

    struct Insertion: Codable, Equatable {
        /// "paste" (pasteboard + Cmd-V) or "type" (synthesized keystrokes).
        var method = "paste"
        /// false: leave the transcript on the clipboard. true: put your previous clipboard back after pasting.
        var restoreClipboard = false
        /// Add a space after the text so consecutive dictations don't run together.
        var trailingSpace = true
    }
}

enum Paths {
    /// ~/.config/murmur, or $MURMUR_CONFIG_DIR (handy for testing a config without touching yours).
    static let configDir: URL = {
        if let dir = ProcessInfo.processInfo.environment["MURMUR_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/murmur", isDirectory: true)
    }()
    static let configFile = configDir.appendingPathComponent("config.json")
    static let envFile = configDir.appendingPathComponent(".env")
    static let modelsDir = configDir.appendingPathComponent("models", isDirectory: true)
    static let historyFile = configDir.appendingPathComponent("history.json")

    static func modelURL(for nameOrPath: String) -> URL {
        let value = nameOrPath.trimmingCharacters(in: .whitespaces)
        if value.contains("/") || value.hasSuffix(".bin") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return modelsDir.appendingPathComponent("ggml-\(value).bin")
    }
}

enum ConfigStore {
    struct LoadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Reads config.json, layering it over the defaults. Writes a full default file if none exists.
    static func load() throws -> Config {
        try ensureFiles()
        let data = try Data(contentsOf: Paths.configFile)
        guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError(message: "config.json must contain a JSON object")
        }
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
        let merged = deepMerge(defaults, user)
        do {
            return try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx) {
            let key = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            throw LoadError(message: "config.json: wrong type for \"\(key)\"")
        }
    }

    static func ensureFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Paths.configFile.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(Config()).write(to: Paths.configFile)
        }
        if !fm.fileExists(atPath: Paths.envFile.path) {
            let template = """
            # API keys for Murmur. Only the services you use need a key.
            # Leave them all empty to run fully offline with the local whisper.cpp model.
            GROQ_API_KEY=
            OPENAI_API_KEY=
            ANTHROPIC_API_KEY=

            """
            fm.createFile(atPath: Paths.envFile.path, contents: Data(template.utf8),
                          attributes: [.posixPermissions: 0o600])
        }
    }

    private static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in over {
            if let b = base[key] as? [String: Any], let o = value as? [String: Any] {
                out[key] = deepMerge(b, o)
            } else {
                out[key] = value
            }
        }
        return out
    }
}

/// API keys from ~/.config/murmur/.env, with the process environment taking precedence.
enum Secrets {
    static func value(_ name: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        guard let text = try? String(contentsOf: Paths.envFile, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == name else { continue }
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" {
                v = String(v.dropFirst().dropLast())
            }
            return v.isEmpty ? nil : v
        }
        return nil
    }
}

import Foundation

/// Polishes a raw transcript with an LLM: drops filler words, fixes punctuation and casing.
/// Any failure (offline, no key, timeout, odd output) returns the raw transcript unchanged.
enum Cleanup {
    struct Provider {
        enum API { case openAICompatible, anthropic }
        let name: String
        let api: API
        let baseURL: String
        let model: String
        let key: String?
    }

    static func resolveProvider(_ c: Config.Cleanup) -> Provider? {
        guard c.enabled else { return nil }
        func make(_ name: String) -> Provider? {
            let model = c.model.isEmpty ? nil : c.model
            func base(_ fallback: String) -> String { c.baseURL.isEmpty ? fallback : c.baseURL }
            switch name {
            case "groq":
                guard let key = Secrets.value("GROQ_API_KEY") else { return nil }
                return Provider(name: name, api: .openAICompatible, baseURL: base("https://api.groq.com/openai/v1"),
                                model: model ?? "openai/gpt-oss-120b", key: key)
            case "openai":
                guard let key = Secrets.value("OPENAI_API_KEY") else { return nil }
                return Provider(name: name, api: .openAICompatible, baseURL: base("https://api.openai.com/v1"),
                                model: model ?? "gpt-4.1-mini", key: key)
            case "anthropic":
                guard let key = Secrets.value("ANTHROPIC_API_KEY") else { return nil }
                return Provider(name: name, api: .anthropic, baseURL: base("https://api.anthropic.com/v1"),
                                model: model ?? "claude-haiku-5-5", key: key)
            case "ollama":
                return Provider(name: name, api: .openAICompatible,
                                baseURL: base("http://localhost:11434/v1"),
                                model: model ?? "llama3.2", key: Secrets.value("OLLAMA_API_KEY"))
            case "custom":
                guard !c.baseURL.isEmpty, let model else { return nil }
                return Provider(name: name, api: .openAICompatible, baseURL: c.baseURL, model: model,
                                key: Secrets.value("CLEANUP_API_KEY"))
            default:
                return nil
            }
        }
        if c.provider == "auto" {
            return ["groq", "openai", "anthropic"].lazy.compactMap(make).first
        }
        return make(c.provider)
    }

    static func systemPrompt(_ config: Config) -> String {
        let casing = config.cleanup.casing == "lowercase"
            ? "Write everything in lowercase, casual chat style, except acronyms and code identifiers."
            : "Use normal sentence casing, as in typed prose."
        let vocabulary = config.vocabulary.isEmpty ? ""
            : "\n# Vocabulary\nSpell these names and terms exactly like this: \(config.vocabulary.joined(separator: ", ")).\n"
        let override = Paths.configDir.appendingPathComponent("cleanup-prompt.md")
        let template = (try? String(contentsOf: override, encoding: .utf8)) ?? CleanupPrompt.template
        return template
            .replacingOccurrences(of: "{{CASING}}", with: casing)
            .replacingOccurrences(of: "{{VOCABULARY}}", with: vocabulary)
    }

    /// Opens the connection to the cleanup API while the user is still talking.
    static func warmUp(config: Config) {
        if let provider = resolveProvider(config.cleanup) { HTTP.prewarm(provider.baseURL) }
    }

    /// Returns the cleaned text, or the input when cleanup is off, unavailable or fails.
    /// `context` is the cleaned text of the previous piece of a long dictation.
    static func polish(_ raw: String, config: Config, context: String = "") async -> String {
        guard let provider = resolveProvider(config.cleanup), !APIHealth.isDown(.cleanup) else { return raw }
        // A few words leave nothing to correct; Whisper's punctuation is enough and it saves a round trip.
        guard raw.split(whereSeparator: \.isWhitespace).count > 3 else { return raw }
        // Over the provider's per-minute limit: paste Whisper's text now rather than wait.
        guard !RateLimits.isLimited(provider.model) else { return raw }
        if config.cleanup.skipWhenClean, context.isEmpty, !needsCleanup(raw) { return raw }
        do {
            let started = Date()
            let cleaned = try await request(raw, provider: provider, config: config, context: context)
            Log.info(String(format: "Cleanup via %@ (%@) took %.0f ms", provider.name, provider.model,
                            Date().timeIntervalSince(started) * 1000))
            APIHealth.markOK(.cleanup)
            return accept(cleaned, raw: raw) ? cleaned : raw
        } catch let limit as RateLimited {
            RateLimits.mark(provider.model, seconds: limit.retryAfter)
            Log.info("Cleanup model \(provider.model) is rate limited for \(Int(limit.retryAfter))s")
            return raw
        } catch {
            if !Task.isCancelled {
                APIHealth.markFailed(.cleanup)
                Log.info("Cleanup via \(provider.name) failed: \(error.localizedDescription)")
            }
            return raw
        }
    }

    struct RateLimited: Error {
        let retryAfter: TimeInterval
    }

    /// When each model may be used again after a 429.
    private enum RateLimits {
        private static let lock = NSLock()
        private static var until: [String: Date] = [:]

        static func isLimited(_ model: String) -> Bool { lock.withLock { (until[model] ?? .distantPast) > Date() } }
        static func mark(_ model: String, seconds: TimeInterval) {
            lock.withLock { until[model] = Date().addingTimeInterval(seconds) }
        }
    }

    /// Seconds until a rate limit resets, from `retry-after` or Groq's "1m26.4s"-style reset header.
    static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval {
        if let value = http.value(forHTTPHeaderField: "retry-after"), let seconds = Double(value) { return max(1, seconds) }
        guard let value = http.value(forHTTPHeaderField: "x-ratelimit-reset-tokens") else { return 30 }
        let regex = try! NSRegularExpression(pattern: #"([0-9.]+)(ms|h|m|s)"#)
        var total = 0.0
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let n = Range(match.range(at: 1), in: value).flatMap({ Double(value[$0]) }),
                  let unit = Range(match.range(at: 2), in: value).map({ value[$0] }) else { continue }
            total += n * (unit == "h" ? 3600 : unit == "m" ? 60 : unit == "ms" ? 0.001 : 1)
        }
        return max(1, total)
    }

    /// Whether the LLM would change anything. Whisper already punctuates and capitalizes, so a short,
    /// plain sentence goes straight through. Long dictations always get cleaned (paragraphs, stray fillers).
    static func needsCleanup(_ raw: String) -> Bool {
        let text = " " + raw.lowercased() + " "
        if raw.split(whereSeparator: \.isWhitespace).count > 40 { return true }
        let triggers = [
            // filler
            " eh", " em ", " emm", " o sea", " tipo,", " tipo ", " viste", " digamos", "bueno,", " este,", " um", " uh",
            " like,", "you know", "i mean", " so,", " ah,",
            // self-corrections
            " no,", "perdón", "mejor dicho", "quise decir", "retiro lo dicho", "borrá eso", "borra eso", "olvidate",
            "olvídate", "scratch that", "delete that", "actually", " corrijo", "o mejor",
            // lists and layout
            "primero", "segundo", "tercero", " uno,", " dos,", "first", "second", "third", "number one",
            "nueva línea", "salto de línea", "nuevo párrafo", "punto y aparte", "new line", "new paragraph", " enter",
            // dictated punctuation, addresses, spelled-out numbers
            " coma ", " punto ", "dos puntos", "signo de", "paréntesis", "comillas", " comma", " period", "question mark",
            "arroba", "punto com", "dot com", " mil ", "millón", "millones", "por ciento", "percent", " y media",
            " y cuarto", "hundred", "thousand",
        ]
        if triggers.contains(where: text.contains) { return true }
        // Enumerations with digits ("1 … 2 …"), stutters ("el el"), and a greeting plus a sign-off (an email).
        let patterns = [#"\b1\b.*\b2\b"#, #"\b(\w+) \1\b"#,
                        #"^\s*(hola|hi|hello|buen día|buenas|querid)[\s\S]*(saludos|abrazo|gracias|besos|thanks|regards|cheers)"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Cleanup only removes words and adds punctuation, so a much longer reply means the model went off-script
    /// (answered the dictation, added commentary). Keep the raw transcript in that case.
    private static func accept(_ cleaned: String, raw: String) -> Bool {
        !cleaned.isEmpty && Double(cleaned.count) <= Double(raw.count) * 1.3 + 20
    }

    private static func request(_ raw: String, provider: Provider, config: Config, context: String) async throws -> String {
        var user = "<dictation>\n\(raw)\n</dictation>"
        if !context.isEmpty { user = "<previous>\n\(context.suffix(600))\n</previous>\n" + user }
        let text = try await LLM.complete(system: systemPrompt(config), user: user, provider: provider,
                                          timeout: config.cleanup.timeoutSeconds)
        return text
            .replacingOccurrences(of: "<dictation>", with: "")
            .replacingOccurrences(of: "</dictation>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

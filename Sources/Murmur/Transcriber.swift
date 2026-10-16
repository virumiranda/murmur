import Foundation
import whisper

struct MurmurError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Set from any thread; read by whisper.cpp's abort callback between compute steps.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// whisper.cpp running in-process. The model loads when a recording starts (overlapping with speech)
/// and is freed after an idle period.
final class LocalWhisper: @unchecked Sendable {
    static let shared = LocalWhisper()

    private let queue = DispatchQueue(label: "murmur.whisper", qos: .userInitiated)
    private var ctx: OpaquePointer?
    private var loadedPath: String?
    private var unloadWork: DispatchWorkItem?

    private init() {
        // Silence whisper.cpp / ggml logging.
        whisper_log_set({ _, _, _ in }, nil)
    }

    /// Loads the model in the background if it isn't loaded already.
    func preload(_ url: URL, unloadAfterMinutes: Int) {
        queue.async {
            guard (try? self.context(for: url)) != nil else { return }
            self.scheduleUnload(minutes: unloadAfterMinutes)
        }
    }

    func transcribe(_ samples: [Float], model url: URL, language: String, prompt: String,
                    unloadAfterMinutes: Int) async throws -> String {
        let abort = AbortFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    do {
                        let text = try self.run(samples, url: url, language: language, prompt: prompt, abort: abort)
                        self.scheduleUnload(minutes: unloadAfterMinutes)
                        cont.resume(returning: text)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            abort.set()
        }
    }

    /// Frees the model. Must run before the process exits: ggml's Metal backend asserts if it's still loaded.
    func shutdown() {
        queue.sync {
            unloadWork?.cancel()
            if let ctx { whisper_free(ctx) }
            ctx = nil
            loadedPath = nil
        }
    }

    // Everything below runs on `queue`.

    private func context(for url: URL) throws -> OpaquePointer {
        unloadWork?.cancel()
        if let ctx, loadedPath == url.path { return ctx }
        if let ctx { whisper_free(ctx) }
        ctx = nil
        loadedPath = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MurmurError(L("Model \(url.lastPathComponent) not found. Run: make model", "Falta el modelo \(url.lastPathComponent). Ejecutá: make model"))
        }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        let started = Date()
        guard let newCtx = whisper_init_from_file_with_params(url.path, params) else {
            throw MurmurError("Could not load Whisper model \(url.lastPathComponent)")
        }
        Log.info(String(format: "Loaded %@ in %.2fs", url.lastPathComponent, Date().timeIntervalSince(started)))
        ctx = newCtx
        loadedPath = url.path
        return newCtx
    }

    private func run(_ samples: [Float], url: URL, language: String, prompt: String, abort: AbortFlag) throws -> String {
        if abort.isSet { throw CancellationError() }
        let ctx = try context(for: url)

        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        p.translate = false
        p.no_context = true
        p.no_timestamps = true
        p.print_progress = false
        p.print_realtime = false
        p.print_special = false
        p.print_timestamps = false
        p.suppress_blank = true
        p.suppress_nst = true
        p.abort_callback = { data in
            Unmanaged<AbortFlag>.fromOpaque(data!).takeUnretainedValue().isSet
        }
        p.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()

        let lang = strdup(language.isEmpty ? "auto" : language)
        let initialPrompt = prompt.isEmpty ? nil : strdup(prompt)
        defer {
            free(lang)
            free(initialPrompt)
        }
        p.language = UnsafePointer(lang)
        p.initial_prompt = UnsafePointer(initialPrompt)

        let started = Date()
        whisper_reset_timings(ctx)
        let status = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, p, buf.baseAddress, Int32(buf.count))
        }
        if let t = whisper_get_timings(ctx)?.pointee {
            Log.info(String(format: "whisper_full took %.2fs (encode %.0f ms, decode %.0f ms)",
                            Date().timeIntervalSince(started), t.encode_ms, t.decode_ms + t.batchd_ms + t.prompt_ms))
        }
        if abort.isSet { throw CancellationError() }
        guard status == 0 else { throw MurmurError("whisper.cpp failed (code \(status))") }

        var segments: [String] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            guard let cstr = whisper_full_get_segment_text(ctx, i) else { continue }
            segments.append(String(cString: cstr))
        }
        return TranscriptFilter.clean(segments)
    }

    private func scheduleUnload(minutes: Int) {
        unloadWork?.cancel()
        guard minutes > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let ctx = self.ctx else { return }
            whisper_free(ctx)
            self.ctx = nil
            self.loadedPath = nil
        }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + .seconds(min(minutes, 7 * 24 * 60) * 60), execute: work)
    }
}

enum TranscriptFilter {
    /// Drops the non-speech markers Whisper emits on silence or noise ("[BLANK_AUDIO]", "(music)", "[Applause]").
    static func clean(_ segments: [String]) -> String {
        let marker = try! NSRegularExpression(pattern: #"^\s*[\[\(][^\]\)]{1,40}[\]\)]\s*$"#)
        return segments
            .filter { s in marker.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Groq / OpenAI hosted Whisper (both speak the OpenAI transcription API).
enum RemoteWhisper {
    static func baseURL(provider: String, override: String) -> String {
        if !override.isEmpty { return override }
        return provider == "groq" ? "https://api.groq.com/openai/v1" : "https://api.openai.com/v1"
    }

    static func transcribe(_ samples: [Float], provider: String, model: String, language: String,
                           prompt: String, baseURL: String) async throws -> String {
        let base = Self.baseURL(provider: provider, override: baseURL)
        let keyName = provider == "groq" ? "GROQ_API_KEY" : "OPENAI_API_KEY"
        guard let key = Secrets.value(keyName) else { throw MurmurError("\(keyName) is not set in .env") }

        let boundary = "murmur-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        field("temperature", "0")
        if language != "auto", !language.isEmpty { field("language", language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        let audio = AudioUtil.aacData(samples).map { ($0, "audio.m4a", "audio/mp4") }
            ?? (AudioUtil.wavData(samples), "audio.wav", "audio/wav")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.1)\"\r\nContent-Type: \(audio.2)\r\n\r\n".utf8))
        body.append(audio.0)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        guard let baseURL = URL(string: base), baseURL.scheme != nil else { throw MurmurError("Invalid apiBaseURL \"\(base)\"") }
        var req = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await HTTP.send(req, body: body)
        try HTTP.check(response, data, service: provider)
        struct Reply: Decodable { let text: String }
        let text = try JSONDecoder().decode(Reply.self, from: data).text
        return TranscriptFilter.clean([text])
    }
}

enum HTTP {
    /// Ephemeral: no cookies, no URL cache on disk.
    static let session = URLSession(configuration: .ephemeral)
    /// Mirrors `Config.bypassVPN`; set whenever the config loads.
    static var bypassVPN = false

    /// Sends a request with `body`, skipping the VPN if the bypass is on and a VPN is active.
    static func send(_ request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        if let interface = DirectRoute.bypassInterface(enabled: bypassVPN) {
            return try await DirectRoute.send(request, body: body, interface: interface)
        }
        return try await session.upload(for: request, from: body)
    }

    /// Opens the TLS connection to an API host while the user is still talking, so the real request
    /// doesn't pay for the handshake. The response itself is ignored.
    static func prewarm(_ base: String) {
        guard let url = URL(string: base), url.scheme == "https",
              DirectRoute.bypassInterface(enabled: bypassVPN) == nil else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "HEAD"
        session.dataTask(with: req).resume()
    }

    static func check(_ response: URLResponse, _ data: Data, service: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            throw HTTPError(status: http.statusCode, body: snippet, service: service)
        }
    }

    struct HTTPError: LocalizedError {
        let status: Int
        let body: String
        let service: String
        var errorDescription: String? { "\(service) returned HTTP \(status)" }
    }
}

/// Remembers recent API failures (offline, blocked by a VPN, bad key), so the next dictations go straight
/// to the fallback instead of waiting on a request that will fail again. Retries after a couple of minutes.
enum APIHealth {
    enum Service { case transcription, cleanup }

    private static let lock = NSLock()
    private static var failedAt: [Service: Date] = [:]
    private static let cooldown: TimeInterval = 120

    static func isDown(_ service: Service) -> Bool {
        lock.withLock { failedAt[service].map { Date().timeIntervalSince($0) < cooldown } ?? false }
    }

    static func markFailed(_ service: Service) { lock.withLock { failedAt[service] = Date() } }
    static func markOK(_ service: Service) { lock.withLock { failedAt[service] = nil } }
}

/// Picks the transcription backend from config, falling back to the local model when the API is unavailable.
enum Transcriber {
    /// "auto" becomes the first API with a key in .env, or the local model.
    static func resolvedProvider(_ t: Config.Transcription) -> String {
        guard t.provider == "auto" else { return t.provider }
        if Secrets.value("GROQ_API_KEY") != nil { return "groq" }
        if Secrets.value("OPENAI_API_KEY") != nil { return "openai" }
        return "local"
    }

    /// `context` is the text that came right before this audio (the previous piece of a long dictation);
    /// Whisper uses it to keep wording, language and casing consistent across pieces.
    static func transcribe(_ samples: [Float], config: Config, context: String = "") async throws -> String {
        var t = config.transcription
        t.provider = resolvedProvider(t)
        var prompt = config.vocabulary.isEmpty ? "" : config.vocabulary.joined(separator: ", ") + "."
        if !context.isEmpty { prompt += (prompt.isEmpty ? "" : " ") + String(context.suffix(200)) }
        let modelURL = Paths.modelURL(for: t.localModel)
        func local() async throws -> String {
            try await LocalWhisper.shared.transcribe(samples, model: modelURL, language: t.language,
                                                     prompt: prompt, unloadAfterMinutes: t.unloadModelAfterMinutes)
        }
        switch t.provider {
        case "groq", "openai":
            let canFallBack = t.fallbackToLocal && FileManager.default.fileExists(atPath: modelURL.path)
            if canFallBack, APIHealth.isDown(.transcription) { return try await local() }
            do {
                let started = Date()
                let text = try await RemoteWhisper.transcribe(samples, provider: t.provider,
                                                              model: t.provider == "groq" ? t.groqModel : t.openaiModel,
                                                              language: t.language, prompt: prompt, baseURL: t.apiBaseURL)
                Log.info(String(format: "Transcribed %.1fs of audio via %@ in %.0f ms%@", Double(samples.count) / AudioRecorder.sampleRate,
                                t.provider, Date().timeIntervalSince(started) * 1000,
                                DirectRoute.bypassInterface(enabled: HTTP.bypassVPN) != nil ? " (bypassing VPN)" : ""))
                APIHealth.markOK(.transcription)
                return text
            } catch {
                if Task.isCancelled { throw CancellationError() }
                APIHealth.markFailed(.transcription)
                guard canFallBack else { throw error }
                Log.info("Remote transcription failed (\(error.localizedDescription)); using local model")
                return try await local()
            }
        case "local":
            return try await local()
        default:
            throw MurmurError("Unknown transcription.provider \"\(t.provider)\"")
        }
    }

    /// Called when recording starts: load the local model, or open the connection to the API.
    static func warmUp(config: Config) {
        var t = config.transcription
        t.provider = resolvedProvider(t)
        let keyName = t.provider == "groq" ? "GROQ_API_KEY" : "OPENAI_API_KEY"
        let remoteUnusable = Secrets.value(keyName) == nil || APIHealth.isDown(.transcription)
        if t.provider == "local" || (t.fallbackToLocal && remoteUnusable) {
            // No key, or the API just failed (offline, VPN): the local model will do the work.
            LocalWhisper.shared.preload(Paths.modelURL(for: t.localModel), unloadAfterMinutes: t.unloadModelAfterMinutes)
        } else {
            HTTP.prewarm(RemoteWhisper.baseURL(provider: t.provider, override: t.apiBaseURL))
        }
    }
}

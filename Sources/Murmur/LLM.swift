import Foundation

/// One request to the language model set up for cleanup (Groq, OpenAI, Anthropic, Ollama or custom).
/// Used by the cleanup pass, Transforms and meeting summaries.
enum LLM {
    /// The provider from the cleanup settings, even when the cleanup pass itself is switched off.
    static func provider(_ config: Config) -> Cleanup.Provider? {
        var c = config.cleanup
        c.enabled = true
        return Cleanup.resolveProvider(c)
    }

    /// Throws `Cleanup.RateLimited` on a 429, so callers can wait or give up.
    static func complete(system: String, user: String, provider: Cleanup.Provider,
                         timeout: TimeInterval, maxTokens: Int = 4096) async throws -> String {
        guard let baseURL = URL(string: provider.baseURL), baseURL.scheme != nil else {
            throw MurmurError("Invalid cleanup.baseURL \"\(provider.baseURL)\"")
        }
        var req = URLRequest(url: baseURL, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any]
        switch provider.api {
        case .openAICompatible:
            req.url = req.url!.appendingPathComponent("chat/completions")
            if let key = provider.key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = [
                "model": provider.model,
                "temperature": 0,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ]
            // gpt-oss models reason before answering; these tasks need very little of it.
            if provider.model.contains("gpt-oss") { body["reasoning_effort"] = "low" }
        case .anthropic:
            req.url = req.url!.appendingPathComponent("messages")
            req.setValue(provider.key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // Current Claude models reject a non-default temperature, so none is sent.
            // Thinking only adds latency here.
            body = [
                "model": provider.model,
                "max_tokens": maxTokens,
                "thinking": ["type": "disabled"],
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
        }

        var (data, response) = try await send(req, body)
        if (response as? HTTPURLResponse)?.statusCode == 400 {
            let error = String(decoding: data, as: UTF8.self)
            if error.contains("reasoning_effort"), body["reasoning_effort"] != nil {
                body["reasoning_effort"] = nil
                (data, response) = try await send(req, body)
            } else if error.contains("temperature"), body["temperature"] != nil {
                // Some models only accept their default temperature.
                body["temperature"] = nil
                (data, response) = try await send(req, body)
            } else if error.contains("thinking"), body["thinking"] != nil {
                // Some Claude models (e.g. Opus 5.5) can't turn thinking off; keep it short instead.
                body["thinking"] = nil
                body["output_config"] = ["effort": "low"]
                (data, response) = try await send(req, body)
            }
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            throw Cleanup.RateLimited(retryAfter: Cleanup.retryAfter(http))
        }
        try HTTP.check(response, data, service: provider.name)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text: String?
        switch provider.api {
        case .openAICompatible:
            let choices = json?["choices"] as? [[String: Any]]
            text = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        case .anthropic:
            let blocks = json?["content"] as? [[String: Any]]
            text = blocks?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        }
        guard let text else { throw MurmurError("Unexpected reply from \(provider.name)") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Like `complete`, but waits out rate limits (up to `maxWait` seconds in total) instead of failing.
    /// For long, non-interactive jobs such as meeting summaries.
    static func completePatiently(system: String, user: String, provider: Cleanup.Provider,
                                  timeout: TimeInterval, maxWait: TimeInterval = 240) async throws -> String {
        var waited: TimeInterval = 0
        while true {
            do {
                return try await complete(system: system, user: user, provider: provider, timeout: timeout)
            } catch let limit as Cleanup.RateLimited where waited + limit.retryAfter <= maxWait {
                Log.info("LLM rate limited; waiting \(Int(limit.retryAfter))s")
                try await Task.sleep(nanoseconds: UInt64((limit.retryAfter + 0.5) * 1_000_000_000))
                waited += limit.retryAfter
            }
        }
    }

    private static func send(_ req: URLRequest, _ body: [String: Any]) async throws -> (Data, URLResponse) {
        try await HTTP.send(req, body: JSONSerialization.data(withJSONObject: body))
    }
}

import AppKit

let version = "1.1.0"
let usage = """
Murmur \(version): hold-to-talk dictation for macOS.

Usage:
  Murmur                         Run the menu bar app (normally launched as Murmur.app)
  Murmur --check                 Show config, model and API key status
  Murmur --transcribe <file>     Transcribe an audio file with the configured pipeline and print the result
        [--raw]                  Skip the LLM cleanup step
        [--model <name|path>]    Override transcription.localModel
        [--provider <name>]      Override transcription.provider (auto, local, groq, openai)
        [--realtime]             Feed the audio at real speed, as if recorded live (shows the wait after stopping)
  Murmur --clean "<text>"        Run text through the cleanup LLM only (to try prompt changes)
  Murmur --transform <1-9> "<text>"  Rewrite text with the Transform on that shortcut (⌃⌥1 = Polish)
  Murmur --summarize <file.txt>  Write meeting notes from a transcript in a text file
"""

func argValue(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

enum CLI {
    static func check() {
        print("Murmur \(version)")
        print("Config file:   \(Paths.configFile.path)")
        let config: Config
        do {
            config = try ConfigStore.load()
        } catch {
            print("               ERROR: \(error.localizedDescription)")
            return
        }
        let hotkey = (try? HotkeySpec.parse(config.hotkey))?.display ?? "INVALID (\(config.hotkey))"
        print("Hotkey:        \(hotkey)")
        let t = config.transcription
        print("Transcription: \(Transcriber.resolvedProvider(t))\(t.provider == "auto" ? " (auto)" : ""), language \(t.language)")
        let model = Paths.modelURL(for: t.localModel)
        if let size = (try? FileManager.default.attributesOfItem(atPath: model.path))?[.size] as? Int {
            print("Local model:   \(model.path) (\(size / 1_000_000) MB)")
        } else {
            print("Local model:   \(model.path) MISSING. Run scripts/download-model.sh \(t.localModel)")
        }
        let keys = ["GROQ_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
            .map { "\($0) \(Secrets.value($0) == nil ? "–" : "✓")" }
        print("API keys:      \(keys.joined(separator: ", "))   (\(Paths.envFile.path))")
        if let p = Cleanup.resolveProvider(config.cleanup) {
            print("Cleanup:       \(p.name) · \(p.model) · \(p.baseURL)")
        } else {
            print("Cleanup:       off\(config.cleanup.enabled ? " (no provider available)" : "")")
        }
        print("Insertion:     \(config.insertion.method), restoreClipboard \(config.insertion.restoreClipboard)")
    }

    static func transcribe(path: String) {
        Task { @MainActor in
            do {
                var config = try ConfigStore.load()
                DirectRoute.start()
                HTTP.bypassVPN = config.bypassVPN
                try await Task.sleep(nanoseconds: 200_000_000) // let the network monitor report
                if let model = argValue("--model") { config.transcription.localModel = model }
                if let provider = argValue("--provider") { config.transcription.provider = provider }

                let samples = try AudioUtil.loadFile(URL(fileURLWithPath: path))
                let seconds = Double(samples.count) / AudioRecorder.sampleRate
                print(String(format: "audio:   %.1fs, peak RMS %.4f", seconds, AudioUtil.peakRMS(samples)))

                if CommandLine.arguments.contains("--raw") { config.cleanup.enabled = false }
                Transcriber.warmUp(config: config)
                Cleanup.warmUp(config: config)

                // Same path as the app: pieces are cut and transcribed while "recording", the rest after.
                let session = StreamingTranscription(config: config)
                var source = ArraySource(samples: samples, available: 0)
                let tick = Int(AudioRecorder.sampleRate / 4)
                while source.available < samples.count {
                    source.available = min(samples.count, source.available + tick)
                    session.poll(source)
                    if CommandLine.arguments.contains("--realtime") { try await Task.sleep(nanoseconds: 250_000_000) }
                }
                let start = Date()
                let result = try await session.finish(samples)
                let label = Cleanup.resolveProvider(config.cleanup)?.name ?? "no cleanup"
                print(String(format: "wait after stop: %.2fs (%@)", Date().timeIntervalSince(start), label))
                print("raw:     \(result.raw)")
                if config.cleanup.enabled, result.text != result.raw { print("cleaned: \(result.text)") }
                LocalWhisper.shared.shutdown()
                exit(0)
            } catch {
                Log.error(error.localizedDescription)
                LocalWhisper.shared.shutdown()
                exit(1)
            }
        }
        dispatchMain()
    }
}

let args = CommandLine.arguments
if args.contains("--help") || args.contains("-h") {
    print(usage)
} else if args.contains("--version") {
    print(version)
} else if args.contains("--check") {
    Log.echo = true
    CLI.check()
} else if let text = argValue("--clean") {
    Task { @MainActor in
        let config = (try? ConfigStore.load()) ?? Config()
        DirectRoute.start()
        HTTP.bypassVPN = config.bypassVPN
        try? await Task.sleep(nanoseconds: 200_000_000) // let the network monitor report
        let start = Date()
        let out = await Cleanup.polish(text, config: config)
        FileHandle.standardError.write(Data(String(format: "%.2fs\n", Date().timeIntervalSince(start)).utf8))
        print(out)
        exit(0)
    }
    dispatchMain()
} else if let key = argValue("--transform") {
    let args = CommandLine.arguments
    let text = args.firstIndex(of: "--transform").flatMap { $0 + 2 < args.count ? args[$0 + 2] : nil } ?? ""
    Task { @MainActor in
        let config = (try? ConfigStore.load()) ?? Config()
        DirectRoute.start()
        HTTP.bypassVPN = config.bypassVPN
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let transform = PersonalizationStore().transform(forKey: Int(key) ?? 0), let provider = LLM.provider(config) else {
            FileHandle.standardError.write(Data("No transform on that key, or no AI key\n".utf8))
            exit(1)
        }
        do {
            let start = Date()
            let out = try await TransformRunner.rewrite(text, instructions: transform.instructions, provider: provider)
            FileHandle.standardError.write(Data(String(format: "%@ · %.2fs\n", transform.name, Date().timeIntervalSince(start)).utf8))
            print(out)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
} else if let file = argValue("--summarize") {
    Task { @MainActor in
        let config = (try? ConfigStore.load()) ?? Config()
        DirectRoute.start()
        HTTP.bypassVPN = config.bypassVPN
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let text = try? String(contentsOfFile: file, encoding: .utf8), let provider = LLM.provider(config) else {
            FileHandle.standardError.write(Data("Can't read the file, or no AI key\n".utf8))
            exit(1)
        }
        do {
            let start = Date()
            let notes = try await Summarizer.summarize(text, provider: provider)
            FileHandle.standardError.write(Data(String(format: "%.2fs\n", Date().timeIntervalSince(start)).utf8))
            print("Title: \(notes.title ?? "–")\n\n\(notes.body)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
} else if let file = argValue("--transcribe") {
    Log.echo = true
    CLI.transcribe(path: file)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

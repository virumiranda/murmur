import Foundation

protocol SampleSource {
    var sampleCount: Int { get }
    func copySamples(from start: Int, count: Int) -> [Float]
}

/// Transcribes a long recording in pieces while it is still being recorded.
///
/// Whenever ~20 s of untranscribed audio builds up, the piece is cut at the quietest moment of its
/// last few seconds (so no word is split), then transcribed and cleaned up in the background.
/// When recording stops, only the last piece is left to do, so speaking longer doesn't mean waiting longer.
/// Short dictations never reach a cut and go through in one piece.
final class StreamingTranscription {
    static let pieceSeconds = 20.0
    static let searchSeconds = 5.0

    private struct Piece {
        let raw: String
        let text: String
    }

    private let config: Config
    private var dispatched = 0 // samples already handed to a piece
    private var pieces: [Task<Piece, Error>] = []

    init(config: Config) {
        self.config = config
    }

    /// Call regularly while recording (main thread). Cuts and dispatches a piece when enough audio has built up.
    func poll(_ source: SampleSource) {
        let pieceSamples = Int(Self.pieceSeconds * AudioRecorder.sampleRate)
        guard source.sampleCount - dispatched >= pieceSamples else { return }
        let audio = source.copySamples(from: dispatched, count: pieceSamples)
        let cut = Self.quietestCut(audio)
        dispatched += cut
        submit(Array(audio[..<cut]))
    }

    /// Transcribes what's left and returns the whole dictation: (raw transcript, cleaned text).
    func finish(_ all: [Float]) async throws -> (raw: String, text: String) {
        let rest = dispatched < all.count ? Array(all[dispatched...]) : []
        dispatched = all.count
        if pieces.isEmpty || Double(rest.count) / AudioRecorder.sampleRate >= 0.3 {
            submit(rest)
        }
        let tasks = pieces
        return try await withTaskCancellationHandler {
            var raws: [String] = []
            var texts: [String] = []
            for task in tasks {
                let piece = try await task.value
                if !piece.raw.isEmpty {
                    raws.append(piece.raw)
                    texts.append(piece.text)
                }
            }
            return (raws.joined(separator: " "), texts.joined(separator: " "))
        } onCancel: {
            tasks.forEach { $0.cancel() }
        }
    }

    func cancel() {
        pieces.forEach { $0.cancel() }
    }

    private func submit(_ audio: [Float]) {
        let previous = pieces.last
        let config = self.config
        pieces.append(Task {
            // In order, and with the previous piece's text as context.
            let before = try await previous?.value
            try Task.checkCancellation()
            guard AudioUtil.peakRMS(audio) >= 0.004 else { return Piece(raw: "", text: "") } // a silent stretch
            let raw = try await Transcriber.transcribe(audio, config: config, context: before?.raw ?? "")
            try Task.checkCancellation()
            guard !raw.isEmpty else { return Piece(raw: "", text: "") }
            let text = await Cleanup.polish(raw, config: config, context: before?.text ?? "")
            return Piece(raw: raw, text: text)
        })
    }

    /// Index of the quietest 100 ms in the last few seconds of `audio`: the best place to end a piece.
    static func quietestCut(_ audio: [Float]) -> Int {
        let rate = Int(AudioRecorder.sampleRate)
        let window = rate / 10
        let step = rate / 40
        let searchStart = max(0, audio.count - Int(searchSeconds * AudioRecorder.sampleRate))
        var best = audio.count
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = searchStart
        while i + window <= audio.count {
            var energy: Float = 0
            for j in i..<(i + window) { energy += audio[j] * audio[j] }
            if energy < bestEnergy {
                bestEnergy = energy
                best = i + window / 2
            }
            i += step
        }
        return best
    }
}

extension AudioRecorder: SampleSource {}

/// Feeds a fixed array as if it were being recorded (used by --transcribe).
struct ArraySource: SampleSource {
    let samples: [Float]
    var available: Int

    var sampleCount: Int { available }

    func copySamples(from start: Int, count: Int) -> [Float] {
        Array(samples[start..<min(available, start + count)])
    }
}

/// Runs `work`, but gives up after `seconds` even if `work` never returns (a hung network call or helper
/// process). Cancelling the caller cancels `work` and returns right away.
func withWatchdog<T>(seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
    let gate = OnceGate()
    var worker: Task<Void, Never>?
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            worker = Task {
                do {
                    let value = try await work()
                    if gate.claim() { cont.resume(returning: value) }
                } catch {
                    if gate.claim() { cont.resume(throwing: error) }
                }
            }
            gate.onCancel = { [worker] in
                worker?.cancel()
                cont.resume(throwing: CancellationError())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard gate.claim() else { return }
                worker?.cancel()
                cont.resume(throwing: MurmurError(L("Transcription took too long and was stopped", "La transcripción tardó demasiado y se canceló")))
            }
        }
    } onCancel: {
        gate.cancel()
    }
}

/// Makes sure a continuation is resumed exactly once, whichever of work, timeout or cancel comes first.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var cancelled = false
    private var cancelHandler: (() -> Void)?

    var onCancel: (() -> Void)? {
        get { lock.withLock { cancelHandler } }
        set {
            let runNow = lock.withLock { () -> Bool in
                cancelHandler = newValue
                return cancelled && !done
            }
            if runNow, claim() { newValue?() }
        }
    }

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }

    func cancel() {
        let handler = lock.withLock { () -> (() -> Void)? in
            cancelled = true
            return cancelHandler
        }
        if let handler, claim() { handler() }
    }
}

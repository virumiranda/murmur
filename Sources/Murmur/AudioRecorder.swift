import AVFoundation

/// Captures the default input device as 16 kHz mono Float32, the format Whisper wants.
/// A fresh AVAudioEngine per session picks up device changes (AirPods, USB mics) without bookkeeping.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    enum RecorderError: LocalizedError {
        case noInputDevice
        var errorDescription: String? { "No microphone available" }
    }

    /// Called on the main queue ~20 times a second with a 0...1 level.
    var onLevel: ((Float) -> Void)?

    private let queue = DispatchQueue(label: "murmur.audio")
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let lock = NSLock()

    /// Starts asynchronously so the pill appears without waiting on CoreAudio.
    func start(onError: @escaping (Error) -> Void) {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        queue.async {
            do {
                try self.startEngine()
            } catch {
                DispatchQueue.main.async { onError(error) }
            }
        }
    }

    /// Stops capture and returns everything recorded.
    func stop() -> [Float] {
        queue.sync { stopEngine() }
        return lock.withLock {
            let out = samples
            samples = []
            return out
        }
    }

    func cancel() {
        _ = stop()
    }

    /// Takes everything recorded so far and keeps recording (long sessions, so memory doesn't grow).
    func drain() -> [Float] {
        lock.withLock {
            let out = samples
            samples.removeAll(keepingCapacity: true)
            return out
        }
    }

    /// Samples recorded so far in this session (any thread).
    var sampleCount: Int { lock.withLock { samples.count } }

    func copySamples(from start: Int, count: Int) -> [Float] {
        lock.withLock { Array(samples[min(start, samples.count)..<min(samples.count, start + count)]) }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecorderError.noInputDevice }
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                      channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw RecorderError.noInputDevice }
        converter.downmix = true

        var lastLevelUpdate = Date.distantPast
        var peak: Float = 0
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / inFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
            self.lock.withLock { self.samples.append(contentsOf: chunk) }

            var sum: Float = 0
            for s in chunk { sum += s * s }
            peak = max(peak, (sum / Float(chunk.count)).squareRoot())
            let now = Date()
            if now.timeIntervalSince(lastLevelUpdate) >= 0.05 {
                lastLevelUpdate = now
                // Map roughly -55 dBFS...-10 dBFS onto 0...1.
                let db = 20 * log10(max(peak, 1e-6))
                let level = min(1, max(0, (db + 55) / 45))
                peak = 0
                DispatchQueue.main.async { self.onLevel?(level) }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}

enum AudioUtil {
    /// Loudest 30 ms window, as RMS. Used to skip transcribing silence (Whisper hallucinates on it).
    static func peakRMS(_ samples: [Float]) -> Float {
        let window = Int(AudioRecorder.sampleRate * 0.03)
        guard samples.count >= window else { return 0 }
        var best: Float = 0
        var i = 0
        while i + window <= samples.count {
            var sum: Float = 0
            for j in i..<(i + window) { sum += samples[j] * samples[j] }
            best = max(best, (sum / Float(window)).squareRoot())
            i += window
        }
        return best
    }

    /// AAC in an .m4a container, about 7x smaller than WAV, so uploads to the transcription API finish sooner.
    /// AVAudioFile only writes to files, so it goes through a private temp file that's deleted right away.
    /// Returns nil if encoding fails (the caller then sends WAV).
    static func aacData(_ samples: [Float]) -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ]
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            // Scoped so the file is closed (and its header finalized) before it's read back.
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
            }
            return try Data(contentsOf: url)
        } catch {
            return nil
        }
    }

    /// 16-bit PCM WAV, for the HTTP transcription APIs.
    static func wavData(_ samples: [Float]) -> Data {
        let rate = UInt32(AudioRecorder.sampleRate)
        let dataSize = UInt32(samples.count * 2)
        var d = Data(capacity: 44 + Int(dataSize))
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// Decodes any file AVAudioFile can read into 16 kHz mono Float32 (used by --transcribe).
    static func loadFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                      channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw AudioRecorder.RecorderError.noInputDevice }
        converter.downmix = true
        try file.read(into: inBuf)
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * AudioRecorder.sampleRate / inFormat.sampleRate) + 1024
        let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)!
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

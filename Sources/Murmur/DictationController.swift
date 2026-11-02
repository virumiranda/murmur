import AppKit
import AVFoundation

/// Turns hotkey events into recordings, and recordings into text at the cursor.
///
///   hold hotkey ............ record while held, transcribe on release
///   double-tap ............. hands-free: keeps recording, one more tap stops
///   Esc .................... drop the recording, or kill transcriptions in flight
///   maxRecordingSeconds .... any recording stops and transcribes on its own
///
/// All state lives on the main thread. Transcription jobs run one at a time, in order,
/// so a new recording can start while the previous one is still being transcribed.
final class DictationController {
    var config: Config {
        didSet { pill.model.maxSeconds = TimeInterval(config.maxRecordingSeconds) }
    }
    /// Called whenever recording/processing state changes (menu bar icon).
    var onActivityChange: (() -> Void)?
    /// Final touches before pasting: dictionary replacements and the writing style for the app in front.
    var postProcess: ((String) -> String)?
    /// Called with each finished dictation (for the history), right before it's pasted.
    var onTranscript: ((_ text: String, _ raw: String, _ seconds: Double) -> Void)?
    /// Called after text was pasted into another app (to learn from corrections).
    var onPasted: ((String) -> Void)?
    /// A recording is starting.
    var onRecordingStart: (() -> Void)?
    /// Something else (a Transform) is working: show the working pill.
    var externalWork = false {
        didSet { refreshPill() }
    }
    private(set) var lastTranscript: String?

    private enum State {
        case idle
        case holding(since: Date)
        /// A short tap ended; recording continues while we wait to see if a second tap follows.
        case awaitingSecondTap
        case handsFree
    }

    private var state: State = .idle
    private var mode: RecordingMode = .hold
    /// The press that switched to hands-free is still down; its release means nothing.
    private var ignoreNextUp = false
    /// A tap during hands-free: stop on its release, unless it turns out to be fn+key.
    private var stopOnUp = false
    private var recordingStart = Date()
    private var doubleTapWork: DispatchWorkItem?
    private var autoStopWork: DispatchWorkItem?
    private var ticker: Timer?

    private let recorder = AudioRecorder()
    /// Transcribes the current recording piece by piece while it's still going.
    private var streaming: StreamingTranscription?
    private let pill = PillWindow()
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?

    var isRecording: Bool {
        if case .idle = state { return false }
        return true
    }

    var isProcessing: Bool { !jobs.isEmpty }

    init(config: Config) {
        self.config = config
        pill.model.maxSeconds = TimeInterval(config.maxRecordingSeconds)
        recorder.onLevel = { [weak self] level in self?.pill.model.push(level: level) }
        pill.onCancel = { [weak self] in self?.escape() }
        pill.onStop = { [weak self] in
            guard let self, case .handsFree = self.state else { return }
            self.finishRecording()
        }
    }

    // MARK: Hotkey state machine

    func handle(_ event: HotkeyEvent) {
        switch (event, state) {
        case (.escape, _):
            escape()

        case (.chord, .holding):
            // fn+arrow, fn+delete, ... — a shortcut, not dictation.
            cancelRecording()

        case (.chord, .handsFree):
            if ignoreNextUp {
                cancelRecording() // the "second tap" was really fn+key
            } else {
                stopOnUp = false // fn+key mid-session (e.g. fn+← to move the cursor): keep recording
            }

        case (.down, .idle):
            beginHold()

        case (.down, .holding):
            // The release went missing (e.g. the hotkey monitor restarted mid-press). Don't paste stale audio.
            cancelRecording()
            beginHold()

        case (.down, .awaitingSecondTap):
            // Second tap: switch to hands-free and keep the same recording going.
            doubleTapWork?.cancel()
            state = .handsFree
            mode = .handsFree
            ignoreNextUp = true
            showRecordingPill()
            sound("Tink")

        case (.down, .handsFree):
            ignoreNextUp = false
            stopOnUp = true

        case (.up, _) where ignoreNextUp:
            ignoreNextUp = false

        case (.up, .handsFree) where stopOnUp:
            stopOnUp = false
            finishRecording()

        case (.up, .holding(let since)):
            if Date().timeIntervalSince(since) * 1000 < Double(config.tapMaxMs) {
                state = .awaitingSecondTap
                let work = DispatchWorkItem { [weak self] in
                    guard let self, case .awaitingSecondTap = self.state else { return }
                    self.cancelRecording() // a single short tap: nothing to transcribe
                }
                doubleTapWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(config.doubleTapWindowMs), execute: work)
            } else {
                finishRecording()
            }

        default:
            break
        }
    }

    /// Called when the app is switched off from the menu, or quits.
    func shutdown() {
        if isRecording { cancelRecording() }
        cancelJobs()
    }

    /// Called when the hotkey changes: the old key's release will never arrive.
    func cancelActiveRecording() {
        if isRecording { cancelRecording() }
    }

    /// A short message in the pill (for other features).
    func notify(_ text: String, isError: Bool = false) {
        flash(text, isError: isError, seconds: isError ? 3 : 1.8)
    }

    private func escape() {
        if isRecording {
            cancelRecording()
            flash(L("Cancelled", "Cancelado"))
        } else if isProcessing {
            cancelJobs()
            flash(L("Cancelled", "Cancelado"))
        }
    }

    // MARK: Recording

    private func beginHold() {
        ignoreNextUp = false
        stopOnUp = false
        guard startRecording(.hold) else { return }
        state = .holding(since: Date())
        onActivityChange?()
    }

    private func startRecording(_ mode: RecordingMode) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            flash(L("Allow microphone access, then try again", "Permití el micrófono y probá de nuevo"), isError: true)
            return false
        default:
            flash(L("Microphone access is off for Murmur", "Murmur no tiene permiso de micrófono"), isError: true)
            return false
        }

        self.mode = mode
        recordingStart = Date()
        onRecordingStart?()
        recorder.start { [weak self] error in
            guard let self, self.isRecording else { return }
            self.cancelRecording()
            self.flash(error.localizedDescription, isError: true)
        }
        streaming = StreamingTranscription(config: config)
        Transcriber.warmUp(config: config)
        Cleanup.warmUp(config: config)

        let auto = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            Log.info("Max recording length reached; stopping")
            self.finishRecording()
        }
        autoStopWork = auto
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(min(max(5, config.maxRecordingSeconds), 4 * 3600)), execute: auto)

        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pill.model.elapsed = Date().timeIntervalSince(self.recordingStart)
            self.streaming?.poll(self.recorder)
        }
        showRecordingPill()
        sound("Tink")
        return true
    }

    private func finishRecording() {
        let samples = recorder.stop()
        let session = streaming ?? StreamingTranscription(config: config)
        streaming = nil
        endRecordingState()
        sound("Pop")
        enqueue(samples, session)
    }

    private func cancelRecording() {
        recorder.cancel()
        streaming?.cancel()
        streaming = nil
        endRecordingState()
        refreshPill()
    }

    private func endRecordingState() {
        state = .idle
        stopOnUp = false
        doubleTapWork?.cancel()
        autoStopWork?.cancel()
        ticker?.invalidate()
        ticker = nil
        onActivityChange?()
    }

    // MARK: Processing

    private func enqueue(_ samples: [Float], _ session: StreamingTranscription) {
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        guard seconds >= 0.3 else {
            session.cancel()
            refreshPill()
            return
        }
        guard AudioUtil.peakRMS(samples) >= 0.004 else {
            session.cancel()
            flash(L("No speech detected", "No se escuchó nada"))
            return
        }

        let id = UUID()
        let previous = tail
        let config = self.config
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.process(samples, session, config: config)
            self?.jobs[id] = nil
            self?.refreshPill()
            self?.onActivityChange?()
        }
        jobs[id] = task
        tail = task
        refreshPill()
        onActivityChange?()
    }

    @MainActor
    private func process(_ samples: [Float], _ session: StreamingTranscription, config: Config) async {
        guard !Task.isCancelled else {
            session.cancel()
            return
        }
        do {
            // A safety net: whatever happens underneath, the pill never stays on "Transcribing…" for good.
            let started = Date()
            let result = try await withWatchdog(seconds: 120) { try await session.finish(samples) }
            Log.info(String(format: "Ready to paste %.0f ms after you stopped", Date().timeIntervalSince(started) * 1000))
            try Task.checkCancellation()
            guard !result.raw.isEmpty else {
                flash(L("No speech detected", "No se escuchó nada"))
                return
            }

            var text = postProcess?(result.text) ?? result.text
            let final = text

            lastTranscript = final
            onTranscript?(final, result.raw, Double(samples.count) / AudioRecorder.sampleRate)
            if config.insertion.trailingSpace, !text.hasSuffix("\n") { text += " " }
            if NSApp.isActive {
                // Murmur's own window is in front: type into its text box (a note), or else leave it on the clipboard.
                if let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isEditable {
                    view.insertText(text, replacementRange: view.selectedRange())
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(final, forType: .string)
                }
            } else if Permissions.accessibility {
                TextInserter.insert(text, config: config.insertion)
                onPasted?(final)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                flash(L("Copied. Grant Accessibility to auto-paste", "Copiado. Dale permiso de Accesibilidad para pegar solo"), isError: true, seconds: 3)
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            Log.error("Transcription failed: \(error.localizedDescription)")
            flash(error.localizedDescription, isError: true, seconds: 3)
        }
    }

    private func cancelJobs() {
        jobs.values.forEach { $0.cancel() }
    }

    // MARK: Pill

    private func showRecordingPill() {
        if config.showPill { pill.show(.recording(mode)) }
    }

    /// Recording beats processing beats nothing.
    private func refreshPill() {
        guard config.showPill else { return pill.hide() }
        if isRecording {
            pill.show(.recording(mode))
        } else if isProcessing || externalWork {
            pill.show(.working)
        } else if case .message = pill.model.phase {
            return // let the message time out
        } else {
            pill.hide()
        }
    }

    private func flash(_ text: String, isError: Bool = false, seconds: Double = 1.6) {
        guard config.showPill, !isRecording else { return }
        pill.flash(text, isError: isError, seconds: seconds)
        // Once the message is gone, bring back "Transcribing…" if another job is still running.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in self?.refreshPill() }
    }

    private func sound(_ name: String) {
        guard config.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

import AppKit
import SwiftUI

enum RecordingMode { case hold, handsFree }

final class PillModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording(RecordingMode)
        case working
        case message(String, isError: Bool)
    }

    /// Half of the bars: the waveform is mirrored, newest level in the middle.
    static let historyCount = 7

    @Published var phase: Phase = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: PillModel.historyCount)
    @Published var elapsed: TimeInterval = 0
    var maxSeconds: TimeInterval = 300

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    func push(level: Float) {
        levels.removeLast()
        levels.insert(level, at: 0)
    }
}

/// A small floating capsule near the bottom of the screen. Never takes focus.
/// It ignores the mouse, except in hands-free mode, where it has cancel and stop buttons.
final class PillWindow {
    let model = PillModel()
    /// The ✕ and ■ buttons of the hands-free pill.
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?

    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    /// Bottom center of the pill on screen, fixed while it's visible.
    private var anchor = NSPoint.zero

    /// Wide enough for messages; transparent and click-through.
    private static let wideSize = NSSize(width: 520, height: 64)
    /// Hands-free takes clicks, so the panel shrinks to roughly the capsule.
    private static let buttonsSize = NSSize(width: 260, height: 64)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.wideSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.canHide = false // stays visible when Murmur's window is hidden with Cmd-H
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = PillView(model: model,
                            cancel: { [weak self] in self?.onCancel?() },
                            stop: { [weak self] in self?.onStop?() })
        let host = ClickThroughHostingView(rootView: view)
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func show(_ phase: PillModel.Phase) {
        hideWork?.cancel()
        if case .recording = phase, !model.isRecording {
            model.levels = Array(repeating: 0, count: PillModel.historyCount)
            model.elapsed = 0
        }
        model.phase = phase
        if !panel.isVisible { anchor = Self.bottomCenter() }
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Shows a short message, then hides.
    func flash(_ text: String, isError: Bool = false, seconds: Double = 1.6) {
        show(.message(text, isError: isError))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        model.phase = .hidden
        panel.orderOut(nil)
    }

    private func layout() {
        let buttons = model.phase == .recording(.handsFree)
        let size = buttons ? Self.buttonsSize : Self.wideSize
        panel.ignoresMouseEvents = !buttons
        let frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Bottom center of the screen the mouse is on, just above the Dock.
    private static func bottomCenter() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        return NSPoint(x: visible.midX, y: visible.minY + 10)
    }
}

/// Buttons work on the first click, without making the panel key or activating Murmur.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PillView: View {
    @ObservedObject var model: PillModel
    var cancel: () -> Void = {}
    var stop: () -> Void = {}

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.phase != .hidden {
                content
                    .frame(height: 32)
                    .background(Capsule().fill(Color.black))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .foregroundColor(.white)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.bottom, 10) // room for the shadow
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.phase)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .recording(.hold):
            Waveform(levels: model.levels)
                .padding(.horizontal, 16)

        case .recording(.handsFree):
            HStack(spacing: 10) {
                PillButton(systemName: "xmark", fill: Color.white.opacity(0.18), help: L("Cancel (Esc)", "Cancelar (Esc)"), action: cancel)
                Waveform(levels: model.levels)
                let remaining = model.maxSeconds - model.elapsed
                if remaining <= 30 {
                    Text(L("\(Int(max(0, remaining)))s left", "quedan \(Int(max(0, remaining)))s"))
                        .monospacedDigit()
                        .foregroundColor(.orange)
                        .fixedSize()
                }
                PillButton(systemName: "stop.fill", fill: Color(red: 0.94, green: 0.27, blue: 0.27), help: L("Stop and paste", "Terminar y pegar"), action: stop)
            }
            .padding(.horizontal, 5)

        case .working:
            Ripple(count: PillModel.historyCount * 2)
                .padding(.horizontal, 16)

        case .message(let text, let isError):
            HStack(spacing: 6) {
                if isError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                }
                Text(text).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 14)

        case .hidden:
            EmptyView()
        }
    }
}

private struct PillButton: View {
    let systemName: String
    let fill: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private enum Bars {
    static let width: CGFloat = 3
    static let spacing: CGFloat = 2.5
    static let minHeight: CGFloat = 3
    static let maxHeight: CGFloat = 20

    /// Bars at the edges are a bit shorter, so the waveform tapers like a lens.
    static func taper(_ i: Int, of count: Int) -> CGFloat {
        let middle = CGFloat(count - 1) / 2
        let distance = abs(CGFloat(i) - middle) / max(middle, 1)
        return 1 - 0.45 * distance * distance
    }
}

/// The voice level, mirrored: the newest level is in the middle and older ones move outwards.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        let count = levels.count * 2
        HStack(alignment: .center, spacing: Bars.spacing) {
            ForEach(0..<count, id: \.self) { i in
                let age = i < levels.count ? levels.count - 1 - i : i - levels.count
                let level = CGFloat(min(1, max(0, levels[age])))
                Capsule()
                    .fill(Color.white)
                    .frame(width: Bars.width,
                           height: Bars.minHeight + level * Bars.taper(i, of: count) * (Bars.maxHeight - Bars.minHeight))
            }
        }
        .frame(height: Bars.maxHeight)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}

/// While transcribing: the bars shrink to dots and a soft wave runs through them.
private struct Ripple: View {
    let count: Int

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: Bars.spacing) {
                ForEach(0..<count, id: \.self) { i in
                    let wave = max(0, sin(t * 5 - Double(i) * 0.55))
                    Capsule()
                        .fill(Color.white.opacity(0.45 + 0.55 * wave))
                        .frame(width: Bars.width, height: Bars.minHeight + CGFloat(wave) * 5)
                }
            }
            .frame(height: Bars.maxHeight)
        }
    }
}

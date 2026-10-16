import AppKit
import SwiftUI

enum RecordingMode { case hold, handsFree }

final class PillModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording(RecordingMode)
        case working(String)
        case message(String, isError: Bool)
    }

    @Published var phase: Phase = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: 14)
    @Published var elapsed: TimeInterval = 0
    var maxSeconds: TimeInterval = 300

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

/// A small floating capsule near the bottom of the screen. Never takes focus, ignores the mouse.
final class PillWindow {
    let model = PillModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        // Wider than the capsule needs; the panel is transparent and click-through.
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    func show(_ phase: PillModel.Phase) {
        hideWork?.cancel()
        if case .recording = phase, !model.isRecording {
            model.levels = Array(repeating: 0, count: model.levels.count)
            model.elapsed = 0
        }
        model.phase = phase
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        }
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

    /// Bottom center of the screen the mouse is on, just above the Dock.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 18))
    }
}

private struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.phase != .hidden {
                content
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .foregroundColor(.white)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .recording(let mode):
            HStack(spacing: 8) {
                PulsingDot(color: mode == .hold ? .red : .orange)
                Text(mode == .hold ? L("Hold", "Mantené") : L("Hands-free", "Manos libres"))
                Waveform(levels: model.levels)
                if mode == .handsFree {
                    let remaining = model.maxSeconds - model.elapsed
                    Text(remaining <= 30 ? L("\(Int(max(0, remaining)))s left", "quedan \(Int(max(0, remaining)))s") : clock(model.elapsed))
                        .monospacedDigit()
                        .foregroundColor(remaining <= 30 ? .orange : .white.opacity(0.7))
                }
            }
        case .working(let label):
            HStack(spacing: 8) {
                Spinner()
                Text(label)
            }
        case .message(let text, let isError):
            HStack(spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "xmark.circle")
                    .foregroundColor(isError ? .yellow : .white.opacity(0.7))
                Text(text).lineLimit(1).truncationMode(.middle)
            }
        case .hidden:
            EmptyView()
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

private struct Spinner: View {
    @State private var angle = 0.0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2.5, height: 3 + CGFloat(levels[i]) * 15)
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

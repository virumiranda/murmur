import SwiftUI

/// Pick how dictations read in each kind of app.
struct StyleView: View {
    @ObservedObject var store: PersonalizationStore

    private let sample = L("Hi, how are you? See you tomorrow at 10. Bring the photos.",
                           "Hola, ¿cómo estás? Nos vemos mañana a las 10. Llevá las fotos.")

    var body: some View {
        Page(title: L("Style", "Estilo"),
             subtitle: L("How your dictation is written depending on where you're typing. Murmur notices the app by itself, and the style doesn't add any wait.",
                         "Cómo queda escrito tu dictado según dónde estás escribiendo. Murmur se da cuenta solo de la app, y el estilo no agrega demora.")) {
            ForEach(PersonalizationStore.AppKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(.system(size: 15, weight: .semibold))
                        Text(kind.examples).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(PersonalizationStore.Tone.allCases) { tone in
                            ToneTile(tone: tone, sample: Style.apply(tone, to: sample),
                                     selected: store.tone(for: kind) == tone) {
                                store.tones[kind] = tone
                            }
                        }
                    }
                }
                .card(padding: 16)
            }
        }
    }
}

private struct ToneTile: View {
    let tone: PersonalizationStore.Tone
    let sample: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tone.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selected ? .accentColor : .secondary.opacity(0.5))
                }
                Text(tone.detail).font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sample)
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.08) : hovering ? Color.primary.opacity(0.03) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

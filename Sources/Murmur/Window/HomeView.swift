import SwiftUI

/// Every dictation, grouped by day, ready to copy again.
struct HomeView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var status: AppStatus
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryStore.Entry] {
        query.isEmpty ? history.entries : history.entries.filter { $0.text.matches(query) || ($0.raw ?? "").matches(query) }
    }

    private struct Day: Identifiable {
        let id: Date
        let entries: [HistoryStore.Entry]
    }

    private var days: [Day] {
        let cal = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [HistoryStore.Entry]] = [:]
        for entry in filtered { // already newest first
            let day = cal.startOfDay(for: entry.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.map { Day(id: $0, entries: byDay[$0]!) }
    }

    var body: some View {
        Page(title: L("Your dictations", "Tus dictados"),
             subtitle: L("Hold \(status.hotkey), talk, and let go. Everything you dictate is kept here so you can copy it again.",
                         "Mantené \(status.hotkey), hablá y soltá. Todo lo que dictás queda guardado acá para copiarlo cuando quieras.")) {
            if !status.missing.isEmpty, let pane = status.missing.first {
                Notice(text: L("Murmur needs permissions to work: ", "Murmur necesita permisos para funcionar: ")
                    + status.missing.map(\.title).joined(separator: ", "),
                       action: (L("Open Settings", "Abrir Ajustes"), { Permissions.open(pane) }))
            }

            if !history.entries.isEmpty { stats }

            HStack(spacing: 10) {
                searchField($query, prompt: L("Search your dictations", "Buscar en tus dictados"))
                Menu {
                    Button(L("Clear history…", "Borrar historial…"), role: .destructive) { confirmClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(history.entries.isEmpty)
            }

            if days.isEmpty {
                empty
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(days) { day in
                        Text(Format.dayTitle(day.id).uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, 10)
                            .padding(.leading, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(day.entries.enumerated()), id: \.element.id) { i, entry in
                                if i > 0 { Divider().padding(.leading, 16) }
                                HistoryRow(entry: entry, onDelete: { history.remove(entry.id) })
                            }
                        }
                        .card()
                    }
                }
            }
        }
        .confirmationDialog(L("Clear all your dictation history?", "¿Borrar todo el historial de dictados?"),
                            isPresented: $confirmClear) {
            Button(L("Clear history", "Borrar historial"), role: .destructive) { history.clear() }
        } message: {
            Text(L("This can't be undone.", "No se puede deshacer."))
        }
    }

    private var stats: some View {
        let entries = history.entries
        let words = entries.reduce(0) { $0 + $1.words }
        let seconds = entries.reduce(0) { $0 + $1.seconds }
        let wpm = seconds > 30 ? Int(Double(words) / (seconds / 60)) : nil
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let week = entries.filter { $0.date > weekAgo }.reduce(0) { $0 + $1.words }
        return HStack(spacing: 12) {
            Stat(value: Format.number(week), label: L("words this week", "palabras esta semana"), icon: "flame")
            Stat(value: Format.number(words), label: L("words in total", "palabras en total"), icon: "text.word.spacing")
            Stat(value: wpm.map { Format.number($0) } ?? "–", label: L("words per minute", "palabras por minuto"), icon: "speedometer")
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.secondary)
            Text(query.isEmpty ? L("No dictations yet", "Todavía no hay dictados") : L("Nothing found", "No se encontró nada"))
                .font(.system(size: 15, weight: .semibold))
            if query.isEmpty {
                Text(L("Hold \(status.hotkey) in any app, talk, and let go. What you say shows up here too.",
                       "Mantené \(status.hotkey) en cualquier app, hablá y soltá. Lo que digas va a aparecer también acá."))
                    .font(.system(size: 13)).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .card()
    }
}

private struct Stat: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15)).foregroundColor(.accentColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .card()
    }
}

private struct HistoryRow: View {
    let entry: HistoryStore.Entry
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(Format.time.string(from: entry.date))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let app = entry.app {
                    Text(app).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            HStack(spacing: 2) {
                CopyButton(text: { entry.text })
                Menu {
                    if let raw = entry.raw {
                        Button(L("Copy original (before cleanup)", "Copiar original (sin limpiar)")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(raw, forType: .string)
                        }
                    }
                    Button(L("Delete", "Borrar"), role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(hovering ? Color.primary.opacity(0.035) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension Permissions.Pane {
    var title: String {
        switch self {
        case .accessibility: return L("Accessibility", "Accesibilidad")
        case .inputMonitoring: return L("Input Monitoring", "Monitorización de entrada")
        case .microphone: return L("Microphone", "Micrófono")
        }
    }
}

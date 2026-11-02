import Foundation

/// The text of past dictations, newest first, in ~/.config/murmur/history.json (readable only by you).
/// Audio is never kept. Main thread only.
final class HistoryStore: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var date = Date()
        /// What was pasted (after cleanup).
        var text: String
        /// The transcript before cleanup, only when it differs.
        var raw: String?
        /// The app it was dictated into.
        var app: String?
        /// Length of the recording.
        var seconds: Double

        var words: Int { text.wordCount }
    }

    /// Oldest entries beyond this are dropped.
    static let limit = 2000

    @Published private(set) var entries: [Entry] = []
    private let url: URL

    init(url: URL = Paths.historyFile) {
        self.url = url
        entries = PrivateFile.load([Entry].self, from: url) ?? []
    }

    func add(text: String, raw: String, seconds: Double, app: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.insert(Entry(text: text, raw: raw == text ? nil : raw, app: app, seconds: seconds), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() { PrivateFile.save(entries, to: url) }
}

extension String {
    var wordCount: Int { split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
}

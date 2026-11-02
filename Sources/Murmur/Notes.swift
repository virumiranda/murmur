import Foundation

/// Scratchpad notes and meeting notes, in ~/.config/murmur/notes.json. Main thread only.
final class NotesStore: ObservableObject {
    struct Note: Codable, Identifiable, Equatable {
        var id = UUID()
        var created = Date()
        var updated = Date()
        var body = ""
        var pinned = false
        /// Set for notes made by the meeting notetaker.
        var meeting: Meeting?

        struct Meeting: Codable, Equatable {
            var title: String
            var seconds: Double
            /// Summary, key points and tasks, written by the AI. nil if there was no AI available or it failed.
            var summary: String?
            var transcript: String
            var systemAudio: Bool
        }

        var title: String {
            if let meeting { return meeting.title }
            let first = body.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return first.isEmpty ? L("New note", "Nota nueva") : String(first.prefix(80))
        }

        /// The note's text after its first line, for the list.
        var preview: String {
            if let meeting {
                guard let summary = meeting.summary else { return meeting.transcript }
                return summary.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.joined(separator: " ")
            }
            let lines = body.split(whereSeparator: \.isNewline)
            return lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
    }

    @Published private(set) var notes: [Note] = []
    private let url: URL
    private var saveWork: DispatchWorkItem?

    init(url: URL = Paths.configDir.appendingPathComponent("notes.json")) {
        self.url = url
        notes = PrivateFile.load([Note].self, from: url) ?? []
    }

    var scratchpad: [Note] { sorted(notes.filter { $0.meeting == nil }) }
    var meetings: [Note] { notes.filter { $0.meeting != nil }.sorted { $0.created > $1.created } }

    func note(_ id: Note.ID?) -> Note? { notes.first { $0.id == id } }

    @discardableResult
    func create(body: String = "") -> Note.ID {
        let note = Note(body: body)
        notes.insert(note, at: 0)
        save(now: true)
        return note.id
    }

    func add(_ note: Note) {
        notes.insert(note, at: 0)
        save(now: true)
    }

    func update(_ id: Note.ID, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].body != body else { return }
        notes[i].body = body
        notes[i].updated = Date()
        save(now: false)
    }

    func togglePin(_ id: Note.ID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].pinned.toggle()
        save(now: true)
    }

    func delete(_ id: Note.ID) {
        notes.removeAll { $0.id == id }
        save(now: true)
    }

    /// Pinned first, then the most recently edited.
    private func sorted(_ list: [Note]) -> [Note] {
        list.sorted { a, b in
            a.pinned != b.pinned ? a.pinned : a.updated > b.updated
        }
    }

    /// Typing saves after a short pause; everything else right away.
    private func save(now: Bool) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            PrivateFile.save(self.notes, to: self.url)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.6), execute: work)
    }

    /// Writes any pending edit (on quit).
    func flush() {
        guard let work = saveWork, !work.isCancelled else { return }
        work.perform()
        work.cancel()
    }
}

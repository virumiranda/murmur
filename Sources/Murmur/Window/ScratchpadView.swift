import SwiftUI

/// Quick notes you type or dictate: hold the hotkey while the note is open and the text lands in it.
struct ScratchpadView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var status: AppStatus
    @State private var selection: NotesStore.Note.ID?
    @State private var query = ""
    @State private var confirmDelete = false

    private var notes: [NotesStore.Note] {
        store.scratchpad.filter { $0.body.matches(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 260)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil { selection = store.scratchpad.first?.id }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Scratchpad", "Bloc de notas")).font(.system(size: 22, weight: .semibold, design: .serif))
                Spacer()
                Button {
                    selection = store.create()
                    query = ""
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help(L("New note", "Nota nueva"))
                .keyboardShortcut("n", modifiers: .command)
            }
            searchField($query, prompt: L("Search notes", "Buscar notas"))
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(notes) { note in
                        NoteRow(note: note, selected: note.id == selection)
                            .onTapGesture { selection = note.id }
                            .contextMenu {
                                Button(note.pinned ? L("Unpin", "Desfijar") : L("Pin", "Fijar")) { store.togglePin(note.id) }
                                Button(L("Delete", "Borrar"), role: .destructive) { delete(note.id) }
                            }
                    }
                }
            }
            if notes.isEmpty {
                Text(query.isEmpty ? L("No notes yet.", "Todavía no hay notas.") : L("Nothing found.", "No se encontró nada."))
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var editor: some View {
        if let id = selection, let note = store.note(id), note.meeting == nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(L("Edited ", "Editada ") + Format.short.string(from: note.updated))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button { store.togglePin(id) } label: {
                        Image(systemName: note.pinned ? "pin.fill" : "pin")
                    }
                    .help(note.pinned ? L("Unpin", "Desfijar") : L("Pin to the top", "Fijar arriba"))
                    CopyButton(text: { store.note(id)?.body ?? "" })
                    Button { confirmDelete = true } label: { Image(systemName: "trash") }
                        .help(L("Delete note", "Borrar nota"))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 24)
                .padding(.top, 30)
                .padding(.bottom, 8)

                TextEditor(text: Binding(get: { store.note(id)?.body ?? "" },
                                         set: { store.update(id, body: $0) }))
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 20)
                    .id(id) // a fresh editor (and cursor) per note

                Text(L("Hold \(status.hotkey) and talk to dictate into this note. Select text and press ⌃⌥1 to polish it.",
                       "Mantené \(status.hotkey) y hablá para dictar en esta nota. Seleccioná un texto y apretá ⌃⌥1 para pulirlo."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .confirmationDialog(L("Delete this note?", "¿Borrar esta nota?"), isPresented: $confirmDelete) {
                Button(L("Delete", "Borrar"), role: .destructive) { delete(id) }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "note.text").font(.system(size: 34, weight: .light)).foregroundColor(.secondary)
                Text(L("Write or dictate anything", "Escribí o dictá lo que quieras")).font(.system(size: 15, weight: .semibold))
                Text(L("Ideas, lists, drafts. Hold \(status.hotkey) inside a note to dictate.",
                       "Ideas, listas, borradores. Mantené \(status.hotkey) dentro de una nota para dictar."))
                    .font(.system(size: 13)).foregroundColor(.secondary)
                Button(L("New note", "Nota nueva")) { selection = store.create() }
                    .controlSize(.large)
            }
        }
    }

    private func delete(_ id: NotesStore.Note.ID) {
        let list = notes
        let index = list.firstIndex { $0.id == id } ?? 0
        store.delete(id)
        let rest = list.filter { $0.id != id }
        selection = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
    }
}

private struct NoteRow: View {
    let note: NotesStore.Note
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if note.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(.orange) }
                Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(Format.short.string(from: note.updated)).foregroundColor(.secondary)
                Text(note.preview).foregroundColor(.secondary).lineLimit(1)
            }
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
        .contentShape(Rectangle())
    }
}

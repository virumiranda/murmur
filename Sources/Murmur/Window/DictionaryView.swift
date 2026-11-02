import SwiftUI

/// Words and names Murmur must spell right, replacements, and the words it learned from your corrections.
struct DictionaryView: View {
    @ObservedObject var store: PersonalizationStore
    @ObservedObject var status: AppStatus
    @State private var newWord = ""
    @State private var replaces = ""
    @State private var useReplacement = false
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var duplicate = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, learned, added, replacements
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("All", "Todas")
            case .learned: return L("Learned", "Aprendidas")
            case .added: return L("Added by you", "Agregadas por vos")
            case .replacements: return L("Replacements", "Reemplazos")
            }
        }
    }

    private var shown: [PersonalizationStore.Word] {
        store.words.filter { word in
            let passes: Bool
            switch filter {
            case .all: passes = true
            case .learned: passes = word.learned
            case .added: passes = !word.learned && word.replaces == nil
            case .replacements: passes = word.replaces != nil
            }
            return passes && (word.text.matches(query) || (word.replaces ?? "").matches(query))
        }
    }

    var body: some View {
        Page(title: L("Dictionary", "Diccionario"),
             subtitle: L("Names, brands and terms Murmur must spell exactly. It also learns on its own: when you fix a name after dictating it, the name is added here.",
                         "Nombres, marcas y palabras que Murmur tiene que escribir exacto. También aprende solo: cuando corregís un nombre después de dictarlo, se agrega acá.")) {
            addCard

            Toggle(isOn: $store.learnWords) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Learn words from my corrections", "Aprender palabras de mis correcciones"))
                        .font(.system(size: 13, weight: .medium))
                    Text(L("After pasting, Murmur looks at the text box for a minute. If you fix the spelling of a name, it learns it. Nothing is saved or sent.",
                           "Después de pegar, Murmur mira el cuadro de texto durante un minuto. Si corregís cómo se escribe un nombre, lo aprende. No se guarda ni se envía nada más."))
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .card(padding: 14)

            HStack(spacing: 10) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                searchField($query, prompt: L("Search", "Buscar"))
            }

            if shown.isEmpty {
                Text(store.words.isEmpty
                     ? L("Your dictionary is empty. Add the names you use often: people, companies, products.",
                         "Tu diccionario está vacío. Agregá los nombres que usás seguido: personas, empresas, productos.")
                     : L("Nothing here.", "No hay nada acá."))
                    .font(.system(size: 13)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, word in
                        if i > 0 { Divider().padding(.leading, 44) }
                        WordRow(word: word) { store.removeWord(word.id) }
                    }
                }
                .card()
            }

            if !status.configVocabulary.isEmpty {
                Text(L("Also in use, from \"vocabulary\" in config.json: ", "También se usan, desde \"vocabulary\" en config.json: ")
                     + status.configVocabulary.joined(separator: ", "))
                    .font(.system(size: 11.5)).foregroundColor(.secondary)
            }
        }
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if useReplacement {
                    TextField(L("When I say… (e.g. wisper flow)", "Cuando diga… (ej. wisper flow)"), text: $replaces)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                }
                TextField(useReplacement ? L("…write (e.g. Wispr Flow)", "…escribir (ej. Wispr Flow)")
                                         : L("Word or name (e.g. Wispr Flow)", "Palabra o nombre (ej. Wispr Flow)"),
                          text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(L("Add", "Agregar"), action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty
                              || (useReplacement && replaces.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            HStack {
                Toggle(L("Replace something that's heard differently", "Reemplazar algo que se escucha distinto"), isOn: $useReplacement)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                if duplicate {
                    Text(L("Already in your dictionary", "Ya está en tu diccionario"))
                        .font(.system(size: 12)).foregroundColor(.orange)
                }
            }
            if useReplacement {
                Text(L("Handy for shortcuts too: \"my email\" → your address.", "Sirve también para atajos: \"mi mail\" → tu dirección."))
                    .font(.system(size: 11.5)).foregroundColor(.secondary)
            }
        }
        .card(padding: 14)
    }

    private func add() {
        let ok = store.addWord(newWord, replaces: useReplacement ? replaces : nil)
        duplicate = !ok && !newWord.trimmingCharacters(in: .whitespaces).isEmpty
        if ok {
            newWord = ""
            replaces = ""
        }
    }
}

private struct WordRow: View {
    let word: PersonalizationStore.Word
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: word.learned ? "sparkles" : word.replaces != nil ? "arrow.left.arrow.right" : "character.cursor.ibeam")
                .foregroundColor(word.learned ? .purple : .secondary)
                .frame(width: 20)
            if let from = word.replaces {
                Text(from).foregroundColor(.secondary)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(.secondary)
            }
            Text(word.text).font(.system(size: 13.5, weight: .medium)).textSelection(.enabled)
            if word.learned {
                Text(L("learned", "aprendida"))
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.14)))
                    .foregroundColor(.purple)
            }
            Spacer()
            Text(Format.short.string(from: word.date)).font(.system(size: 11)).foregroundColor(.secondary)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(L("Remove", "Quitar"))
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

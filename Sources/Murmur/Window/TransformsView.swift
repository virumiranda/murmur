import SwiftUI

/// Rewrite selected text anywhere with a shortcut.
struct TransformsView: View {
    @ObservedObject var store: PersonalizationStore
    @ObservedObject var runner: TransformRunner
    @ObservedObject var status: AppStatus

    var body: some View {
        Page(title: "Transforms",
             subtitle: L("Select text in any app and press the shortcut: the AI rewrites it right there. Cmd-Z undoes it.",
                         "Seleccioná un texto en cualquier app y apretá el atajo: la IA lo reescribe ahí mismo. Cmd+Z lo deshace.")) {
            if status.aiName == nil {
                Notice(text: L("Transforms use the same AI as the cleanup. Add your Groq key (menu → Edit API Keys).",
                               "Transforms usa la misma IA que la limpieza. Agregá tu clave de Groq (menú → Editar claves de API)."))
            }
            if status.missing.contains(.accessibility) {
                Notice(text: L("Transforms need the Accessibility permission.", "Transforms necesita el permiso de Accesibilidad."),
                       action: (L("Open Settings", "Abrir Ajustes"), { Permissions.open(.accessibility) }))
            }

            Toggle(isOn: $store.transformsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Shortcuts on", "Atajos activados")).font(.system(size: 13, weight: .medium))
                    Text(L("⌃ Control + ⌥ Option + a number. Up to 3,000 words at a time.",
                           "⌃ Control + ⌥ Opción + un número. Hasta 3.000 palabras por vez."))
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .card(padding: 14)

            ForEach($store.transforms) { $transform in
                TransformCard(transform: $transform,
                              keyTaken: { key in store.transforms.contains { $0.key == key && $0.id != transform.id } },
                              onKey: { key in assign(key, to: transform.id) },
                              onReset: transform.builtin.map { id in { transform.instructions = PersonalizationStore.builtinInstructions(id) } },
                              onDelete: { store.transforms.removeAll { $0.id == transform.id } })
            }

            Button {
                store.transforms.append(PersonalizationStore.Transform(
                    name: L("My transform", "Mi transform"),
                    instructions: L("e.g. Make it shorter and friendlier.", "Por ejemplo: Hacelo más corto y más amable."),
                    key: store.freeKey))
            } label: {
                Label(L("New transform", "Nuevo transform"), systemImage: "plus")
            }

            if !runner.recent.isEmpty {
                Text(L("RECENT", "ÚLTIMOS")).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                    .padding(.top, 10)
                VStack(spacing: 0) {
                    ForEach(Array(runner.recent.enumerated()), id: \.element.id) { i, run in
                        if i > 0 { Divider() }
                        RunRow(run: run)
                    }
                }
                .card()
            }
        }
    }

    /// Gives a shortcut to one transform, taking it away from any other that had it.
    private func assign(_ key: Int, to id: UUID) {
        for i in store.transforms.indices {
            if store.transforms[i].id == id {
                store.transforms[i].key = key
            } else if key > 0, store.transforms[i].key == key {
                store.transforms[i].key = 0
            }
        }
    }
}

private struct TransformCard: View {
    @Binding var transform: PersonalizationStore.Transform
    let keyTaken: (Int) -> Bool
    let onKey: (Int) -> Void
    let onReset: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundColor(.accentColor).frame(width: 18)
                TextField(L("Name", "Nombre"), text: $transform.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: Binding(get: { transform.key }, set: onKey)) {
                    Text(L("No shortcut", "Sin atajo")).tag(0)
                    ForEach(1...9, id: \.self) { key in
                        Text("⌃⌥\(key)" + (keyTaken(key) ? L(" (in use)", " (en uso)") : "")).tag(key)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            TextEditor(text: $transform.instructions)
                .font(.system(size: 12.5))
                .frame(minHeight: 54, maxHeight: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
            HStack(spacing: 14) {
                Text(L("Instructions for the AI. Select text anywhere and press the shortcut.",
                       "Instrucciones para la IA. Seleccioná un texto en cualquier lado y apretá el atajo."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                if let onReset {
                    Button(L("Reset", "Restablecer"), action: onReset).buttonStyle(.link).font(.system(size: 12))
                } else {
                    Button(L("Delete", "Borrar"), role: .destructive, action: onDelete).buttonStyle(.link).font(.system(size: 12))
                }
            }
        }
        .card(padding: 14)
    }

    private var icon: String {
        switch transform.builtin {
        case "polish": return "sparkles"
        case "prompt": return "text.bubble"
        case "english": return "globe"
        default: return "wand.and.stars"
        }
    }
}

private struct RunRow: View {
    let run: TransformRunner.Run
    @State private var showBefore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.name).font(.system(size: 12, weight: .semibold))
                Text(Format.time.string(from: run.date)).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button(showBefore ? L("Show result", "Ver resultado") : L("Show original", "Ver original")) { showBefore.toggle() }
                    .buttonStyle(.link).font(.system(size: 11.5))
                CopyButton(text: { showBefore ? run.before : run.after }).buttonStyle(.borderless)
            }
            Text(showBefore ? run.before : run.after)
                .font(.system(size: 12.5))
                .foregroundColor(showBefore ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }
}

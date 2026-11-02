import SwiftUI

/// Record a meeting or a talk; get the transcript and a summary with key points and tasks.
struct NotetakerView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var notes: NotesStore
    @ObservedObject var status: AppStatus
    @State private var openMeeting: NotesStore.Note.ID?

    var body: some View {
        if let id = openMeeting, let note = notes.note(id), let meeting = note.meeting {
            MeetingDetail(note: note, meeting: meeting, onBack: { openMeeting = nil },
                          onDelete: { notes.delete(id); openMeeting = nil })
        } else {
            Page(title: L("Notetaker", "Tomador de notas"),
                 subtitle: L("Record a meeting or a conversation. Murmur transcribes it while people talk and, at the end, writes a summary with the key points and tasks. Only the text is kept, never the audio.",
                             "Grabá una reunión o una charla. Murmur la transcribe mientras la gente habla y, al final, arma un resumen con los puntos clave y las tareas. Solo se guarda el texto, nunca el audio.")) {
                recorderCard
                if let error = recorder.lastError {
                    Notice(text: error, action: (L("OK", "OK"), { recorder.lastError = nil }))
                }
                if status.aiName == nil {
                    Notice(text: L("Without an AI key you'll get the transcript but no summary. Add GROQ_API_KEY in the menu → Edit API Keys.",
                                   "Sin una clave de IA vas a tener la transcripción pero no el resumen. Agregá GROQ_API_KEY en el menú → Editar claves de API."))
                }
                meetingsList
            }
        }
    }

    // MARK: Recorder

    @ViewBuilder private var recorderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch recorder.phase {
            case .idle:
                HStack(alignment: .center, spacing: 16) {
                    Button(action: recorder.start) {
                        HStack(spacing: 8) {
                            Circle().fill(Color.white).frame(width: 10, height: 10)
                            Text(L("Start recording", "Empezar a grabar")).font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.red))
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L("Include the Mac's audio (Zoom, Meet, Teams…)", "Incluir el audio de la compu (Zoom, Meet, Teams…)"),
                               isOn: $recorder.includeSystemAudio)
                            .toggleStyle(.checkbox)
                            .disabled(!MeetingRecorder.systemAudioSupported)
                        Text(MeetingRecorder.systemAudioSupported
                             ? L("So the other people are heard even with headphones. macOS asks for permission the first time.",
                                 "Para que se escuche a los demás aunque uses auriculares. macOS pide permiso la primera vez.")
                             : L("Needs macOS 14.2 or later. Your microphone is still recorded.",
                                 "Necesita macOS 14.2 o más nuevo. Igual se graba tu micrófono."))
                            .font(.system(size: 11.5)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

            case .recording:
                HStack(spacing: 14) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                        .opacity(Int(recorder.elapsed * 2) % 2 == 0 ? 1 : 0.4)
                    Text(Format.duration(recorder.elapsed)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    LevelMeter(level: recorder.level)
                    Spacer()
                    Button(L("Discard", "Descartar"), role: .destructive, action: recorder.cancel)
                    Button(action: recorder.stop) {
                        Label(L("Finish", "Terminar"), systemImage: "stop.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Text(recorder.capturingSystemAudio
                     ? L("Recording your microphone and the Mac's audio.", "Grabando tu micrófono y el audio de la compu.")
                     : L("Recording your microphone.", "Grabando tu micrófono."))
                    .font(.system(size: 11.5)).foregroundColor(.secondary)
                liveTranscript

            case .finishing(let label):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(label).font(.system(size: 13))
                }
                liveTranscript
            }
        }
        .card(padding: 18)
    }

    @ViewBuilder private var liveTranscript: some View {
        if recorder.segments.isEmpty {
            Text(L("The transcript appears here every half minute or so.", "La transcripción aparece acá cada medio minuto, más o menos."))
                .font(.system(size: 12)).foregroundColor(.secondary)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(recorder.segments) { segment in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Format.duration(segment.offset)).font(.system(size: 11)).monospacedDigit()
                                    .foregroundColor(.secondary).frame(width: 46, alignment: .leading)
                                Text(segment.text).font(.system(size: 12.5)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(segment.id)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                .onChange(of: recorder.segments.count) { _ in
                    if let last = recorder.segments.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    // MARK: Past meetings

    @ViewBuilder private var meetingsList: some View {
        let meetings = notes.meetings
        if !meetings.isEmpty {
            Text(L("YOUR MEETINGS", "TUS REUNIONES")).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                .padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { i, note in
                    if i > 0 { Divider() }
                    MeetingRow(note: note).onTapGesture { openMeeting = note.id }
                }
            }
            .card()
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Float(i) / 12 < level ? Color.green : Color.primary.opacity(0.12))
                    .frame(width: 4, height: 14)
            }
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}

private struct MeetingRow: View {
    let note: NotesStore.Note
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2").foregroundColor(.accentColor).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(note.preview.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.short.string(from: note.created)).font(.system(size: 11)).foregroundColor(.secondary)
                Text(Format.duration(note.meeting?.seconds ?? 0)).font(.system(size: 11)).monospacedDigit().foregroundColor(.secondary)
            }
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(hovering ? Color.primary.opacity(0.035) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct MeetingDetail: View {
    let note: NotesStore.Note
    let meeting: NotesStore.Note.Meeting
    let onBack: () -> Void
    let onDelete: () -> Void
    @State private var showTranscript = false
    @State private var confirmDelete = false

    private var subtitle: String {
        var parts = [Format.dayTitle(note.created), Format.time.string(from: note.created), Format.duration(meeting.seconds)]
        if meeting.systemAudio { parts.append(L("microphone and Mac audio", "micrófono y audio de la compu")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: onBack) {
                    Label(L("All meetings", "Todas las reuniones"), systemImage: "chevron.left")
                }
                .buttonStyle(.link)

                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title).font(.system(size: 26, weight: .semibold, design: .serif))
                        .textSelection(.enabled)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
                }

                HStack(spacing: 10) {
                    if let summary = meeting.summary {
                        CopyButton(text: { summary }, label: L("Copy summary", "Copiar resumen"))
                    }
                    CopyButton(text: { meeting.transcript }, label: L("Copy transcript", "Copiar transcripción"))
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: { Label(L("Delete", "Borrar"), systemImage: "trash") }
                }

                if let summary = meeting.summary {
                    NotesText(text: summary).card(padding: 18)
                }

                DisclosureGroup(isExpanded: $showTranscript) {
                    Text(meeting.transcript)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } label: {
                    Text(L("Full transcript", "Transcripción completa")).font(.system(size: 14, weight: .semibold))
                }
                .card(padding: 16)
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 30)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { showTranscript = meeting.summary == nil }
        .confirmationDialog(L("Delete this meeting?", "¿Borrar esta reunión?"), isPresented: $confirmDelete) {
            Button(L("Delete", "Borrar"), role: .destructive, action: onDelete)
        }
    }
}

/// The summary's simple layout: "## " headings, "- " bullets, paragraphs.
private struct NotesText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    Text(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundColor(.secondary)
                        Text(inline(String(line.dropFirst(2)))).font(.system(size: 13)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if !line.isEmpty {
                    Text(inline(line)).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// **bold** and the like, if the AI used them.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

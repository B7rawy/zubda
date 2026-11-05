import AppKit
import SwiftUI

// The main window's Voice notes, Notes, Clients and Ask Claude pages.

private func isArabic(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
}

/// Page header used by every page: title, one line of context, optional trailing controls.
private struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .semibold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

private struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 320)
        .card()
    }
}

private struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 200)
        .card()
    }
}

private struct SmallButton: View {
    let title: String
    let icon: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(tint)
                .background(RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

private func dayTitle(_ day: Date) -> String {
    if Calendar.current.isDateInToday(day) { return "TODAY" }
    if Calendar.current.isDateInYesterday(day) { return "YESTERDAY" }
    return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()
}

// MARK: - Voice notes

struct VoicePage: View {
    @ObservedObject var library: Library
    @ObservedObject var voice: VoiceNotes
    @ObservedObject var config = ConfigStore.shared
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Voice notes", subtitle: "WhatsApp voice notes, transcribed on this Mac.") {
                SearchField(prompt: "Search voice notes", text: $search)
            }

            if !config.voiceWatch || voice.blocked { statusCard }

            if !voice.waiting.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WAITING").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(voice.waiting.enumerated()), id: \.element) { index, url in
                            if index > 0 { Divider().padding(.leading, 56) }
                            HStack(spacing: 14) {
                                icon("waveform.badge.mic", .green)
                                Text("New voice note").font(.system(size: 13, weight: .semibold))
                                Spacer()
                                SmallButton(title: "Transcribe", icon: "text.quote", tint: brand) {
                                    Task { await voice.transcribe(url); library.reload() }
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                    .card()
                }
            }

            let groups = grouped
            if groups.isEmpty {
                EmptyState(icon: "waveform", title: search.isEmpty ? "No voice notes yet" : "Nothing matches",
                           detail: search.isEmpty ? "New WhatsApp voice notes show up in the notch. Click Transcribe and they land here." : "Try other words.")
            }
            ForEach(groups, id: \.0) { day, notes in
                VStack(alignment: .leading, spacing: 8) {
                    Text(dayTitle(day)).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                            if index > 0 { Divider().padding(.leading, 56) }
                            VoiceRow(note: note)
                        }
                    }
                    .card()
                }
            }
        }
    }

    private var grouped: [(Date, [Library.VoiceNote])] {
        let notes = library.voiceNotes.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
        let byDay = Dictionary(grouping: notes) { Calendar.current.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { ($0, byDay[$0]!) }
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            icon(voice.blocked ? "exclamationmark.triangle.fill" : "waveform.badge.mic", voice.blocked ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.blocked ? "macOS is blocking WhatsApp's files" : "Watching for voice notes is off")
                    .font(.system(size: 13, weight: .semibold))
                Text(voice.blocked
                     ? "Allow Zubda under Privacy & Security, then turn it on again."
                     : "Turn it on and the notch offers to transcribe each new WhatsApp voice note.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if voice.blocked {
                SmallButton(title: "Open Settings", icon: "gearshape") { voice.openPrivacySettings() }
            }
            SmallButton(title: "Turn on", icon: "power", tint: brand) {
                config.voiceWatch = true
                config.save()
                voice.start()
            }
        }
        .padding(14)
        .card()
    }
}

private func icon(_ name: String, _ tint: Color) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: radius).fill(tint.opacity(0.12))
        Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
    }
    .frame(width: 30, height: 30)
}

/// A voice note that opens to show its full text, with Claude for a summary or a reply.
private struct VoiceRow: View {
    let note: Library.VoiceNote
    @State private var open = false
    @State private var working = false
    @State private var answer: (title: String, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(alignment: .top, spacing: 14) {
                    icon("waveform", .green)
                    Text(note.text)
                        .font(.system(size: 13))
                        .lineLimit(open ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, isArabic(note.text) ? .rightToLeft : .leftToRight)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(note.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        if !note.length.isEmpty { Text(note.length).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                HStack(spacing: 8) {
                    SmallButton(title: "Copy", icon: "doc.on.doc") { copy(note.text) }
                    SmallButton(title: "Summarise", icon: "sparkles") { run(reply: false) }
                    SmallButton(title: "Suggest a reply", icon: "arrowshape.turn.up.left") { run(reply: true) }
                    if working { ProgressView().controlSize(.small) }
                }
                .padding(.leading, 44)
                if let answer {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(answer.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(brand)
                            Spacer()
                            Button { copy(answer.text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        Text(answer.text).font(.system(size: 13)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, isArabic(answer.text) ? .rightToLeft : .leftToRight)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: radius).fill(brand.opacity(0.06)))
                    .padding(.leading, 44)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func run(reply: Bool) {
        working = true
        let prompt = reply
            ? "Here is a voice note \(Paths.userName) received. Suggest a short, natural reply in the same language and dialect. Only the reply.\n\n\(note.text)"
            : "Here is a voice note \(Paths.userName) received. In \(Paths.reportLanguage), give the gist in at most 3 short bullets, then anything they are asked to do.\n\n\(note.text)"
        Task {
            let text = await VoiceNotes.runClaude(prompt) ?? "Couldn't reach Claude."
            answer = (reply ? "Suggested reply" : "Summary", text)
            working = false
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Notes

struct NotesPage: View {
    @ObservedObject var library: Library
    @ObservedObject var voice: VoiceNotes
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Notes", subtitle: "Thoughts you said out loud, written down. Press ⌃⌥N anywhere.") {
                SearchField(prompt: "Search notes", text: $search)
            }

            recordCard

            let notes = library.notes.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
            if notes.isEmpty {
                EmptyState(icon: "note.text", title: search.isEmpty ? "No notes yet" : "Nothing matches",
                           detail: search.isEmpty ? "Press ⌃⌥N, say what's on your mind, press it again. It lands here." : "Try other words.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        if index > 0 { Divider().padding(.leading, 56) }
                        HStack(alignment: .top, spacing: 14) {
                            icon("note.text", .orange)
                            Text(note.text)
                                .font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .environment(\.layoutDirection, isArabic(note.text) ? .rightToLeft : .leftToRight)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(note.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    Button { copy(note.text) } label: { Image(systemName: "doc.on.doc") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy")
                                    Button { library.delete(note) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete (kept in Notes/deleted.md)")
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                    }
                }
                .card()
            }
        }
    }

    private var recordCard: some View {
        HStack(spacing: 14) {
            icon(voice.recordingNote ? "mic.fill" : "mic", voice.recordingNote ? brand : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.recordingNote ? "Listening… press again to save" : "Say a note")
                    .font(.system(size: 13, weight: .semibold))
                Text("Transcribed on this Mac and saved here. Claude can read your notes too.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                voice.toggleNote()
                Task { try? await Task.sleep(for: .seconds(6)); library.reload() }
            } label: {
                Label(voice.recordingNote ? "Save note" : "Record", systemImage: voice.recordingNote ? "stop.fill" : "mic.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: radius).fill(brand))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .card()
    }
}

// MARK: - Clients

struct ClientsPage: View {
    @ObservedObject var library: Library
    @ObservedObject var recorder: Recorder
    @ObservedObject var config = ConfigStore.shared
    @State private var newClient = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Clients", subtitle: "Each client's meetings, open points, and the words to get right.") {
                HStack(spacing: 6) {
                    TextField("New client", text: $newClient).textFieldStyle(.plain)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newClient.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(width: 240)
                .card()
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(recorder.projects.filter { $0 != "General" }, id: \.self) { client in
                    ClientCard(client: client, meetings: library.meetings.filter { $0.client == client },
                               recorder: recorder, config: config)
                }
            }
            if recorder.projects.filter({ $0 != "General" }).isEmpty {
                EmptyState(icon: "folder", title: "No clients yet",
                           detail: "Add one above, or pick a client in the notch before recording.")
            }
        }
    }

    private func add() {
        recorder.addProject(newClient)
        newClient = ""
    }
}

private struct ClientCard: View {
    let client: String
    let meetings: [Library.Meeting]
    @ObservedObject var recorder: Recorder
    @ObservedObject var config: ConfigStore
    @State private var brief: Brief?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(client).font(.system(size: 15, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                SmallButton(title: "Meetings", icon: "person.2.wave.2") {
                    Navigator.shared.clientFilter = client
                    Navigator.shared.meeting = nil
                    Navigator.shared.section = .meetings
                }
            }

            if let brief, !brief.items.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Still open").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(brief.items.prefix(3), id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(brand).frame(width: 4, height: 4)
                            Text(item).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .environment(\.layoutDirection, isArabic(item) ? .rightToLeft : .leftToRight)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                field("Other names", "Arabic spelling, contact names…", Binding(
                    get: { (recorder.aliases[client] ?? []).joined(separator: "، ") },
                    set: { recorder.setAliases($0.components(separatedBy: CharacterSet(charactersIn: ",،")), for: client) }
                ))
                field("Words to spell right", "Names and terms Whisper gets wrong", Binding(
                    get: { config.vocabulary[client] ?? "" },
                    set: { config.vocabulary[client] = $0; config.save() }
                ))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
        .task(id: client) { brief = Brief.latest(for: client) }
    }

    private var subtitle: String {
        guard let last = meetings.first?.started else { return "No meetings yet" }
        let minutes = meetings.reduce(0) { $0 + $1.minutes }
        return "\(meetings.count) meeting\(meetings.count == 1 ? "" : "s") · \(minutes) min · last \(last.formatted(.relative(presentation: .named)))"
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.05)))
        }
    }
}

// MARK: - Ask Claude

struct AskPage: View {
    @ObservedObject var ask: Ask
    @ObservedObject var recorder: Recorder
    @State private var question = ""
    @State private var history: [(id: UUID, question: String, answer: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Ask Claude", subtitle: "Anything about any meeting, voice note or note. Answers cite the moment.") { EmptyView() }

            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(brand)
                TextField("e.g. What did the client say about the price?", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: radius).fill(question.isEmpty || ask.busy ? Color.secondary : brand))
                }
                .buttonStyle(.plain)
                .disabled(question.isEmpty || ask.busy)
            }
            .padding(12)
            .card()

            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { text in
                    Button(text) { question = text; send() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.05)))
                        .disabled(ask.busy)
                }
            }

            if case .asking(let q, let since) = ask.state {
                VStack(alignment: .leading, spacing: 8) {
                    Text(q).font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Claude is reading your meetings…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        Spacer()
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text("\(Int(context.date.timeIntervalSince(since)))s").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Button("Cancel") { ask.cancel() }
                    }
                }
                .padding(16)
                .card()
            }

            ForEach(history, id: \.id) { item in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(item.question).font(.system(size: 13.5, weight: .semibold))
                        Spacer()
                        Button { copy(item.answer) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy answer")
                    }
                    Text((try? AttributedString(markdown: item.answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(item.answer))
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, isArabic(item.answer) ? .rightToLeft : .leftToRight)
                }
                .padding(16)
                .card()
            }

            if history.isEmpty, ask.state == .idle {
                EmptyState(icon: "sparkles", title: "Ask about anything you recorded",
                           detail: "Claude searches your transcripts and reports on this Mac, and quotes the time of each answer.")
            }
        }
        .onChange(of: ask.state) { _, state in
            switch state {
            case .answered(let q, let a): history.insert((UUID(), q, a), at: 0)
            case .failed(let q, let reason): history.insert((UUID(), q, reason), at: 0)
            default: break
            }
        }
    }

    private var suggestions: [String] {
        let client = recorder.projects.first { $0 != "General" }
        return ["What did I promise to do this week?",
                client.map { "What's still open with \($0)?" } ?? "What's still open with my clients?",
                "Summarise my last meeting"]
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ask.ask(text)
        question = ""
    }
}

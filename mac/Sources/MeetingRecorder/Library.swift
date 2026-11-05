import Foundation

/// Everything recorded so far, read from the meetings folder for the main window.
@MainActor
final class Library: ObservableObject {
    struct Meeting: Identifiable, Equatable {
        var id: String { folder.path }
        let folder: URL
        let client: String
        let title: String
        let started: Date?
        let minutes: Int
        let inPerson: Bool
        let marks: Int
        let hasReport: Bool
        let hasTranscript: Bool
        let summary: String
        let recording: Bool
    }

    struct VoiceNote: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let length: String
        let text: String
    }

    struct Note: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let text: String
    }

    enum Activity: Identifiable {
        case meeting(Meeting)
        case voice(VoiceNote)
        case note(Note)

        var id: String {
            switch self {
            case .meeting(let m): "m\(m.id)"
            case .voice(let v): "v\(v.id)"
            case .note(let n): "n\(n.id)"
            }
        }

        var date: Date {
            switch self {
            case .meeting(let m): m.started ?? .distantPast
            case .voice(let v): v.date
            case .note(let n): n.date
            }
        }
    }

    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var voiceNotes: [VoiceNote] = []
    @Published private(set) var notes: [Note] = []

    var totalMinutes: Int { meetings.reduce(0) { $0 + $1.minutes } }
    var totalMarks: Int { meetings.reduce(0) { $0 + $1.marks } }
    var clients: [String] { Array(Set(meetings.map(\.client))).sorted() }

    /// Newest first, grouped by day.
    var activityByDay: [(day: Date, items: [Activity])] {
        let all = meetings.map(Activity.meeting) + voiceNotes.map(Activity.voice) + notes.map(Activity.note)
        let grouped = Dictionary(grouping: all) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day]!.sorted { $0.date > $1.date })
        }
    }

    private let root = Recorder.meetingsFolder

    /// Removes a spoken note from notes.md and keeps it in deleted.md, so it can be recovered.
    func delete(_ note: Note) {
        let file = root.appendingPathComponent("Notes/notes.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm"
        let line = "- \(format.string(from: note.date)) — \(note.text)"
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: line) else { return }
        lines.remove(at: index)
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let trash = root.appendingPathComponent("Notes/deleted.md")
        let old = (try? String(contentsOf: trash, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: trash, atomically: true, encoding: .utf8)
        reload()
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        meetings = folders.compactMap(Self.meeting).sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
        voiceNotes = Self.voiceNotes(in: root.appendingPathComponent("Voice notes"))
        notes = Self.notes(in: root.appendingPathComponent("Notes/notes.md"))
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let date = iso.date(from: text) { return date }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text)
    }

    static func meeting(_ folder: URL) -> Meeting? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              meta["status"] as? String != "interrupted" else { return nil }
        let started = date(meta["startedAt"])
        let ended = date(meta["endedAt"])
        let minutes = started.flatMap { s in ended.map { Int(($0.timeIntervalSince(s) / 60).rounded()) } } ?? 0
        var title = meta["title"] as? String ?? folder.lastPathComponent
        if title.hasPrefix("Meet - ") || title == "test" { title = meta["mode"] as? String == "room" ? "In-person meeting" : "Online meeting" }
        let report = folder.appendingPathComponent("report.md")
        return Meeting(
            folder: folder,
            client: meta["project"] as? String ?? "General",
            title: title,
            started: started,
            minutes: max(0, minutes),
            inPerson: meta["mode"] as? String == "room",
            marks: (meta["marks"] as? [Any])?.count ?? 0,
            hasReport: FileManager.default.fileExists(atPath: report.path),
            hasTranscript: FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path),
            summary: summary(of: report),
            recording: meta["status"] as? String == "recording"
        )
    }

    private static func summary(of report: URL) -> String {
        guard let text = try? String(contentsOf: report, encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.contains("ملخص") }) else { return "" }
        let body = lines[(start + 1)...].prefix { !$0.hasPrefix("## ") }
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-* ")) }
            .filter { !$0.isEmpty }
        return body.joined(separator: " ").replacingOccurrences(of: "**", with: "").prefix(260).description
    }

    private static func voiceNotes(in folder: URL) -> [VoiceNote] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm"
        var found: [VoiceNote] = []
        for file in files where file.pathExtension == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let date = file.deletingPathExtension().lastPathComponent
            for block in text.components(separatedBy: "## ").dropFirst() {
                let lines = block.components(separatedBy: "\n")
                let head = lines[0].components(separatedBy: " · ")
                let body = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let when = day.date(from: "\(date) \(head[0])"), !body.isEmpty else { continue }
                found.append(VoiceNote(date: when, length: head.count > 1 ? head[1] : "", text: body))
            }
        }
        return found.sorted { $0.date > $1.date }
    }

    private static func notes(in file: URL) -> [Note] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return text.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("- "), let dash = line.range(of: " — ") else { return nil }
            let stamp = String(line[line.index(line.startIndex, offsetBy: 2)..<dash.lowerBound])
            guard let date = format.date(from: stamp) else { return nil }
            return Note(date: date, text: String(line[dash.upperBound...]))
        }.sorted { $0.date > $1.date }
    }
}

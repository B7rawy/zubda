import AppKit

/// Finished recordings wait here to be transcribed and reported, one at a time, so a new
/// meeting can be recorded while an earlier one is still being processed.
@MainActor
final class ProcessingQueue: ObservableObject {
    enum Stage: Equatable {
        case waiting
        case transcribing
        case reporting
        case ready(report: Bool)
        case failed(String)

        var isActive: Bool { self == .transcribing || self == .reporting }
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let folder: URL
        let title: String
        var stage: Stage = .waiting
        var since = Date()
    }

    @Published private(set) var jobs: [Job] = []
    /// True for a minute after a job finishes, so the closed notch can say "Ready".
    @Published private(set) var justFinished = false

    /// Called after each report, so the pre-meeting brief picks up the newest one.
    var onReport: (() -> Void)?

    private var running = false
    private static let keptFinished = 4

    var active: Job? { jobs.first { $0.stage.isActive } }
    var waiting: Int { jobs.filter { $0.stage == .waiting }.count }

    /// Newest first, the way the notch lists them.
    var listed: [Job] { Array(jobs.reversed().prefix(3)) }

    func add(folder: URL, title: String) {
        guard !jobs.contains(where: { $0.folder == folder }) else { return }
        jobs.append(Job(folder: folder, title: title))
        trim()
        pump()
    }

    /// Picks up recordings the app saved but never got to transcribe, for example because it
    /// was quit while a queue was waiting.
    func resumeUnprocessed() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Recorder.meetingsFolder, includingPropertiesForKeys: nil
        )) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  meta["app"] as? String == "meeting-recorder-mac",
                  meta["status"] as? String == "done" else { continue }
            add(folder: folder, title: Self.title(for: meta))
        }
    }

    /// Stops working on a recording (if it is the one being processed) and moves it to the Trash.
    func discard(_ job: Job) {
        let wasActive = job.stage.isActive
        jobs.removeAll { $0.id == job.id }
        if wasActive { Transcriber.cancelCurrent() }
        try? FileManager.default.trashItem(at: job.folder, resultingItemURL: nil)
    }

    func open(_ job: Job) {
        Navigator.shared.open(meeting: job.folder)
    }

    static func title(for meta: [String: Any]) -> String {
        let project = meta["project"] as? String ?? "General"
        let kind = meta["mode"] as? String == "room" ? "In person" : "Online"
        var time = ""
        if let started = (meta["startedAt"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            time = " · " + formatter.string(from: started)
        }
        if let title = meta["title"] as? String, !["Online meeting", "In-person meeting"].contains(title) {
            return "\(project) · \(title)\(time)"
        }
        return "\(project) · \(kind)\(time)"
    }

    /// Fake jobs for screenshots (MR_PREVIEW); processes nothing.
    func showPreview() {
        let folder = Recorder.meetingsFolder
        jobs = [
            Job(folder: folder.appendingPathComponent("a"), title: "Acme · Online · 7:10 PM", stage: .ready(report: true)),
            Job(folder: folder.appendingPathComponent("b"), title: "Northwind · Online · 8:02 PM", stage: .reporting, since: Date().addingTimeInterval(-71)),
            Job(folder: folder.appendingPathComponent("c"), title: "Globex · In person · 8:40 PM", stage: .waiting),
        ]
        running = true
    }

    private func pump() {
        guard !running, let job = jobs.first(where: { $0.stage == .waiting }) else { return }
        running = true
        Task {
            set(job.id, .transcribing)
            if await Transcriber.run(folder: job.folder) {
                set(job.id, .reporting)
                let wrote = await Transcriber.writeReport(folder: job.folder)
                if wrote { Promises.schedule(folder: job.folder, title: job.title) }
                set(job.id, .ready(report: wrote))
                flashReady()
                onReport?()
            } else {
                set(job.id, .failed("Transcription failed"))
            }
            running = false
            pump()
        }
    }

    private func set(_ id: UUID, _ stage: Stage) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].stage = stage
        jobs[index].since = Date()
    }

    private func flashReady() {
        justFinished = true
        Task {
            try? await Task.sleep(for: .seconds(60))
            if active == nil { justFinished = false }
        }
    }

    private func trim() {
        while jobs.filter({ !$0.stage.isActive && $0.stage != .waiting }).count > Self.keptFinished,
              let oldest = jobs.firstIndex(where: { !$0.stage.isActive && $0.stage != .waiting }) {
            jobs.remove(at: oldest)
        }
    }
}

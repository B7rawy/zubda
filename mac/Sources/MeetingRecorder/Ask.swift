import AppKit

/// Answers a question from every recorded meeting, through Claude Code, read-only.
@MainActor
final class Ask: ObservableObject {
    enum State: Equatable {
        case idle
        case asking(question: String, since: Date)
        case answered(question: String, answer: String)
        case failed(question: String, reason: String)
    }

    @Published private(set) var state: State = .idle
    private var process: Process?

    private static let claude = Paths.claude

    private static var instructions: String { """
    Answer \(Paths.userName)'s question from their recorded meetings in this folder. Each subfolder is one \
    meeting: session.json (project, title, startedAt), transcript.md (timestamped; «أنا» is \
    \(Paths.userName)) and often report.md. Search with Grep first, then read only what is relevant. \
    Answer in \(Paths.reportLanguage), at most 8 short lines, and cite the meeting date and the \
    [hh:mm:ss] timestamp for each fact. If the meetings don't say, say so plainly; never guess. \
    Lines marked (غير واضح) may be wrong, so flag them if you rely on one.

    Question:
    """ }

    var busy: Bool {
        if case .asking = state { return true }
        return false
    }

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        run(question, prompt: Self.instructions + " " + question)
    }

    /// "What did I miss?": a few bullets about the last five minutes of the meeting in progress,
    /// read from the live transcript the recorder keeps writing.
    func catchUp(folder: URL) {
        run("What did I miss? (last 5 min)", prompt: """
        The meeting in \(folder.path) is still being recorded. Read live.jsonl there (one JSON object \
        per sentence: t = seconds from the start, speaker, text; «أنا» is \(Paths.userName)) and the \
        marks in session.json. Look at the last 5 minutes, measured from the last line's t. In \
        \(Paths.reportLanguage), give at most 5 short bullets: what was being discussed, any number, \
        date or decision, and anything asked of \(Paths.userName). Only what the file says; if it is \
        empty, say nothing has been transcribed yet.
        """)
    }

    private func run(_ question: String, prompt: String) {
        guard !busy else { return }
        state = .asking(question: question, since: Date())

        let process = Process()
        process.executableURL = Self.claude
        process.currentDirectoryURL = Recorder.meetingsFolder
        process.arguments = [
            "-p", prompt,
            "--strict-mcp-config",
            "--allowedTools", "Read", "Glob", "Grep",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Without this the CLI waits three seconds for piped input that never comes.
        process.standardInput = FileHandle.nullDevice
        self.process = process

        Task.detached {
            do {
                try process.run()
            } catch {
                await self.finish(question: question, answer: nil)
                return
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            await self.finish(question: question, answer: process.terminationStatus == 0 ? text : nil)
        }
    }

    /// Fake answer for screenshots (MR_PREVIEW).
    func showPreview() {
        state = .answered(question: "العميل قال إيه عن بوابة الدفع؟", answer: """
        - 2 نوفمبر [00:42:26]: اسم الشركة **«ثواني»**، بوابة عُمانية، وفيه بوابة تانية هيختاروا حسب العرض.
        - نفس الميتنج [00:00:36]: «بياخدوا أعتقد 1.5» — تقديره هو، مش رقم مؤكد.
        - [00:00:46]: الفلوس بتنزل في يوم أو يومين.
        - [00:01:12]: عايز كمان التحويل برقم الهاتف من أبليكيشن البنك.
        """)
    }

    func cancel() {
        process?.terminate()
        process = nil
        state = .idle
    }

    func clear() {
        if !busy { state = .idle }
    }

    func copyAnswer() {
        guard case .answered(_, let answer) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    private func finish(question: String, answer: String?) {
        guard case .asking(let asked, _) = state, asked == question else { return }
        process = nil
        if let answer, !answer.isEmpty {
            state = .answered(question: question, answer: answer)
        } else {
            state = .failed(question: question, reason: "Couldn't get an answer. Is the claude CLI logged in?")
        }
    }
}

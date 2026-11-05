import AppKit

/// WhatsApp voice notes and quick spoken notes.
///
/// Voice notes: WhatsApp on the Mac keeps each one as an .opus file. New ones show up in the
/// notch; nothing is transcribed until the user clicks, unless they turned on automatic
/// transcription for long ones. Summaries and reply ideas only run when asked.
/// Spoken notes: ⌃⌥N records the mic until pressed again, then saves the text to Notes/notes.md.
@MainActor
final class VoiceNotes: ObservableObject {
    enum Card: Equatable {
        case new(URL)
        case working(String)
        case result(title: String, text: String)
        case recordingNote(since: Date)
    }

    @Published var card: Card?
    /// True while a spoken note (⌃⌥N) is being recorded.
    @Published private(set) var recordingNote = false
    /// macOS refused access to WhatsApp's folder; the user has to allow it in System Settings.
    @Published private(set) var blocked = false
    /// Voice notes that arrived and haven't been transcribed, newest first.
    @Published private(set) var waiting: [URL] = []

    private var lastScan = Date()
    private var seen: Set<String> = []
    private var lastText = ""
    private var memoMic: MicCapture?
    private var memoSink: AudioSink?
    private var memoFile: URL?
    private var hideTask: Task<Void, Never>?

    private static let whatsApp = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media")

    private var timer: Timer?

    /// Starts watching only when the user turned it on: reading another app's folder makes macOS
    /// ask for permission, which shouldn't pop up out of nowhere.
    func start() {
        guard ConfigStore.shared.voiceWatch, timer == nil else { return }
        guard (try? FileManager.default.contentsOfDirectory(atPath: Self.whatsApp.path)) != nil else {
            blocked = FileManager.default.fileExists(atPath: Self.whatsApp.deletingLastPathComponent().path)
            return
        }
        blocked = false
        lastScan = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated { self.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Voice notes

    private func scan() {
        let since = lastScan
        lastScan = Date()
        guard let walker = FileManager.default.enumerator(
            at: Self.whatsApp, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var found: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if values?.isDirectory == true {
                // A folder that hasn't changed since the last look can't hold a new file.
                if modified < since.addingTimeInterval(-5) { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension == "opus", modified >= since.addingTimeInterval(-5),
                  !seen.contains(url.path) else { continue }
            seen.insert(url.path)
            found.append(url)
        }
        for url in found { arrived(url) }
    }

    private func arrived(_ url: URL) {
        waiting.insert(url, at: 0)
        if waiting.count > 5 { waiting.removeLast() }
        let config = ConfigStore.shared
        if config.voiceAuto {
            Task { await transcribe(url, minimum: config.voiceAutoMinSeconds, quiet: true) }
        } else {
            show(.new(url), hideAfter: 15)
        }
    }

    func transcribe(_ url: URL, minimum: Double = 0, quiet: Bool = false) async {
        if !quiet { show(.working("Transcribing the voice note…")) }
        let result = await Self.runVoice([url.path, "--save", "voice"] + (minimum > 0 ? ["--min", String(Int(minimum))] : []))
        waiting.removeAll { $0 == url }
        guard let (seconds, text) = result, !text.isEmpty else {
            if !quiet { show(.result(title: "Voice note", text: "Nothing to transcribe in this one.")) }
            return
        }
        lastText = text
        show(.result(title: "Voice note · \(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))", text: text))
    }

    /// Summary or reply idea from Claude for the last transcribed text.
    func askClaude(reply: Bool) async {
        guard !lastText.isEmpty else { return }
        let language = Paths.reportLanguage
        let prompt = reply
            ? "Here is a voice note \(Paths.userName) received. Suggest a short, natural reply in the same language and dialect as the note. Only the reply text.\n\n\(lastText)"
            : "Here is a voice note \(Paths.userName) received. In \(language), give the gist in at most 3 short bullets, then anything they are asked to do. Nothing else.\n\n\(lastText)"
        show(.working(reply ? "Claude is drafting a reply…" : "Claude is summarising…"))
        let answer = await Self.runClaude(prompt)
        show(.result(title: reply ? "Suggested reply" : "Summary", text: answer ?? "Couldn't reach Claude."))
    }

    func copy() {
        if case .result(_, let text) = card {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func dismiss() {
        hideTask?.cancel()
        card = nil
    }

    // MARK: Spoken notes

    var isRecordingNote: Bool { memoMic != nil }

    func toggleNote() {
        if isRecordingNote { Task { await finishNote() } } else { startNote() }
    }

    private func startNote() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).caf")
        guard let sink = try? AudioSink(url: file) else { return }
        let mic = MicCapture()
        do { try mic.start(into: sink) } catch {
            show(.result(title: "Note", text: "The microphone isn't available."))
            return
        }
        memoMic = mic
        memoSink = sink
        memoFile = file
        recordingNote = true
        show(.recordingNote(since: Date()))
    }

    private func finishNote() async {
        memoMic?.stop()
        memoSink?.close()
        memoMic = nil
        memoSink = nil
        recordingNote = false
        guard let file = memoFile else { return }
        memoFile = nil
        show(.working("Writing down your note…"))
        let result = await Self.runVoice([file.path, "--save", "notes"])
        try? FileManager.default.removeItem(at: file)
        if let (_, text) = result, !text.isEmpty {
            lastText = text
            show(.result(title: "Note saved", text: text), hideAfter: 8)
        } else {
            show(.result(title: "Note", text: "Didn't catch anything."), hideAfter: 5)
        }
    }

    // MARK: Helpers

    private func show(_ card: Card, hideAfter seconds: Double? = nil) {
        hideTask?.cancel()
        self.card = card
        guard let seconds else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled, self.card == card { self.card = nil }
        }
    }

    private static func runVoice(_ arguments: [String]) async -> (Double, String)? {
        let output = await run(Paths.python, [Paths.script("voice.py").path] + arguments)
        guard let line = output?.split(separator: "\n").last,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return (json["seconds"] as? Double ?? 0, json["text"] as? String ?? "")
    }

    static func runClaude(_ prompt: String) async -> String? {
        let output = await run(Paths.claude, ["-p", prompt, "--strict-mcp-config"])
        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ executable: URL, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            DispatchQueue.global().async {
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}

/// On-device translation of live captions, with the Mac's own Translation framework.
@MainActor
final class CaptionTranslator {
    static let shared = CaptionTranslator()
    /// Set when the language pair isn't downloaded on this Mac.
    private(set) var missingLanguages = false

    func translate(_ text: String, to target: String) async -> String? {
        guard target != "off" else { return nil }
        let source = text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } ? "ar" : "en"
        guard source != target else { return nil }
        guard #available(macOS 26.0, *) else { return nil }
        return await TranslationBridge.translate(text, from: source, to: target) { missing in
            self.missingLanguages = missing
        }
    }
}

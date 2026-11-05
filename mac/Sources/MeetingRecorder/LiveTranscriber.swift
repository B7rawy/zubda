import Foundation

/// Streams the recording to live.py, which transcribes it every few seconds with Whisper.
/// Lines come back as they are ready; when the recording stops the full transcript is written,
/// so the report can start without waiting for a second transcription pass.
final class LiveTranscriber: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let feed = DispatchQueue(label: "live-feed")
    private var broken = false
    private var buffer = Data()

    /// Called on the main queue with each new line: track, text, seconds from the start.
    var onLine: ((Line) -> Void)?
    /// "soniox" once the cloud engine is streaming, "local" if it fell back to Whisper.
    var onEngine: ((String) -> Void)?
    /// A line named a price, a date or a promise: kinds, seconds from the start, the line.
    var onAutoMark: (([String], Double, String) -> Void)?

    struct Line {
        let track: String
        let text: String
        let start: Double
        /// Which voice on a shared track (the room, or several people on the call), from Soniox.
        let speaker: String?
        /// Soniox's translation, when captions are translated and the cloud engine is on.
        let translation: String?
    }
    /// Called on the main queue when a Whisper pass starts (true) or ends (false).
    var onBusy: ((Bool) -> Void)?
    /// Word-by-word mode: the sentence being spoken, as confirmed words plus a tentative tail.
    var onDraft: ((String, String, String, String?) -> Void)?

    init(folder: URL, tracks: [String]) {
        process.executableURL = Paths.python
        process.arguments = [Paths.script("live.py").path, folder.path, tracks.joined(separator: ",")]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[..<newline]
                self.buffer.removeSubrange(...newline)
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let busy = json["busy"] as? Bool {
                    DispatchQueue.main.async { self.onBusy?(busy) }
                } else if let track = json["draft"] as? String {
                    let fixed = json["fixed"] as? String ?? "", tentative = json["tentative"] as? String ?? ""
                    let speaker = Self.speaker(json["speaker"])
                    DispatchQueue.main.async { self.onDraft?(track, fixed, tentative, speaker) }
                } else if let kinds = json["auto_mark"] as? [String] {
                    let at = json["t"] as? Double ?? 0, text = json["text"] as? String ?? ""
                    DispatchQueue.main.async { self.onAutoMark?(kinds, at, text) }
                } else if let engine = json["engine"] as? String {
                    DispatchQueue.main.async { self.onEngine?(engine) }
                } else if let track = json["track"] as? String, let text = json["text"] as? String {
                    let line = Line(track: track, text: text, start: json["start"] as? Double ?? 0,
                                    speaker: Self.speaker(json["speaker"]), translation: json["translation"] as? String)
                    DispatchQueue.main.async { self.onLine?(line) }
                }
            }
        }
        try process.run()
    }

    private static func speaker(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? Int { return String(number) }
        return nil
    }

    /// Sends 16 kHz mono samples for one track. Safe from any thread.
    func send(track: UInt8, samples: [Int16]) {
        guard !samples.isEmpty else { return }
        feed.async {
            guard !self.broken else { return }
            var header = Data([track])
            withUnsafeBytes(of: UInt32(samples.count).littleEndian) { header.append(contentsOf: $0) }
            let body = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            do {
                try self.input.fileHandleForWriting.write(contentsOf: header + body)
            } catch {
                self.broken = true  // the worker died; the queue will do a full transcription instead
            }
        }
    }

    /// Ends the stream and waits for the transcript. True when transcript.md was written.
    func finish(timeout: TimeInterval = 600) async -> Bool {
        feed.sync {}
        try? input.fileHandleForWriting.close()
        let exited = await withCheckedContinuation { continuation in
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().async {
                while self.process.isRunning && DispatchTime.now() < deadline { usleep(200_000) }
                if self.process.isRunning { self.process.terminate() }
                continuation.resume(returning: !self.broken && self.process.terminationStatus == 0)
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        return exited
    }

    func cancel() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
    }
}

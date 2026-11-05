import AppKit

/// Runs the same local Whisper script Claude uses, so the transcript is ready by the time
/// the user says "شوف آخر ميتنج".
enum Transcriber {
    private static let python = Paths.python
    private static let script = Paths.script("transcribe.py")

    private static let reportScript = Paths.script("report.py")

    /// Rebuilds the archive page (all meetings, grouped by client, searchable).
    static func buildArchive() async {
        _ = await launchScript(Paths.script("archive.py"), arguments: [])
    }

    @MainActor static func openArchive() {
        Navigator.shared.openSearch()
    }

    /// Re-renders a Markdown file as its HTML page.
    static func render(_ file: URL) async {
        _ = await launch(script: Paths.script("render.py"), folder: file)
    }

    /// Puts names on numbered voices in the transcript, report and stats.
    static func renameSpeakers(folder: URL, names: [String: String]) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: names),
              let json = String(data: data, encoding: .utf8) else { return false }
        return await launchScript(Paths.script("insights.py"), arguments: ["rename", folder.path, json])
    }

    /// Registers the connector with Claude Desktop and Claude Code.
    static func connectClaude() async -> Bool {
        await launchScript(Paths.script("connect_claude.py"), arguments: [])
    }

    static func run(folder: URL) async -> Bool {
        await launch(script: script, folder: folder)
    }

    /// Asks Claude Code to read the transcript and write report.md next to it.
    static func writeReport(folder: URL) async -> Bool {
        guard await launch(script: reportScript, folder: folder) else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("report.md").path)
    }

    /// The step running for the processing queue, so it can be cancelled.
    nonisolated(unsafe) private static var current: Process?

    static func cancelCurrent() {
        current?.terminate()
    }

    private static func launch(script: URL, folder: URL) async -> Bool {
        await launchScript(script, arguments: [folder.path])
    }

    private static func launchScript(_ script: URL, arguments: [String]) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else { return false }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = python
            process.arguments = [script.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                current = nil
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
                current = process
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}

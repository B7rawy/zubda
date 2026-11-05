import AppKit

/// "Share this moment": cuts 30 seconds of the meeting around a timestamp (clip.py) and
/// opens the share menu with the audio and the words said, for WhatsApp, Mail, AirDrop….
@MainActor
enum Clips {
    static func share(folder: URL, at seconds: Double, from view: NSView) async {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path),
              let result = await cut(folder: folder, at: seconds) else {
            NSSound.beep()
            return
        }
        let picker = NSSharingServicePicker(items: [result.file, result.text])
        let point = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        picker.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .maxY)
    }

    private static func cut(folder: URL, at seconds: Double) async -> (file: URL, text: String)? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = Paths.python
            process.arguments = [Paths.script("clip.py").path, folder.path, String(Int(seconds))]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard finished.terminationStatus == 0,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let path = json["path"] as? String else { return continuation.resume(returning: nil) }
                continuation.resume(returning: (URL(fileURLWithPath: path), json["text"] as? String ?? ""))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}

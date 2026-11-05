import Foundation

/// Do Not Disturb while recording, through the two shortcuts focus.py sets up
/// (macOS gives apps no direct switch for Focus).
enum Focus {
    static let on = "Zubda Focus On"
    static let off = "Zubda Focus Off"
    nonisolated(unsafe) private static var active = false

    @MainActor static func set(_ enabled: Bool) {
        guard enabled != active else { return }
        if enabled && !ConfigStore.shared.focusWhileRecording { return }
        active = enabled
        run(["run", enabled ? on : off])
    }

    /// Whether both shortcuts exist, for the Settings row.
    static func installed() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let names = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .components(separatedBy: "\n") ?? []
        process.waitUntilExit()
        return names.contains(on) && names.contains(off)
    }

    /// Builds both shortcuts and opens them; Shortcuts asks the user to add each one.
    static func setUp() {
        let process = Process()
        process.executableURL = Paths.python
        process.arguments = [Paths.script("focus.py").path, "setup"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func run(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

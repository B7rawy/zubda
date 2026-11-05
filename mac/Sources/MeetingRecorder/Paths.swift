import Foundation

/// Where things live on this Mac. build.sh writes the repo, Python and Claude paths into
/// Info.plist, so nothing here is tied to one person's machine.
enum Paths {
    private static let info = Bundle.main.infoDictionary ?? [:]
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The cloned repository with the Python scripts.
    static let repo = URL(fileURLWithPath: info["MRRepo"] as? String ?? home.appendingPathComponent("meeting-recorder").path)
    static let python = URL(fileURLWithPath: info["MRPython"] as? String
        ?? home.appendingPathComponent(".local/share/meeting-recorder/venv/bin/python").path)
    static let claude = URL(fileURLWithPath: info["MRClaude"] as? String ?? home.appendingPathComponent(".local/bin/claude").path)

    static func script(_ name: String) -> URL { repo.appendingPathComponent(name) }

    /// Shared with the Python side: ~/.config/meeting-recorder/config.json.
    static let meetings: URL = {
        let config = home.appendingPathComponent(".config/meeting-recorder/config.json")
        if let data = try? Data(contentsOf: config),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let folder = json["meetings_folder"] as? String {
            return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Downloads/Meetings", isDirectory: true)
    }()

    static var userName: String {
        let config = home.appendingPathComponent(".config/meeting-recorder/config.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "the user" }
        return json["user_name"] as? String ?? "the user"
    }

    static var reportLanguage: String {
        let config = home.appendingPathComponent(".config/meeting-recorder/config.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Arabic" }
        return json["report_language"] as? String ?? "Arabic"
    }
}

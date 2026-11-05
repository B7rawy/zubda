import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Every meeting's transcript in Spotlight, a couple of minutes per result, so ⌘Space
/// "Thawani" finds the meeting and the moment. Opening a result jumps there in the app.
enum Spotlight {
    private static let domain = "meetings"
    private static let chunk = 120.0

    static func reindex() {
        DispatchQueue.global(qos: .utility).async {
            let root = Recorder.meetingsFolder
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            var items: [CSSearchableItem] = []
            for folder in folders {
                items += Self.items(for: folder)
            }
            let index = CSSearchableIndex.default()
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                index.indexSearchableItems(items) { error in
                    NSLog("MRSpotlight: indexed %d items, error: %@", items.count, String(describing: error))
                }
            }
        }
    }

    private static func items(for folder: URL) -> [CSSearchableItem] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]] else { return [] }
        let meta = json["meeting"] as? [String: Any] ?? [:]
        let client = meta["project"] as? String ?? "General"
        var title = meta["title"] as? String ?? folder.lastPathComponent
        if title.hasPrefix("Meet - ") || title == "test" { title = meta["mode"] as? String == "room" ? "In-person meeting" : "Online meeting" }
        let day = String(folder.lastPathComponent.prefix(10))
        // Other spellings of the names and terms said, from keywords.json (written with the report).
        let spellings = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("keywords.json"))))
            as? [String: [String]] ?? [:]

        var groups: [Int: [String]] = [:]
        for segment in segments {
            guard let start = segment["start"] as? Double, let text = segment["text"] as? String else { continue }
            let who = segment["speaker"] as? String ?? ""
            groups[Int(start / chunk), default: []].append("\(who): \(text)")
        }
        return groups.keys.sorted().map { key in
            let at = Int(Double(key) * chunk)
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = "\(client == "General" ? title : client) · \(day) · \(clock(at))"
            let text = groups[key]!.joined(separator: "\n")
            attributes.contentDescription = String(text.prefix(300))
            attributes.textContent = text
            let extra = spellings.filter { text.localizedCaseInsensitiveContains($0.key) }.flatMap { [$0.key] + $0.value }
            attributes.keywords = [client, title, "meeting", "ميتنج"] + extra
            if !extra.isEmpty { attributes.textContent = text + "\n" + extra.joined(separator: " ") }
            return CSSearchableItem(uniqueIdentifier: "\(folder.lastPathComponent)#\(at)",
                                    domainIdentifier: domain, attributeSet: attributes)
        }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }

    /// "folder#seconds" from a Spotlight result, opened in the main window at that moment.
    @MainActor static func open(_ identifier: String) {
        let parts = identifier.split(separator: "#", maxSplits: 1)
        guard let name = parts.first else { return }
        let folder = Recorder.meetingsFolder.appendingPathComponent(String(name))
        // Closed first, so a meeting already open reopens at the new moment.
        Navigator.shared.meeting = nil
        DispatchQueue.main.async {
            Navigator.shared.jump = parts.count > 1 ? Double(parts[1]) : nil
            Navigator.shared.open(meeting: folder)
        }
    }
}

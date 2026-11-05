import Foundation

/// What was left open the last time with a client, read from that meeting's report.md.
struct Brief: Equatable {
    let when: String
    let items: [String]

    static func latest(for project: String) -> Brief? {
        guard project != "General" else { return nil }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Recorder.meetingsFolder, includingPropertiesForKeys: nil
        )) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  meta["project"] as? String == project,
                  let report = try? String(contentsOf: folder.appendingPathComponent("report.md"), encoding: .utf8)
            else { continue }
            let items = Array(bullets(in: report, under: "النقط المفتوحة").prefix(2))
                + Array(bullets(in: report, under: "المهام").prefix(2))
            guard !items.isEmpty else { continue }
            return Brief(when: relativeDate(meta["startedAt"] as? String), items: items)
        }
        return nil
    }

    /// The first bullet lines under the first heading that contains `title`.
    private static func bullets(in markdown: String, under title: String) -> [String] {
        var inside = false
        var found: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if inside { break }
                inside = line.contains(title)
                continue
            }
            guard inside else { continue }
            let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ")
                || (line.first?.isNumber == true && line.contains(". "))
            guard isBullet else { continue }
            var text = line.drop { $0 == "-" || $0 == "*" || $0.isNumber || $0 == "." || $0 == " " }
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            if text.count > 90 { text = String(text.prefix(88)) + "…" }
            if !text.isEmpty { found.append(text) }
        }
        return found
    }

    private static func relativeDate(_ iso: String?) -> String {
        // The Chrome extension writes fractional seconds; the Mac app doesn't.
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) ?? precise.date(from: iso) else { return "last time" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

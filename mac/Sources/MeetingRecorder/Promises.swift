import Foundation
import UserNotifications

/// Commitments Claude found in a meeting (promises.json, written with the report), turned
/// into reminders: an hour before a timed deadline, or 9:00 on the day for a date.
enum Promises {
    struct Promise: Decodable {
        let who: String?
        let what: String
        let due: String?
    }

    static func load(_ folder: URL) -> [Promise] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("promises.json")) else { return [] }
        return (try? JSONDecoder().decode([Promise].self, from: data)) ?? []
    }

    static func schedule(folder: URL, title: String) {
        let center = UNUserNotificationCenter.current()
        for (index, promise) in load(folder).enumerated() {
            guard let due = promise.due, let when = remindAt(due), when > Date().addingTimeInterval(60) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Due \(due.count > 10 ? "soon" : "today"): \(promise.what)"
            content.body = [promise.who, "from \(title)"].compactMap { $0 }.joined(separator: " · ")
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
            let id = "promise-\(folder.lastPathComponent)-\(index)"
            center.add(UNNotificationRequest(identifier: id, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
    }

    private static func remindAt(_ due: String) -> Date? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let time = format.date(from: String(due.prefix(16))) {
            let early = time.addingTimeInterval(-3600)
            return early > Date() ? early : time
        }
        format.dateFormat = "yyyy-MM-dd"
        guard let day = format.date(from: String(due.prefix(10))) else { return nil }
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)
    }

    /// Numbered voice labels in a meeting's transcript («متحدث 1», «ضيف 2»…), in order of appearance.
    static func voices(_ folder: URL) -> [String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]] else { return [] }
        var seen: [String] = []
        for segment in segments {
            guard let speaker = segment["speaker"] as? String, !seen.contains(speaker),
                  speaker.range(of: #"^(متحدث|ضيف|الطرف التاني|متكلم) \d+$"#, options: .regularExpression) != nil else { continue }
            seen.append(speaker)
        }
        return seen
    }
}

import EventKit

/// Reads the Mac's Calendar (which includes Google calendars added under Internet Accounts)
/// to know which meeting is about to start, who is in it, and which client it belongs to.
@MainActor
final class CalendarWatcher: ObservableObject {
    struct Meeting: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let attendees: [String]
        let notes: String
        /// The call link from the event (Meet, Zoom, Teams…), for the Join button.
        var link: URL? = nil
    }

    private static let callLink = try! NSRegularExpression(
        pattern: #"https?://(meet\.google\.com|[\w.-]*zoom\.us|teams\.microsoft\.com|teams\.live\.com|whereby\.com|meet\.jit\.si)/[^\s<>"')]+"#)

    private static func link(in event: EKEvent) -> URL? {
        for text in [event.url?.absoluteString, event.location, event.notes].compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = callLink.firstMatch(in: text, range: range), let r = Range(match.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    /// In progress, or starting within two minutes.
    @Published private(set) var current: Meeting?
    /// The next meeting that starts within the hour, for the countdown in the closed notch.
    @Published private(set) var next: Meeting?

    private let store = EKEventStore()
    private var timer: Timer?

    func start() {
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            access = granted ? .granted : .denied
            guard granted else { return }
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
                MainActor.assumeIsolated { self.refresh() }
            }
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { self.refresh() }
            }
        }
    }

    func refresh() {
        guard access == .granted else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.startDate <= now.addingTimeInterval(120) }
            .sorted { $0.startDate > $1.startDate }
        current = events.first.map(Self.meeting)
        next = store.events(matching: store.predicateForEvents(withStart: now, end: now.addingTimeInterval(3600), calendars: nil))
            .filter { !$0.isAllDay && $0.startDate > now.addingTimeInterval(120) }
            .min { $0.startDate < $1.startDate }
            .map(Self.meeting)
    }

    /// Today's remaining meetings, for the morning brief.
    func today() -> [Meeting] {
        guard access == .granted else { return [] }
        let now = Date()
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        return store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map(Self.meeting)
    }

    private static func meeting(_ event: EKEvent) -> Meeting {
        Meeting(
            id: "\(event.calendarItemIdentifier)@\(Int(event.startDate.timeIntervalSince1970))",
            title: event.title?.isEmpty == false ? event.title! : "Meeting",
            start: event.startDate,
            end: event.endDate,
            attendees: (event.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") },
            notes: event.notes ?? "",
            link: link(in: event)
        )
    }
}

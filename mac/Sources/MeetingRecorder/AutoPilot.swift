import AppKit
import CoreAudio
import UserNotifications

/// Notices when a call starts or ends, and asks from the notch instead of making the user
/// remember. It never starts a recording on its own; it only stops one after asking first.
@MainActor
final class AutoPilot: ObservableObject {
    enum Prompt: Equatable {
        /// Another app started using the mic.
        case start(app: String)
        /// A calendar meeting is starting (or its call app just opened the mic).
        case meeting(CalendarWatcher.Meeting)
        /// The call looks over; recording stops when the countdown runs out.
        case end(reason: String, deadline: Date)
        /// Once a day: today's meetings and what's still open with those clients.
        case morning(lines: [String])
    }

    @Published private(set) var prompt: Prompt?

    private let recorder: Recorder
    private let calendar: CalendarWatcher
    private var timer: Timer?
    private var promptedEvents: Set<String> = []
    private var micUsers: Set<String> = []
    private var dismissedUsers: Set<String> = []
    private var startPromptShownAt: Date?
    private var callSeenWhileRecording = false
    private var callGoneSince: Date?
    private var quietSince: Date?
    private var snoozedUntil: Date?

    private static let startPromptLifetime: TimeInterval = 20
    private static let callGoneGrace: TimeInterval = 5
    private static let silenceLimit: TimeInterval = 180
    private static let endCountdown: TimeInterval = 30
    private var callApp: String?
    private var micDeadSince: Date?
    private var warnedDeadMic = false
    /// Below this the mic is delivering digital silence, not a quiet room.
    private static let deadMicLevel: Float = 0.001
    private static let deadMicAfter: TimeInterval = 20

    init(recorder: Recorder, calendar: CalendarWatcher) {
        self.recorder = recorder
        self.calendar = calendar
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Calendar meetings already told they are nearly over.
    private var nudged: Set<String> = []

    /// Five minutes before the calendar meeting ends, a quiet line in the notch.
    private func watchTimeLeft(now: Date) {
        guard let event = calendar.current, !nudged.contains(event.id) else { return }
        let left = event.end.timeIntervalSince(now)
        guard left > 0, left <= 5 * 60, event.end.timeIntervalSince(event.start) >= 15 * 60 else { return }
        nudged.insert(event.id)
        recorder.nudge("\(Int((left / 60).rounded(.up))) minutes left in “\(event.title)”. Time to agree on next steps.")
    }

    func acceptStart() {
        if case .meeting(let event) = prompt { recorder.pendingEvent = event }
        prompt = nil
        Task { await recorder.start(.online) }
    }

    func dismissMorning() {
        if case .morning = prompt { prompt = nil }
    }

    /// Shown the first time the Mac is in use after 5 am, if there's anything to say.
    private func watchMorning(now: Date) {
        let day = Calendar.current.startOfDay(for: now)
        guard Calendar.current.component(.hour, from: now) >= 5,
              UserDefaults.standard.object(forKey: "briefDay") as? Date != day else { return }
        UserDefaults.standard.set(day, forKey: "briefDay")
        var lines: [String] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        var clients: [String] = []
        for meeting in calendar.today().prefix(4) {
            let client = recorder.matchProject(for: meeting)
            lines.append("\(formatter.string(from: meeting.start)) · \(meeting.title)")
            if let client, !clients.contains(client) { clients.append(client) }
        }
        for client in clients.prefix(2) {
            for item in (Brief.latest(for: client)?.items ?? []).prefix(2) { lines.append("\(client): \(item)") }
        }
        guard !lines.isEmpty else { return }
        prompt = .morning(lines: lines)
        Task {
            try? await Task.sleep(for: .seconds(25))
            dismissMorning()
        }
    }

    /// Bundle id of the app in the current "is using your mic" prompt.
    private var promptedBundle: String?

    /// Never ask again for this app (dictation tools like Wispr Flow use the mic all day).
    func ignorePromptedApp() {
        if let bundle = promptedBundle {
            var ignored = UserDefaults.standard.stringArray(forKey: "ignoredMicApps") ?? []
            ignored.append(bundle)
            UserDefaults.standard.set(ignored, forKey: "ignoredMicApps")
        }
        dismissStart()
    }

    func dismissStart() {
        dismissedUsers.formUnion(micUsers)
        prompt = nil
    }

    func keepRecording() {
        Notifier.clear()
        prompt = nil
        snoozedUntil = Date().addingTimeInterval(Self.silenceLimit)
        quietSince = nil
        callGoneSince = nil
        callSeenWhileRecording = false
    }

    func stopNow() {
        Notifier.clear()
        prompt = nil
        Task { await recorder.stop() }
    }

    /// Fake prompts for screenshots (MR_PREVIEW); stops the watcher.
    func showPreview(_ prompt: Prompt) {
        timer?.invalidate()
        if case .meeting(let event) = prompt { recorder.chooseProject(for: event) }
        self.prompt = prompt
    }

    private func tick() {
        let now = Date()
        let users = MicUsers.current()
        defer { micUsers = Set(users.keys) }

        switch recorder.phase {
        case .recording:
            if case .start = prompt { prompt = nil }
            watchMic(now: now)
            watchLimit(now: now)
            watchForEnd(users: users, now: now)
            watchTimeLeft(now: now)
        case .idle, .failed:
            resetRecordingWatch()
            watchForStart(users: users, now: now)
            if prompt == nil { watchMorning(now: now) }
        default:
            resetRecordingWatch()
        }
    }

    private func watchForStart(users: [String: String], now: Date) {
        // Forget dismissals once that app lets go of the mic, so the next call asks again.
        dismissedUsers.formIntersection(users.keys)

        switch prompt {
        case .morning:
            if !users.isEmpty || calendar.current != nil { prompt = nil } else { return }
        case .start:
            if users.isEmpty || now.timeIntervalSince(startPromptShownAt ?? now) > Self.startPromptLifetime {
                prompt = nil
            }
            return
        case .meeting:
            // Calendar prompts stay a little longer: the call may not have opened yet.
            if now.timeIntervalSince(startPromptShownAt ?? now) > Self.startPromptLifetime * 4 { prompt = nil }
            return
        default:
            break
        }

        let event = calendar.current
        let ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredMicApps") ?? [])
        let newcomers = Set(users.keys).subtracting(micUsers).subtracting(dismissedUsers).subtracting(ignored)

        if let event, !promptedEvents.contains(event.id),
           event.start.timeIntervalSince(now) <= ConfigStore.shared.notifyLeadSeconds,
           now.timeIntervalSince(event.start) < 600 || !newcomers.isEmpty {
            promptedEvents.insert(event.id)
            recorder.chooseProject(for: event)
            prompt = .meeting(event)
            startPromptShownAt = now
            NSSound(named: "Tink")?.play()
        } else if ConfigStore.shared.detectCalls, let id = newcomers.first, let name = users[id] {
            promptedBundle = id
            prompt = .start(app: name)
            startPromptShownAt = now
        }
    }

    private func watchMic(now: Date) {
        guard !recorder.paused else {
            micDeadSince = nil
            recorder.micSilent = false
            return
        }
        if recorder.levelMe < Self.deadMicLevel {
            micDeadSince = micDeadSince ?? now
            if now.timeIntervalSince(micDeadSince!) >= Self.deadMicAfter, !recorder.micSilent {
                recorder.micSilent = true
                if !warnedDeadMic {
                    warnedDeadMic = true
                    NSSound(named: "Basso")?.play()
                    Notifier.micSilent()
                }
            }
        } else {
            micDeadSince = nil
            recorder.micSilent = false
        }
    }

    private var warnedLimit = false

    /// Stops at the longest-recording limit from Settings, with a heads-up two minutes before.
    private func watchLimit(now: Date) {
        let limit = ConfigStore.shared.maxMinutes * 60
        guard limit > 0, let started = recorder.startedAt else { return }
        let elapsed = now.timeIntervalSince(started)
        if elapsed >= limit {
            stopNow()
        } else if elapsed >= limit - 120, !warnedLimit {
            warnedLimit = true
            Notifier.limitSoon(minutes: Int(ConfigStore.shared.maxMinutes))
        }
    }

    private func watchForEnd(users: [String: String], now: Date) {
        if case .end(_, let deadline) = prompt {
            if now >= deadline { stopNow() }
            return
        }
        if let snoozedUntil, now < snoozedUntil { return }

        if recorder.mode == .online {
            if !users.isEmpty {
                callSeenWhileRecording = true
                callApp = users.values.first
                callGoneSince = nil
            } else if callSeenWhileRecording {
                callGoneSince = callGoneSince ?? now
                if now.timeIntervalSince(callGoneSince!) >= Self.callGoneGrace {
                    switch ConfigStore.shared.callEnd {
                    case "stop": stopNow()
                    case "ignore": callSeenWhileRecording = false
                    default: askToEnd("\(callApp ?? "The call app") closed the call.", now: now)
                    }
                    return
                }
            }
        }

        let quiet = max(recorder.levelMe, recorder.levelOthers) < 0.02 && !recorder.paused
        if quiet {
            quietSince = quietSince ?? now
            if now.timeIntervalSince(quietSince!) >= Self.silenceLimit {
                askToEnd("Nobody has spoken for 3 minutes.", now: now)
            }
        } else {
            quietSince = nil
        }
    }

    private func askToEnd(_ reason: String, now: Date) {
        prompt = .end(reason: reason, deadline: now.addingTimeInterval(Self.endCountdown))
        NSSound(named: "Glass")?.play()
        Notifier.meetingOver(reason: reason, seconds: Int(Self.endCountdown))
    }

    private func resetRecordingWatch() {
        if case .end = prompt { prompt = nil }
        callSeenWhileRecording = false
        callGoneSince = nil
        quietSince = nil
        snoozedUntil = nil
        micDeadSince = nil
        warnedDeadMic = false
        warnedLimit = false
    }
}

/// Which other apps are using a microphone right now, from Core Audio's process list.
enum MicUsers {
    /// Apple's own background listeners (Siri, dictation) aren't calls.
    private static let appleCallApps = ["com.apple.FaceTime", "com.apple.Safari", "com.apple.WebKit"]

    /// Bundle id → display name.
    static func current() -> [String: String] {
        var result: [String: String] = [:]
        let own = ProcessInfo.processInfo.processIdentifier
        for process in processObjects() {
            guard read(process, kAudioProcessPropertyIsRunningInput, as: UInt32.self) == 1,
                  let pid = read(process, kAudioProcessPropertyPID, as: pid_t.self), pid != own,
                  let bundle = bundleID(of: process) else { continue }
            if bundle.hasPrefix("com.apple."), !appleCallApps.contains(where: bundle.hasPrefix) { continue }
            result[bundle] = displayName(pid: pid, bundle: bundle)
        }
        return result
    }

    private static func displayName(pid: pid_t, bundle: String) -> String {
        // Browsers capture audio in helper processes (com.google.Chrome.helper), which have no
        // useful name of their own, so name the app that owns them.
        let main = bundle.components(separatedBy: ".helper").first ?? bundle
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: main).first,
           let name = app.localizedName {
            return name
        }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name.components(separatedBy: " Helper").first ?? name
        }
        return main.components(separatedBy: ".").last ?? main
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }
}

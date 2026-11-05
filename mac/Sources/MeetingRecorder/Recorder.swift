import AVFoundation
import AppKit
import ScreenCaptureKit

enum RecordingMode: String {
    /// A call on the Mac: what the Mac plays goes to "others", the mic to "me".
    case online
    /// People around the laptop: the mic is the only source, stored as "room".
    case room
}

enum Phase: Equatable {
    case idle
    case starting
    case recording
    case saving
    case failed(String)
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { phaseSince = Date() } }
    }
    /// When the current phase began, so long steps can show they are still moving.
    @Published private(set) var phaseSince = Date()
    @Published private(set) var mode: RecordingMode = .online
    @Published private(set) var startedAt: Date?
    @Published private(set) var paused = false
    @Published private(set) var levelMe: Float = 0
    @Published private(set) var levelOthers: Float = 0
    @Published private(set) var needsScreenPermission = false
    @Published private(set) var lastFolder: URL?
    @Published private(set) var transcriptReady = false
    /// The last problem, shown in the open notch until the next recording starts.
    @Published private(set) var notice: String?
    @Published private(set) var reportReady = false
    /// Bumped on every mark so the closed notch can flash a star.
    @Published private(set) var markCount = 0
    @Published var project: String = UserDefaults.standard.string(forKey: "project") ?? "General" {
        didSet {
            UserDefaults.standard.set(project, forKey: "project")
            refreshBrief()
            // Picking the client mid-meeting still files this recording under them.
            if phase == .recording {
                meta["project"] = project
                writeMeta()
            }
        }
    }
    @Published private(set) var projects: [String] = UserDefaults.standard.stringArray(forKey: "projects")
        ?? ["General"]

    /// Other names a client goes by in calendar titles, notes and attendee lists.
    @Published private(set) var aliases: [String: [String]] =
        UserDefaults.standard.dictionary(forKey: "aliases") as? [String: [String]] ?? [:]
    /// True while the mic delivers no sound at all, which means it is dead or muted in macOS.
    @Published var micSilent = false


    /// What was left open the last time with the selected client.
    @Published private(set) var brief: Brief?
    /// The calendar event the next recording belongs to, if any.
    var pendingEvent: CalendarWatcher.Meeting?

    /// Receives each saved recording for transcription and the report.
    var onSaved: ((URL, String) -> Void)?
    /// Someone said your name: the line, for the notch to open and get your attention.
    var onMention: ((String) -> Void)?
    private var lastMention = Date.distantPast

    /// Whether a line from someone else says one of your alert words.
    private func mentions(_ text: String, track: String) -> Bool {
        let config = ConfigStore.shared
        guard config.mentionAlert, track != "me", track != "mark" else { return false }
        let folded = ConfigStore.fold(text)
        return config.mentionWords.contains { folded.contains($0) }
    }

    /// Alerts once per 20 seconds, from a draft (sooner) or a finished line.
    private func checkMention(_ text: String, track: String) {
        guard mentions(text, track: track), Date().timeIntervalSince(lastMention) > 20 else { return }
        lastMention = Date()
        onMention?(text)
    }

    struct LiveEntry: Identifiable, Equatable {
        let id = UUID()
        let track: String
        let text: String
        let at: Double
        /// When it was shown; only fresh lines get the word-by-word typing effect.
        let shownAt = Date()
        /// The line in the language chosen under Settings → Extras, when translation is on.
        var translation: String?
        /// Whether it gets the word-by-word typing effect when it appears.
        var typed = true
        /// Which voice on a shared track, when the cloud engine tells them apart.
        var speaker: String? = nil
        /// Someone said your name (or an alert word) in this line.
        var mentioned = false
    }

    /// Lines from Whisper arrive in batches; they are released one at a time so the feed
    /// reads like someone typing instead of jumping ahead by a paragraph.
    private var pendingLines: [LiveEntry] = []
    private var dripping = false

    static let secondsPerWord = 0.07

    private func translate(_ line: LiveEntry) {
        let target = ConfigStore.shared.translateTo
        guard target != "off", line.track != "mark", !cloudLive else { return }
        Task {
            guard let text = await CaptionTranslator.shared.translate(line.text, to: target),
                  let index = liveEntries.firstIndex(where: { $0.id == line.id }) else { return }
            liveEntries[index].translation = text
        }
    }

    private func showLine(_ original: LiveEntry) {
        var entry = original
        if mentions(entry.text, track: entry.track) {
            entry.mentioned = true
            checkMention(entry.text, track: entry.track)
        }
        if ConfigStore.shared.wordByWord {
            // The words already appeared one by one in the draft; the line just settles in.
            var line = LiveEntry(track: entry.track, text: entry.text, at: entry.at)
            line.typed = false
            line.speaker = entry.speaker
            line.translation = entry.translation
            line.mentioned = entry.mentioned
            liveEntries.append(line)
            if liveEntries.count > 40 { liveEntries.removeFirst(liveEntries.count - 40) }
            translate(line)
            return
        }
        pendingLines.append(entry)
        guard !dripping else { return }
        dripping = true
        Task {
            while !pendingLines.isEmpty {
                let next = pendingLines.removeFirst()
                var line = LiveEntry(track: next.track, text: next.text, at: next.at)
                line.mentioned = next.mentioned
                liveEntries.append(line)
                translate(line)
                if liveEntries.count > 40 { liveEntries.removeFirst(liveEntries.count - 40) }
                let words = Double(next.text.split(separator: " ").count)
                // Catch up faster when a backlog builds, so the feed never falls further behind.
                let pace = pendingLines.count > 3 ? 0.4 : 1.0
                try? await Task.sleep(for: .seconds((words * Self.secondsPerWord + 0.35) * pace))
            }
            dripping = false
        }
    }

    /// The latest lines from live transcription, oldest first, shown as a running conversation.
    @Published private(set) var liveEntries: [LiveEntry] = []
    /// True while Whisper is writing down the last few seconds.
    @Published private(set) var liveBusy = false

    struct Draft: Equatable {
        let track: String
        let fixed: String
        let tentative: String
        var speaker: String? = nil
    }

    /// True while Soniox is doing the live transcript; it translates too, so Apple's
    /// translator is not asked again.
    private var cloudLive = false

    /// Word-by-word mode: what is being said right now, before it becomes a line.
    @Published private(set) var liveDraft: Draft?

    private var live: LiveTranscriber?
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var sinks: [String: AudioSink] = [:]
    /// The folder of the recording in progress (or the last one).
    private(set) var folder: URL?
    private var meta: [String: Any] = [:]
    private var sleepGuard: NSObjectProtocol?

    nonisolated static let meetingsFolder = Paths.meetings

    var isBusy: Bool {
        [.starting, .recording, .saving].contains(phase)
    }

    func start(_ mode: RecordingMode, retry: Bool = true) async {
        guard !isBusy else { return }
        phase = .starting
        needsScreenPermission = false
        transcriptReady = false
        reportReady = false
        notice = nil

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            fail("Allow microphone access in Privacy settings.")
            openPrivacy("Privacy_Microphone")
            return
        }
        if mode == .online && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            needsScreenPermission = true
            fail("Allow Screen & System Audio Recording, then reopen the app.")
            return
        }

        do {
            let now = Date()
            let folder = try makeFolder(at: now, mode: mode)
            self.folder = folder
            self.mode = mode

            let micTrack = mode == .online ? "me" : "room"
            let micSink = try AudioSink(url: folder.appendingPathComponent("\(micTrack).caf"))
            micSink.onLevel = { [weak self] level in
                Task { @MainActor in self?.levelMe = smooth(self?.levelMe ?? 0, level) }
            }
            sinks = [micTrack: micSink]
            liveEntries = []
            pendingLines = []
            liveBusy = false
            liveDraft = nil

            // Live transcription is a bonus: if it can't start, the queue transcribes afterwards.
            let live = LiveTranscriber(folder: folder, tracks: mode == .online ? [micTrack, "others"] : [micTrack])
            let wantsLive = ConfigStore.shared.liveTranscript
            cloudLive = false
            live.onLine = { [weak self] line in
                MainActor.assumeIsolated {
                    var entry = LiveEntry(track: line.track, text: line.text, at: line.start)
                    entry.speaker = line.speaker
                    entry.translation = line.translation
                    self?.showLine(entry)
                }
            }
            live.onAutoMark = { [weak self] kinds, at, text in
                MainActor.assumeIsolated { self?.autoMark(kinds: kinds, at: at, text: text) }
            }
            live.onEngine = { [weak self] engine in
                MainActor.assumeIsolated { self?.cloudLive = engine == "soniox" }
            }
            live.onBusy = { [weak self] busy in
                MainActor.assumeIsolated { self?.liveBusy = busy }
            }
            live.onDraft = { [weak self] track, fixed, tentative, speaker in
                MainActor.assumeIsolated {
                    self?.liveDraft = fixed.isEmpty && tentative.isEmpty ? nil
                        : Draft(track: track, fixed: fixed, tentative: tentative, speaker: speaker)
                    if !fixed.isEmpty { self?.checkMention(fixed, track: track) }
                }
            }
            if wantsLive, (try? live.start()) != nil {
                self.live = live
                micSink.onSamples16k = { live.send(track: 0, samples: $0) }
            }

            if mode == .online {
                let othersSink = try AudioSink(url: folder.appendingPathComponent("others.caf"))
                othersSink.onLevel = { [weak self] level in
                    Task { @MainActor in self?.levelOthers = smooth(self?.levelOthers ?? 0, level) }
                }
                if let live = self.live {
                    othersSink.onSamples16k = { live.send(track: 1, samples: $0) }
                }
                sinks["others"] = othersSink
                let system = SystemAudioCapture(sink: othersSink)
                system.onUnexpectedStop = { [weak self] _ in
                    Task { @MainActor in await self?.stop() }
                }
                try await system.start()
                self.system = system
            }

            let mic = MicCapture()
            try mic.start(into: micSink, deviceUID: ConfigStore.shared.micUID)
            self.mic = mic

            meta = [
                "app": "meeting-recorder-mac",
                "mode": mode.rawValue,
                "project": project,
                "marks": [[String: Any]](),
                "title": pendingEvent?.title ?? (mode == .online ? "Online meeting" : "In-person meeting"),
                "attendees": pendingEvent?.attendees ?? [],
                "meetingCode": mode == .online ? "online" : "in-person",
                "tracks": mode == .online ? ["others", "me"] : ["room"],
                "startedAt": ISO8601DateFormatter().string(from: now),
                "status": "recording",
            ]
            writeMeta()
            if let event = pendingEvent { rememberProject(for: event.title) }
            pendingEvent = nil
            sleepGuard = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a meeting"
            )
            paused = false
            micSilent = false
            startedAt = now
            phase = .recording
            Focus.set(true)
            if ConfigStore.shared.openWindowOnStart { AppDelegate.showMain() }
        } catch {
            await teardown()
            if let folder { try? FileManager.default.removeItem(at: folder) }
            if mode == .online && !CGPreflightScreenCaptureAccess() { needsScreenPermission = true }
            Self.log("start \(mode) failed: \(error) — \(error.localizedDescription)")
            if retry {
                // Usually a call app grabbing the mic at the same moment (e.g. New Meet opening
                // Meet); the audio devices settle within a second or two.
                phase = .idle
                try? await Task.sleep(for: .seconds(2))
                await start(mode, retry: false)
                return
            }
            fail(error.localizedDescription)
        }
    }

    /// Online: mutes only the user's mic. In person: pauses the whole recording.
    func togglePause() {
        guard phase == .recording else { return }
        paused.toggle()
        sinks["me"]?.muted = paused
        sinks["room"]?.muted = paused
    }

    /// Saves the recording and hands it to the processing queue. Quitting passes
    /// `transcribe: false` so the app can close at once; it is picked up on the next launch.
    func stop(transcribe: Bool = true) async {
        guard phase == .recording else { return }
        phase = .saving
        await teardown()
        meta["endedAt"] = ISO8601DateFormatter().string(from: Date())
        meta["status"] = "done"
        writeMeta()
        if let live {
            // Only the last few seconds are left to transcribe, so this is quick.
            if transcribe { _ = await live.finish() } else { live.cancel() }
            self.live = nil
        }
        liveEntries = []
        liveBusy = false
        liveDraft = nil
        lastFolder = folder
        startedAt = nil
        levelMe = 0
        levelOthers = 0

        phase = .idle
        if transcribe, let folder { onSaved?(folder, ProcessingQueue.title(for: meta)) }
    }

    /// Marks this moment, with an optional note. It shows up in the transcript and the report.
    func mark(note: String? = nil) {
        guard phase == .recording, let startedAt else { return }
        var entry: [String: Any] = ["t": Int(Date().timeIntervalSince(startedAt))]
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { entry["note"] = note }
        var marks = meta["marks"] as? [[String: Any]] ?? []
        marks.append(entry)
        meta["marks"] = marks
        writeMeta()
        markCount += 1
        // Shown straight away in the live conversation, not after the next Whisper pass.
        liveEntries.append(LiveEntry(track: "mark", text: entry["note"] as? String ?? "Marked this moment",
                                     at: Double(entry["t"] as? Int ?? 0)))
    }

    /// A mark the live transcript placed by itself, on a line with a price, a date or a promise.
    private func autoMark(kinds: [String], at: Double, text: String) {
        guard phase == .recording else { return }
        let names = ["سعر": "Price", "موعد": "Date", "وعد": "Promise"]
        let label = kinds.compactMap { names[$0] }.joined(separator: " · ")
        var marks = meta["marks"] as? [[String: Any]] ?? []
        marks.append(["t": Int(at), "note": "تلقائي (\(kinds.joined(separator: "، "))): \(text.prefix(120))", "auto": true])
        meta["marks"] = marks
        writeMeta()
        markCount += 1
        liveEntries.append(LiveEntry(track: "mark", text: "\(label): \(text.prefix(70))", at: at))
    }

    /// A quiet line in the live feed (and the captions), e.g. time running out on the calendar.
    func nudge(_ text: String) {
        guard phase == .recording, let startedAt else { return }
        liveEntries.append(LiveEntry(track: "notice", text: text, at: Date().timeIntervalSince(startedAt)))
        NSSound(named: "Tink")?.play()
    }

    /// Throws the current recording away: stops it, skips transcription and moves its folder
    /// to the Trash, so a test or a mistake can still be recovered from there.
    func discard() async {
        guard phase == .recording else { return }
        live?.cancel()
        live = nil
        phase = .saving
        await teardown()
        if let folder { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
        folder = nil
        startedAt = nil
        levelMe = 0
        levelOthers = 0
        liveEntries = []
        pendingLines = []
        liveBusy = false
        phase = .idle
    }

    func refreshBrief() {
        brief = Brief.latest(for: project)
    }

    /// Picks the client for a calendar event: the one used last time for an event with the
    /// same title, else a project whose name appears in the title, notes or attendees.
    func chooseProject(for event: CalendarWatcher.Meeting) {
        if let match = matchProject(for: event) { project = match }
    }

    func matchProject(for event: CalendarWatcher.Meeting) -> String? {
        let remembered = UserDefaults.standard.dictionary(forKey: "eventProjects") as? [String: String]
        if let known = remembered?[event.title], projects.contains(known) { return known }
        let haystack = Self.normalized(([event.title, event.notes] + event.attendees).joined(separator: " "))
        let match = projects.first { name in
            name != "General" && ([name] + (aliases[name] ?? [])).contains { term in
                let term = Self.normalized(term)
                return !term.isEmpty && haystack.contains(term)
            }
        }
        return match
    }

    func setAliases(_ names: [String], for project: String) {
        aliases[project] = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        UserDefaults.standard.set(aliases, forKey: "aliases")
    }

    /// Lowercase, and Arabic letters folded so «إدراك» matches «ادراك» and «فيثاغوره» matches «فيثاغورة».
    static func normalized(_ text: String) -> String {
        var text = text.lowercased()
        for (from, to) in [("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ة", "ه"), ("ى", "ي"), ("ـ", "")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text.unicodeScalars.filter { !(0x064B...0x0652).contains($0.value) }.map(String.init).joined()
    }

    private func rememberProject(for eventTitle: String) {
        var remembered = UserDefaults.standard.dictionary(forKey: "eventProjects") as? [String: String] ?? [:]
        remembered[eventTitle] = project
        UserDefaults.standard.set(remembered, forKey: "eventProjects")
    }

    /// Brings in an audio or video file recorded elsewhere: it becomes a meeting and goes
    /// through the same transcription and report.
    func importRecording(_ file: URL) {
        let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        guard let folder = try? makeFolder(at: date, mode: .room) else { return }
        let ext = file.pathExtension.lowercased()
        try? FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("room.\(ext)"))
        let meta: [String: Any] = [
            "app": "meeting-recorder-mac", "mode": "room", "project": project,
            "title": file.deletingPathExtension().lastPathComponent, "tracks": ["room"], "marks": [[String: Any]](),
            "startedAt": ISO8601DateFormatter().string(from: date), "status": "done", "imported": true,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("session.json"))
        }
        onSaved?(folder, ProcessingQueue.title(for: meta))
    }

    func addProject(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !projects.contains(name) {
            projects.insert(name, at: 0)
            UserDefaults.standard.set(projects, forKey: "projects")
        }
        project = name
    }

    func openReport() {
        guard let lastFolder else { return openLastFolder() }
        Navigator.shared.open(meeting: lastFolder)
    }

    /// ~/Library/Logs/MeetingRecorder.log, so a "Problem" in the notch can be traced afterwards.
    static func log(_ line: String) {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MeetingRecorder.log")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func fail(_ message: String) {
        Self.log("problem: \(message)")
        notice = message
        phase = .failed(message)
        settle()
    }

    /// The closed notch shows a result for a few seconds, then goes quiet again.
    private func settle() {
        Task {
            try? await Task.sleep(for: .seconds(8))
            if case .failed = phase { phase = .idle }
        }
    }

    func openLastFolder() {
        NSWorkspace.shared.open(lastFolder ?? Self.meetingsFolder)
    }

    func openScreenPermission() {
        openPrivacy("Privacy_ScreenCapture")
    }

    /// Fake recording state for screenshots (MR_PREVIEW); records nothing.
    func showRoomPreview() {
        mode = .room
        startedAt = Date().addingTimeInterval(-74)
        levelOthers = 0.6
        phase = .recording
        cloudLive = true
        let lines: [(String, String, String, Double)] = [
            ("1", "تنبيهات وإشعارات وحاجات من دي.", "Alerts and notifications and things like that.", 48),
            ("2", "تتحكم فيها الإدارة، تفرضها على المعلم، صح؟", "Management controls it, imposes it on the teacher, right?", 55),
            ("1", "بالظبط، آه. الجدول ده بتبقى حاجة الإدارة بتحطها للمعلمين.", "Exactly, yeah. This schedule is something management puts on teachers.", 61),
        ]
        for (speaker, text, translation, at) in lines {
            var entry = LiveEntry(track: "room", text: text, at: at)
            entry.speaker = speaker
            entry.translation = translation
            showLine(entry)
        }
        liveDraft = Draft(track: "room", fixed: "الحين أنا هنا يظهر لي المعلمين", tentative: "الأكتف في هذا", speaker: "2")
    }

    func showLivePreview() {
        mode = .online
        startedAt = Date().addingTimeInterval(-205)
        levelMe = 0.3
        levelOthers = 0.6
        phase = .recording
        liveBusy = true
        for (track, text, at) in [
            ("others", "صباح الخير، خلينا نبدأ بآخر تحديثات المشروع.", 171.0),
            ("me", "تمام، خلصنا صفحة الدفع وفاضل ربط البوابة.", 178.0),
            ("others", "طب إمتى نقدر نجربها على السيرفر التجريبي؟", 186.0),
            ("me", "غالبًا يوم الخميس الصبح، وهبعتلك الرابط.", 192.0),
        ] {
            showLine(LiveEntry(track: track, text: text, at: at))
        }
    }

    func showPreview() {
        mode = .online
        startedAt = Date().addingTimeInterval(-754)
        levelMe = 0.35
        levelOthers = 0.7
        phase = .recording
    }

    private func teardown() async {
        Focus.set(false)
        if phase != .saving {
            live?.cancel()
            live = nil
        }
        mic?.stop()
        mic = nil
        await system?.stop()
        system = nil
        sinks.values.forEach { $0.close() }
        sinks = [:]
        if let sleepGuard { ProcessInfo.processInfo.endActivity(sleepGuard) }
        sleepGuard = nil
    }

    private func makeFolder(at date: Date, mode: RecordingMode) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let slug = project.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let name = "\(formatter.string(from: date))_\(slug)_\(mode == .online ? "online" : "in-person")"
        let url = Self.meetingsFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMeta() {
        guard let folder,
              let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: folder.appendingPathComponent("session.json"))
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Rises fast and falls slowly, so the meters look alive instead of flickering.
private func smooth(_ current: Float, _ next: Float) -> Float {
    next > current ? next : current * 0.82 + next * 0.18
}

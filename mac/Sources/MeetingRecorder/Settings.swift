import AVFoundation
import AppKit
import EventKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// The user's settings, kept in ~/.config/meeting-recorder/config.json so the Python side reads
/// the same values. Keys this app doesn't know are left untouched.
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/meeting-recorder/config.json")
    private var raw: [String: Any] = [:]

    @Published var userName = ""
    @Published var language = "ar"
    @Published var prompt = ""
    @Published var reportLanguage = "Arabic"
    /// Words Whisper should spell right, per client.
    @Published var vocabulary: [String: String] = [:]
    /// Watch WhatsApp's folder for new voice notes. Off until the user turns it on.
    @Published var voiceWatch = false
    @Published var voiceAuto = false
    @Published var voiceAutoMinSeconds = 60.0
    @Published var translateTo = "off"
    // Recording behaviour (Settings → Recording).
    @Published var micUID = ""
    @Published var notifyLeadSeconds = 60.0
    @Published var showCountdown = true
    @Published var countdownMinutes = 30.0
    @Published var detectCalls = true
    @Published var maxMinutes = 180.0
    /// What happens when the call app hangs up: "ask", "stop" or "ignore".
    @Published var callEnd = "ask"
    @Published var hideFromCapture = false
    @Published var liveTranscript = true
    /// "word": words appear as they are said (uses more battery); "sentence": every ~10 s.
    @Published var liveMode = "word"
    /// "local": Whisper on this Mac, free. "soniox": Soniox's servers with the user's own key, faster.
    @Published var liveEngine = "local"
    /// Mark lines with a price, a date or a promise by itself while recording.
    @Published var autoMarks = true
    /// Extra words that should get your attention when someone says them, comma separated.
    @Published var alertWords = ""
    @Published var mentionAlert = true
    /// Turn on Do Not Disturb while recording (through two shortcuts the user adds once).
    @Published var focusWhileRecording = false

    /// Your name plus the extra words, ready to match against live lines.
    var mentionWords: [String] {
        let all = [userName] + alertWords.components(separatedBy: CharacterSet(charactersIn: ",،\n"))
        return all.map { Self.fold($0) }.filter { $0.count >= 2 }
    }

    /// Lowercase, and the Arabic letters people write either way made the same.
    static func fold(_ text: String) -> String {
        var t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for (from, to) in [("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ة", "ه"), ("ى", "ي")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return t
    }

    /// Words appear one by one (local word mode, or Soniox, which always streams words).
    var wordByWord: Bool { liveEngine == "soniox" || liveMode == "word" }

    static let sonioxKeyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/meeting-recorder/soniox.key")

    /// Kept in its own file, readable only by this user, never in config.json or the repo.
    var sonioxKey: String {
        get { (try? String(contentsOf: Self.sonioxKeyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set {
            let file = Self.sonioxKeyFile
            let key = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { try? FileManager.default.removeItem(at: file); return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
    @Published var openWindowOnStart = false

    init() { load() }

    func load() {
        raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        userName = raw["user_name"] as? String ?? ""
        if userName == "the user" { userName = "" }
        language = raw["language"] as? String ?? "ar"
        prompt = raw["prompt"] as? String ?? ""
        reportLanguage = raw["report_language"] as? String ?? "Arabic"
        vocabulary = (raw["vocabulary"] as? [String: [String]] ?? [:]).mapValues { $0.joined(separator: "، ") }
        voiceWatch = raw["voice_watch"] as? Bool ?? false
        voiceAuto = raw["voice_auto"] as? Bool ?? false
        voiceAutoMinSeconds = raw["voice_auto_min_seconds"] as? Double ?? 60
        translateTo = raw["translate_to"] as? String ?? "off"
        micUID = raw["mic_uid"] as? String ?? ""
        notifyLeadSeconds = raw["notify_lead_seconds"] as? Double ?? 60
        showCountdown = raw["show_countdown"] as? Bool ?? true
        countdownMinutes = raw["countdown_minutes"] as? Double ?? 30
        detectCalls = raw["detect_calls"] as? Bool ?? true
        maxMinutes = raw["max_minutes"] as? Double ?? 180
        callEnd = raw["call_end"] as? String ?? "ask"
        hideFromCapture = raw["hide_from_capture"] as? Bool ?? false
        liveTranscript = raw["live_transcript"] as? Bool ?? true
        liveMode = raw["live_mode"] as? String ?? "word"
        liveEngine = raw["live_engine"] as? String ?? "local"
        autoMarks = raw["auto_marks"] as? Bool ?? true
        alertWords = raw["alert_words"] as? String ?? ""
        mentionAlert = raw["mention_alert"] as? Bool ?? true
        focusWhileRecording = raw["focus_while_recording"] as? Bool ?? false
        openWindowOnStart = raw["open_window_on_start"] as? Bool ?? false
    }

    func save() {
        raw["user_name"] = userName.isEmpty ? "the user" : userName
        raw["language"] = language
        raw["prompt"] = prompt
        raw["report_language"] = reportLanguage
        raw["vocabulary"] = vocabulary.mapValues { words in
            words.components(separatedBy: CharacterSet(charactersIn: ",،\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }.filter { !$0.value.isEmpty }
        raw["voice_watch"] = voiceWatch
        raw["voice_auto"] = voiceAuto
        raw["voice_auto_min_seconds"] = voiceAutoMinSeconds
        raw["translate_to"] = translateTo
        raw["mic_uid"] = micUID
        raw["notify_lead_seconds"] = notifyLeadSeconds
        raw["show_countdown"] = showCountdown
        raw["countdown_minutes"] = countdownMinutes
        raw["detect_calls"] = detectCalls
        raw["max_minutes"] = maxMinutes
        raw["call_end"] = callEnd
        raw["hide_from_capture"] = hideFromCapture
        raw["live_transcript"] = liveTranscript
        raw["live_mode"] = liveMode
        raw["live_engine"] = liveEngine
        raw["auto_marks"] = autoMarks
        raw["alert_words"] = alertWords
        raw["mention_alert"] = mentionAlert
        raw["focus_while_recording"] = focusWhileRecording
        raw["open_window_on_start"] = openWindowOnStart
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    /// Runs connect_claude.py, which adds the meetings connector to Claude Desktop and Claude Code.
    func connectClaude() async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = Paths.python
            process.arguments = [Paths.script("connect_claude.py").path]
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do { try process.run() } catch { continuation.resume(returning: "Couldn't run the connector setup.") }
        }
    }

    var claudeConnected: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        guard let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: path))) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return Self.claudeCodeConnected }
        if servers["zubda"] != nil || servers["meeting-recorder"] != nil { return true }
        return Self.claudeCodeConnected
    }

    static var claudeDesktopConnected: Bool {
        let extensions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Claude Extensions")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: extensions.path),
           names.contains(where: { $0.contains("zubda") }) { return true }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        guard let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: path))) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers["zubda"] != nil || servers["meeting-recorder"] != nil
    }

    /// Claude Code keeps its servers in ~/.claude.json.
    static var claudeCodeConnected: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: path))) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers["zubda"] != nil || servers["meeting-recorder"] != nil
    }
}

/// Opens SwiftUI content in a normal titled window, for onboarding and settings.
@MainActor
enum Windows {
    private static var open: [String: NSWindow] = [:]

    static func show<Content: View>(_ id: String, title: String, size: CGSize, resizable: Bool = false,
                                    @ViewBuilder content: () -> Content, onClose: (() -> Void)? = nil) {
        if let window = open[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.formUnion([.resizable, .miniaturizable]) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        open[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                open[id] = nil
                onClose?()
            }
        }
    }

    static func close(_ id: String) {
        open[id]?.close()
    }
}

// MARK: - Permissions

private enum Permission: CaseIterable {
    case microphone, systemAudio, calendar, notifications

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "Screen & System Audio Recording"
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        }
    }

    var why: String {
        switch self {
        case .microphone: "Records your voice, or the whole room in an in-person meeting."
        case .systemAudio: "Hears the other side of Zoom, Meet, Teams or WhatsApp calls. Nothing on screen is recorded."
        case .calendar: "Offers to record a meeting a minute before it starts and picks the client."
        case .notifications: "Tells you when a call ended or the mic hears nothing."
        }
    }

    var icon: String {
        switch self {
        case .microphone: "mic.fill"
        case .systemAudio: "speaker.wave.2.fill"
        case .calendar: "calendar"
        case .notifications: "bell.badge.fill"
        }
    }

    func granted() async -> Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .systemAudio: return CGPreflightScreenCaptureAccess()
        case .calendar: return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .notifications: return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
        }
    }

    func request() async {
        switch self {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .systemAudio:
            if !CGRequestScreenCaptureAccess(),
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .calendar:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    @State private var granted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.icon)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(granted ? Color.green : Color(red: 1, green: 0.27, blue: 0.23)))
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.system(size: 13, weight: .semibold))
                Text(permission.why).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 18))
            } else {
                Button("Allow") { Task { await permission.request(); granted = await permission.granted() } }
            }
        }
        .task {
            // macOS settings change outside the app, so keep checking while this is on screen.
            while !Task.isCancelled {
                granted = await permission.granted()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

// MARK: - Shared fields

private struct ProfileFields: View {
    @ObservedObject var config: ConfigStore

    var body: some View {
        Form {
            TextField("Your name", text: $config.userName, prompt: Text("Used in reports, e.g. Kareem"))
            Picker("Meetings are mostly in", selection: $config.language) {
                Text("Arabic").tag("ar")
                Text("English").tag("en")
                Text("Detect automatically").tag("auto")
            }
            TextField("Describe your meetings", text: $config.prompt,
                      prompt: Text("e.g. اجتماع عمل باللهجة المصرية، وفيه مصطلحات إنجليزية."), axis: .vertical)
                .lineLimit(2...3)
            Picker("Write reports in", selection: $config.reportLanguage) {
                Text("Arabic").tag("Arabic")
                Text("Egyptian Arabic").tag("Egyptian Arabic")
                Text("Gulf Arabic").tag("Gulf Arabic")
                Text("English").tag("English")
            }
        }
        .formStyle(.grouped)
        .onChange(of: config.userName) { _, _ in config.save() }
        .onChange(of: config.language) { _, _ in config.save() }
        .onChange(of: config.prompt) { _, _ in config.save() }
        .onChange(of: config.reportLanguage) { _, _ in config.save() }
    }
}

private struct ClaudeConnect: View {
    @ObservedObject var config: ConfigStore
    @State private var status: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: config.claudeConnected ? "checkmark.seal.fill" : "link")
                    .foregroundStyle(config.claudeConnected ? .green : .orange)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.claudeConnected ? "Claude can read your meetings" : "Connect your meetings to Claude")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Then ask Claude Desktop or Claude Code anything about any meeting, even one that's still going.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(config.claudeConnected ? "Reconnect" : "Connect") {
                    working = true
                    Task {
                        status = await config.connectClaude()
                        working = false
                    }
                }
                .disabled(working)
            }
            if let status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var config = ConfigStore.shared
    @State private var page = 0
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: permissions
                case 2: profile
                default: claude
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 30)
            .padding(.top, 34)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(page)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == page ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                if page > 0 { Button("Back") { withAnimation(.spring(response: 0.35)) { page -= 1 } } }
                Button(page == 3 ? "Start" : "Continue") {
                    if page == 3 { finish() } else { withAnimation(.spring(response: 0.35)) { page += 1 } }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .animation(.spring(response: 0.35), value: page)
        }
        .frame(width: 560, height: 520)
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Zubda").font(.system(size: 26, weight: .bold))
            Text("Lives in your notch. Records online and in-person meetings, writes them down on this Mac, and lets Claude understand them.")
                .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                feature("rectangle.topthird.inset.filled", "Hover over the notch to start, mark moments and see the live transcript.")
                feature("lock.fill", "Recordings and transcripts never leave this Mac.")
                feature("sparkles", "Reports, and answers about any meeting, come from your own Claude.")
            }
            .padding(.top, 8)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A few permissions").font(.system(size: 20, weight: .bold))
            Text("macOS asks for each one. You can change them later in System Settings → Privacy & Security.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(Permission.allCases, id: \.self) { PermissionRow(permission: $0) }
            Text("After allowing Screen & System Audio Recording, macOS may ask to quit and reopen the app.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About your meetings").font(.system(size: 20, weight: .bold))
            Text("This helps Whisper understand your dialect and Claude write reports the way you want.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ProfileFields(config: config)
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect Claude").font(.system(size: 20, weight: .bold))
            ClaudeConnect(config: config)
            VStack(alignment: .leading, spacing: 8) {
                Label("Tell people before you record", systemImage: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                Text("In many countries recording someone without their consent is illegal. Say it at the start of every meeting.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 20)
            Text(text).font(.system(size: 13))
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var config = ConfigStore.shared
    @ObservedObject var recorder: Recorder
    @ObservedObject var ui: NotchUI
    @ObservedObject var voice: VoiceNotes
    /// Inside the main window it fills the page; on its own it is a fixed-size window.
    var embedded = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            ScrollView { VStack(alignment: .leading) { ProfileFields(config: config) }.padding() }
                .tabItem { Label("Meetings", systemImage: "person.2.wave.2") }

            RecordingSettings(config: config, ui: ui)
                .tabItem { Label("Recording", systemImage: "record.circle") }

            Form {
                Section("Words to spell right") {
                    Text("Names and terms Whisper keeps getting wrong. Used for that client's meetings.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    ForEach(recorder.projects.filter { $0 != "General" }, id: \.self) { project in
                        TextField(project, text: Binding(
                            get: { config.vocabulary[project] ?? "" },
                            set: { config.vocabulary[project] = $0; config.save() }
                        ), prompt: Text("e.g. Paymob، Stripe، اسم المشروع"))
                    }
                    TextField("All meetings", text: Binding(
                        get: { config.vocabulary["*"] ?? "" },
                        set: { config.vocabulary["*"] = $0; config.save() }
                    ), prompt: Text("Words for every meeting"))
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Clients", systemImage: "folder") }

            Form {
                Section("WhatsApp voice notes") {
                    Toggle("Offer to transcribe new WhatsApp voice notes", isOn: $config.voiceWatch)
                    if voice.blocked {
                        HStack {
                            Text("macOS blocked access to WhatsApp's files. Allow Zubda there, then turn this on again.")
                                .font(.system(size: 11.5)).foregroundStyle(.orange)
                            Button("Open Settings") { voice.openPrivacySettings() }
                        }
                    }
                    Toggle("Transcribe long voice notes on their own", isOn: $config.voiceAuto)
                        .disabled(!config.voiceWatch)
                    Stepper("Longer than \(Int(config.voiceAutoMinSeconds)) seconds",
                            value: $config.voiceAutoMinSeconds, in: 15...600, step: 15)
                        .disabled(!config.voiceAuto)
                    Text("Shorter ones wait for you to click them in the notch. Summaries only run when you ask.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Section("Live captions") {
                    Toggle("Captions under the closed notch", isOn: $ui.captions)
                    Picker("Translate captions to", selection: $config.translateTo) {
                        Text("Don't translate").tag("off")
                        Text("Arabic").tag("ar")
                        Text("English").tag("en")
                    }
                }
                Section {
                    Toggle("Open at login", isOn: $launchAtLogin)
                }
            }
            .formStyle(.grouped)
            .onChange(of: config.voiceWatch) { _, on in
                config.save()
                if on { voice.start() } else { voice.stop() }
            }
            .onChange(of: config.voiceAuto) { _, _ in config.save() }
            .onChange(of: config.voiceAutoMinSeconds) { _, _ in config.save() }
            .onChange(of: config.translateTo) { _, _ in config.save() }
            .onChange(of: launchAtLogin) { _, on in
                if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            }
            .tabItem { Label("Extras", systemImage: "sparkles") }

            VStack(alignment: .leading, spacing: 16) {
                ClaudeConnect(config: config)
                Divider()
                Button("Show the welcome screens again") { AppDelegate.showOnboarding() }
            }
            .padding(24)
            .frame(maxHeight: .infinity, alignment: .top)
            .tabItem { Label("Claude", systemImage: "sparkle") }
        }
        .frame(width: embedded ? nil : 560, height: embedded ? 520 : 470)
        .frame(maxWidth: embedded ? 720 : nil, alignment: .leading)
    }
}


/// How recording behaves: microphone, call detection, limits, privacy while sharing, shortcuts.
/// Do Not Disturb while recording. macOS only lets Shortcuts switch Focus, so the first time
/// the app makes two shortcuts and Shortcuts asks to add them.
private struct FocusRow: View {
    @ObservedObject var config: ConfigStore
    @State private var ready = Focus.installed()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Turn on Do Not Disturb while recording", isOn: $config.focusWhileRecording)
                .disabled(!ready)
            if !ready {
                HStack {
                    Text("Needs two shortcuts, added once. Click Add in Shortcuts for each.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Set up…") { Focus.setUp() }
                    Button("Check again") { ready = Focus.installed() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ready = Focus.installed()
        }
    }
}

/// Where the user pastes their own Soniox key. Shown masked once saved.
private struct SonioxKeyField: View {
    @ObservedObject var config: ConfigStore
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("Soniox API key", text: $key, prompt: Text("snx_…"))
                    .onSubmit(save)
                Button("Paste") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        key = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        save()
                    }
                }
                .help("Paste the key you copied from console.soniox.com")
                Button(saved ? "Saved" : "Save", action: save).disabled(key.isEmpty || saved)
            }
            Text("Words show up in under a second, and your Mac stays cool. The audio is sent to Soniox while you record (about $0.12 an hour per voice track, billed to your Soniox account). The final transcript after the meeting is still made on this Mac. If the key is missing, out of credit or offline, the app switches to this Mac by itself. Get a key at console.soniox.com.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            key = config.sonioxKey
            saved = !key.isEmpty
        }
        .onChange(of: key) { _, _ in saved = !key.isEmpty && key == config.sonioxKey }
    }

    private func save() {
        config.sonioxKey = key
        saved = !key.isEmpty
    }
}

private struct RecordingSettings: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject var ui: NotchUI
    @State private var inputs = AudioDevices.inputs()

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Record your voice from", selection: $config.micUID) {
                    Text("System default").tag("")
                    ForEach(inputs) { Text($0.name).tag($0.uid) }
                }
            }
            Section("Meeting detection") {
                Picker("Offer to record a calendar meeting", selection: $config.notifyLeadSeconds) {
                    Text("15 seconds before").tag(15.0)
                    Text("1 minute before").tag(60.0)
                    Text("2 minutes before").tag(120.0)
                    Text("5 minutes before").tag(300.0)
                }
                Toggle("Show the next meeting countdown in the notch", isOn: $config.showCountdown)
                Picker("Start the countdown", selection: $config.countdownMinutes) {
                    Text("10 minutes before").tag(10.0)
                    Text("30 minutes before").tag(30.0)
                    Text("1 hour before").tag(60.0)
                }
                .disabled(!config.showCountdown)
                Toggle("Ask to record when a call app starts using the mic", isOn: $config.detectCalls)
            }
            Section("Ending a recording") {
                Picker("When the call app hangs up", selection: $config.callEnd) {
                    Text("Ask, then stop after 30 seconds").tag("ask")
                    Text("Stop and save right away").tag("stop")
                    Text("Keep recording").tag("ignore")
                }
                Picker("Longest recording", selection: $config.maxMinutes) {
                    Text("1 hour").tag(60.0)
                    Text("2 hours").tag(120.0)
                    Text("3 hours").tag(180.0)
                    Text("No limit").tag(0.0)
                }
                Text("You get a heads-up two minutes before the limit.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Section("While recording") {
                Toggle("Write the transcript live", isOn: $config.liveTranscript)
                Picker("Live transcript runs on", selection: $config.liveEngine) {
                    Text("This Mac (free, private)").tag("local")
                    Text("Soniox (faster, uses your API key)").tag("soniox")
                }
                .disabled(!config.liveTranscript)
                if config.liveEngine == "local" {
                    Picker("Live transcript speed", selection: $config.liveMode) {
                        Text("Word by word (more battery)").tag("word")
                        Text("Sentence by sentence (every ~10 s)").tag("sentence")
                    }
                    .disabled(!config.liveTranscript)
                } else {
                    SonioxKeyField(config: config)
                }
                Toggle("Mark prices, dates and promises by itself", isOn: $config.autoMarks).disabled(!config.liveTranscript)
                Toggle("Get my attention when someone says my name", isOn: $config.mentionAlert).disabled(!config.liveTranscript)
                TextField("Also for these words", text: $config.alertWords,
                          prompt: Text("e.g. باشمهندس, your project name — your name from Settings is included"))
                    .disabled(!config.liveTranscript || !config.mentionAlert)
                    .onSubmit { config.save() }
                Toggle("Captions under the closed notch", isOn: $ui.captions).disabled(!config.liveTranscript)
                Toggle("Open the main window when a recording starts", isOn: $config.openWindowOnStart)
                FocusRow(config: config)
                Toggle("Hide the notch from screenshots and screen sharing", isOn: $config.hideFromCapture)
            }
            Section("Keyboard shortcuts") {
                LabeledContent("Start or stop an online recording", value: "⌃⌥R")
                LabeledContent("Mark this moment", value: "⌃⌥M")
                LabeledContent("Spoken note (outside meetings)", value: "⌃⌥N")
                LabeledContent("Show or hide sidebar labels", value: "⌃⌘S")
            }
            Section("Bring in old recordings") {
                HStack {
                    Text("Transcribe and summarise an audio or video file you already have.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import…") { AppDelegate.importRecording() }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: config.micUID) { _, _ in config.save() }
        .onChange(of: config.notifyLeadSeconds) { _, _ in config.save() }
        .onChange(of: config.showCountdown) { _, _ in config.save() }
        .onChange(of: config.countdownMinutes) { _, _ in config.save() }
        .onChange(of: config.detectCalls) { _, _ in config.save() }
        .onChange(of: config.callEnd) { _, _ in config.save() }
        .onChange(of: config.maxMinutes) { _, _ in config.save() }
        .onChange(of: config.liveTranscript) { _, _ in config.save() }
        .onChange(of: config.liveMode) { _, _ in config.save() }
        .onChange(of: config.liveEngine) { _, _ in config.save() }
        .onChange(of: config.autoMarks) { _, _ in config.save() }
        .onChange(of: config.mentionAlert) { _, _ in config.save() }
        .onChange(of: config.focusWhileRecording) { _, _ in config.save() }
        .onChange(of: config.alertWords) { _, _ in config.save() }
        .onChange(of: config.openWindowOnStart) { _, _ in config.save() }
        .onChange(of: config.hideFromCapture) { _, hide in
            config.save()
            NotchPanel.applyCapturePrivacy(hide)
        }
    }
}

import ServiceManagement
import CoreSpotlight
import AppKit
import SwiftUI

@main
enum MeetingRecorderApp {
    @MainActor private static let delegate = AppDelegate()

    @MainActor static func main() {
        // Writing to a live-transcription worker that died must fail quietly, not end the app.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recorder = Recorder()
    private let queue = ProcessingQueue()
    private let calendar = CalendarWatcher()
    private let ask = Ask()
    private let voice = VoiceNotes()
    private let library = Library()
    private lazy var autopilot = AutoPilot(recorder: recorder, calendar: calendar)
    private var notch: NotchController?
    private static weak var shared: AppDelegate?

    /// First run walks through permissions, the user's details and connecting Claude.
    static func showOnboarding() {
        guard let app = shared else { return }
        Windows.show("onboarding", title: "", size: CGSize(width: 560, height: 520)) {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: "onboarded")
                Windows.close("onboarding")
                Notifier.setUp()
                app.calendar.start()
            }
        }
    }

    static func showEditor(folder: URL) {
        Windows.show("editor-\(folder.lastPathComponent)", title: "Edit transcript", size: CGSize(width: 680, height: 620)) {
            TranscriptEditor(folder: folder)
        }
    }

    /// The main window. The app shows in the Dock while it is open and hides again after.
    static func showMain() {
        guard let app = shared, let ui = app.notch?.ui else { return }
        NSApp.setActivationPolicy(.regular)
        Windows.show("main", title: "Zubda", size: CGSize(width: 1180, height: 760), resizable: true) {
            MainView(library: app.library, recorder: app.recorder, calendar: app.calendar, ui: ui, voice: app.voice, ask: app.ask)
        } onClose: {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Clicking the app in Finder or Launchpad while it runs opens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showMain()
        return false
    }

    /// Picks an audio or video file and imports it as a meeting for the current client.
    static func importRecording() {
        guard let app = shared else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.message = "Choose recordings to transcribe and summarise"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { app.recorder.importRecording(url) }
        Navigator.shared.section = .home
        showMain()
    }

    static func showSettings() {
        guard let app = shared, let ui = app.notch?.ui else { return }
        Windows.show("settings", title: "Zubda Settings", size: CGSize(width: 560, height: 470)) {
            SettingsView(recorder: app.recorder, ui: ui, voice: app.voice)
        }
    }

    /// A Spotlight result for a meeting moment was opened.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        Spotlight.open(id)
        return true
    }

    /// The app has no visible menu bar (it lives in the notch), but text fields only get
    /// ⌘C/⌘V/⌘X/⌘A/⌘Z through an Edit menu, so one is installed behind the scenes.
    private static func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Zubda", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        Self.installEditMenu()
        let queue = queue
        let recorder = recorder
        recorder.onSaved = { folder, title in queue.add(folder: folder, title: title) }
        queue.onReport = {
            recorder.refreshBrief()
            Spotlight.reindex()
        // After a move or rename (Meeting Recorder.app → Zubda.app) the login item points at the
        // old copy; registering again points it at this one.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.register() }
        }
        Spotlight.reindex()
        recorder.refreshBrief()
        queue.resumeUnprocessed()
        let autopilot = autopilot
        Notifier.onStop = { autopilot.stopNow() }
        Notifier.onKeep = { autopilot.keepRecording() }
        notch = NotchController(recorder: recorder, autopilot: autopilot, queue: queue, ask: ask,
                                voice: voice, calendar: calendar)
        if ProcessInfo.processInfo.environment["MR_PREVIEW"] == nil { voice.start() }
        let preview = ProcessInfo.processInfo.environment["MR_PREVIEW"]
        if preview == "onboarding" || (preview == nil && !UserDefaults.standard.bool(forKey: "onboarded")) {
            Self.showOnboarding()
        } else if preview == nil {
            Notifier.setUp()
            calendar.start()
        }
        // ⌃⌥M marks the moment; ⌃⌥R starts an online recording or stops the current one.
        HotKeys.register(keyCode: 0x2E, modifiers: HotKeys.control | HotKeys.option) {
            MainActor.assumeIsolated { recorder.mark() }
        }
        // ⌃⌥N records a quick spoken note (outside meetings; during one, it marks the moment).
        let voice = voice
        HotKeys.register(keyCode: 0x2D, modifiers: HotKeys.control | HotKeys.option) {
            MainActor.assumeIsolated {
                if recorder.phase == .recording { recorder.mark() } else { voice.toggleNote() }
            }
        }
        HotKeys.register(keyCode: 0x0F, modifiers: HotKeys.control | HotKeys.option) {
            MainActor.assumeIsolated {
                _ = Task {
                    if recorder.phase == .recording { await recorder.stop() } else { await recorder.start(.online) }
                }
            }
        }
    }

    /// Quitting mid-meeting saves the recording first instead of losing it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.phase == .recording else { return .terminateNow }
        Task {
            await recorder.stop(transcribe: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// A borderless panel that sits over the notch, above the menu bar, on every Space.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }

    /// Keeps the notch out of screenshots, recordings and screen sharing when asked to.
    @MainActor static func applyCapturePrivacy(_ hide: Bool) {
        for window in NSApp.windows where window is NotchPanel {
            window.sharingType = hide ? .none : .readOnly
        }
    }
}

/// Lets the first click on a button act straight away instead of only focusing the panel.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    private static let canvas = CGSize(width: 620, height: 340)

    private let panel = NotchPanel()
    let ui = NotchUI()
    private let recorder: Recorder
    private let autopilot: AutoPilot
    private let queue: ProcessingQueue
    private let ask: Ask
    private let voice: VoiceNotes
    private let calendar: CalendarWatcher
    private var screen: NSScreen?
    private var leftAt: Date?

    init(recorder: Recorder, autopilot: AutoPilot, queue: ProcessingQueue, ask: Ask,
         voice: VoiceNotes, calendar: CalendarWatcher) {
        self.recorder = recorder
        self.autopilot = autopilot
        self.queue = queue
        self.ask = ask
        self.voice = voice
        self.calendar = calendar
        panel.contentView = FirstClickHostingView(
            rootView: NotchRoot(ui: ui, recorder: recorder, autopilot: autopilot, queue: queue, ask: ask,
                                voice: voice, calendar: calendar)
        )
        place()
        panel.orderFrontRegardless()
        let ui = ui
        recorder.onMention = { text in
            ui.holdOpenUntil = Date().addingTimeInterval(12)
            ui.expanded = true
            NSSound(named: "Glass")?.play()
            Notifier.mention(text)
        }
        panel.sharingType = ConfigStore.shared.hideFromCapture ? .none : .readOnly

        // Screenshots of the open notch without moving the pointer: MR_PREVIEW=expanded.
        switch ProcessInfo.processInfo.environment["MR_PREVIEW"] {
        case "expanded":
            ui.expanded = true
            return
        case "recording":
            recorder.showPreview()
            ui.expanded = true
            return
        case "main":
            DispatchQueue.main.async { AppDelegate.showMain() }
            return
        case let page? where page.hasPrefix("page:"):
            // MR_PREVIEW=page:Clients opens the main window on that page, for screenshots.
            if let section = SidebarSection(rawValue: String(page.dropFirst(5))) {
                DispatchQueue.main.async {
                    Navigator.shared.section = section
                    AppDelegate.showMain()
                }
            }
            return
        case "open-meeting":
            // The newest meeting that has a report, opened inside the main window.
            let folders = (try? FileManager.default.contentsOfDirectory(at: Recorder.meetingsFolder, includingPropertiesForKeys: nil)) ?? []
            if let folder = folders.filter({ FileManager.default.fileExists(atPath: $0.appendingPathComponent("report.html").path) })
                .max(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                DispatchQueue.main.async { Navigator.shared.open(meeting: folder) }
            }
            return
        case "live-room":
            recorder.showRoomPreview()
            ui.expanded = true
            return
        case "live":
            recorder.showLivePreview()
            ui.expanded = true
            return
        case "voice":
            voice.card = .result(title: "Voice note · 1:12", text: "أهلا يا كريم، معلش اتأخرت عليك. بخصوص الميتنج بكرة، ممكن نخليه الساعة ٦ بدل ٤؟ وابعتلي الملف اللي اتكلمنا عليه قبلها لو تقدر.")
            return
        case "morning":
            autopilot.showPreview(.morning(lines: ["10:00 · Acme weekly sync", "4:00 · Northwind demo",
                                                   "Acme: send the revised quote", "Acme: confirm the delivery date"]))
            return
        case "live-closed":
            recorder.showLivePreview()
            return
        case "recording-closed":
            recorder.showPreview()
            return
        case "queue":
            queue.showPreview()
            ui.expanded = true
            return
        case "queue-closed":
            queue.showPreview()
            return
        case "answer":
            ask.showPreview()
            ui.expanded = true
            return
        case "meeting":
            recorder.addProject("Acme")
            autopilot.showPreview(.meeting(CalendarWatcher.Meeting(
                id: "preview", title: "Acme weekly sync", start: Date().addingTimeInterval(60),
                end: Date().addingTimeInterval(3600), attendees: ["Sara", "Omar"], notes: "")))
            return
        case "prompt-start":
            autopilot.showPreview(.start(app: "Zoom"))
            return
        case "prompt-end":
            recorder.showPreview()
            autopilot.showPreview(.end(reason: "The call app stopped using the mic.", deadline: Date().addingTimeInterval(47)))
            return
        default:
            break
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // Polling the pointer is simpler and steadier than tracking areas on a window that
        // ignores mouse events while closed; at 30 Hz it costs nothing measurable.
        Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
    }

    private func place() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        self.screen = screen
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            ui.notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            ui.hasNotch = true
        } else {
            ui.notch = CGSize(width: 190, height: max(24, NSStatusBar.system.thickness))
            ui.hasNotch = false
        }
        let frame = screen.frame
        panel.setFrame(
            NSRect(x: frame.midX - Self.canvas.width / 2, y: frame.maxY - Self.canvas.height,
                   width: Self.canvas.width, height: Self.canvas.height),
            display: true
        )
    }

    private func trackPointer() {
        guard let screen else { return }
        let size = ui.size(for: recorder.phase, prompt: autopilot.prompt, queue: queue,
                           brief: recorder.brief, ask: ask.state, hasCaptions: !recorder.liveEntries.isEmpty || recorder.liveDraft != nil,
                           voice: voice.card, countdown: NextMeeting.soon(calendar.next) != nil)
        let shape = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        let zone = ui.expanded ? shape.insetBy(dx: -18, dy: -18) : shape.insetBy(dx: -4, dy: -2)

        if zone.contains(NSEvent.mouseLocation) {
            leftAt = nil
            if !ui.expanded { ui.expanded = true }
        } else if ui.holdOpenUntil > Date() {
            leftAt = nil
        } else if ui.expanded {
            if let leftAt {
                if Date().timeIntervalSince(leftAt) > 0.35 {
                    ui.expanded = false
                    self.leftAt = nil
                }
            } else {
                leftAt = Date()
            }
        }
        panel.ignoresMouseEvents = !(ui.expanded || autopilot.prompt != nil || voice.card != nil)
    }
}

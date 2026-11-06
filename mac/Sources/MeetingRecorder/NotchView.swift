import ServiceManagement
import SwiftUI

@MainActor
final class NotchUI: ObservableObject {
    @Published var expanded = false
    /// Kept open until then even without the pointer, e.g. after someone says your name.
    var holdOpenUntil = Date.distantPast
    @Published var notch = CGSize(width: 200, height: 32)
    /// Live captions under the closed notch while recording, like a teleprompter.
    @Published var captions = UserDefaults.standard.object(forKey: "closedCaptions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(captions, forKey: "closedCaptions") }
    }
    static let captionHeight: CGFloat = 62
    var hasNotch = false

    static let wing: CGFloat = 84

    static func answerHeight(_ state: Ask.State) -> CGFloat {
        switch state {
        case .idle: 0
        case .asking, .failed: 58
        case .answered: 178
        }
    }
    static let expandedWidth: CGFloat = 440

    /// The black shape's size for the current state. The window controller uses the same
    /// numbers to decide where the pointer counts as "on the notch".
    func size(for phase: Phase, prompt: AutoPilot.Prompt?, queue: ProcessingQueue,
              brief: Brief?, ask: Ask.State, hasCaptions: Bool = false,
              voice: VoiceNotes.Card? = nil, countdown: Bool = false) -> CGSize {
        if let prompt {
            var body: CGFloat = 104
            if let brief, prompt.wantsBrief { body += 30 + CGFloat(min(brief.items.count, 4)) * 20 }
            if case .morning(let lines) = prompt { body = 92 + CGFloat(min(lines.count, 7)) * 21 }
            return CGSize(width: Self.expandedWidth, height: notch.height + body)
        }
        if let voice {
            let body: CGFloat = switch voice {
            case .new: 98
            case .working, .recordingNote: 72
            case .result: 236
            }
            return CGSize(width: Self.expandedWidth, height: notch.height + body)
        }
        if expanded {
            let rows = queue.listed.count
            let body: CGFloat = switch phase {
            case .recording: 356 + Self.answerHeight(ask)
            case .starting, .saving: 96
            default: (rows == 0 ? 172 : 150 + CGFloat(rows) * 44) + 44 + Self.answerHeight(ask)
            }
            return CGSize(width: Self.expandedWidth, height: notch.height + body)
        }
        if phase == .idle && queue.active == nil && !queue.justFinished && !countdown { return notch }
        let captionRoom = phase == .recording && captions && hasCaptions ? Self.captionHeight : 0
        return CGSize(width: notch.width + Self.wing * 2, height: notch.height + captionRoom)
    }
}

private let spring = Animation.spring(response: 0.34, dampingFraction: 0.86)
private let accent = Color(red: 1.0, green: 0.27, blue: 0.23)

struct NotchRoot: View {
    @ObservedObject var ui: NotchUI
    @ObservedObject var recorder: Recorder
    @ObservedObject var autopilot: AutoPilot
    @ObservedObject var queue: ProcessingQueue
    @ObservedObject var ask: Ask
    @ObservedObject var voice: VoiceNotes
    @ObservedObject var calendar: CalendarWatcher

    var body: some View {
        let size = ui.size(for: recorder.phase, prompt: autopilot.prompt, queue: queue, brief: recorder.brief,
                           ask: ask.state, hasCaptions: !recorder.liveEntries.isEmpty || recorder.liveDraft != nil,
                           voice: voice.card, countdown: NextMeeting.soon(calendar.next) != nil)
        let open = ui.expanded || autopilot.prompt != nil || voice.card != nil
        ZStack(alignment: .top) {
            NotchShape(topRadius: open ? 14 : 6, bottomRadius: open ? 28 : 12)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(open ? 0.5 : 0), radius: 22, y: 10)

            Group {
                if let prompt = autopilot.prompt {
                    PromptView(prompt: prompt, autopilot: autopilot, recorder: recorder)
                        .padding(.top, ui.notch.height + 8)
                        .padding(.horizontal, 30)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else if let card = voice.card {
                    VoiceCard(card: card, voice: voice)
                        .padding(.top, ui.notch.height + 8)
                        .padding(.horizontal, 30)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else if ui.expanded {
                    ExpandedView(ui: ui, recorder: recorder, queue: queue, ask: ask)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(spring.delay(0.05)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))
                        ))
                } else {
                    CollapsedView(ui: ui, recorder: recorder, queue: queue, calendar: calendar)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: ui.expanded)
        .animation(spring, value: recorder.phase)
        .animation(spring, value: autopilot.prompt)
        .animation(spring, value: queue.jobs)
        .animation(spring, value: queue.justFinished)
        .animation(spring, value: voice.card)
        .animation(spring, value: calendar.next)
        .animation(spring, value: ask.state)
        .animation(spring, value: recorder.brief)
        .animation(spring, value: recorder.liveEntries.isEmpty)
        .animation(spring, value: ui.captions)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Closed notch

private struct CollapsedView: View {
    @ObservedObject var ui: NotchUI
    @ObservedObject var recorder: Recorder
    @ObservedObject var queue: ProcessingQueue
    @ObservedObject var calendar: CalendarWatcher

    var body: some View {
        if recorder.phase != .idle || queue.active != nil || queue.justFinished || NextMeeting.soon(calendar.next) != nil {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    leading.frame(width: NotchUI.wing)
                    Color.clear.frame(width: ui.notch.width)
                    trailing.frame(width: NotchUI.wing)
                }
                .frame(height: ui.notch.height)
                .environment(\.layoutDirection, .leftToRight)
                if recorder.phase == .recording && ui.captions && (!recorder.liveEntries.isEmpty || recorder.liveDraft != nil) {
                    Teleprompter(entries: recorder.liveEntries, draft: recorder.liveDraft,
                                 level: max(recorder.levelMe, recorder.levelOthers))
                        .frame(height: NotchUI.captionHeight)
                        .padding(.horizontal, 22)
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder private var leading: some View {
        switch recorder.phase {
        case .recording:
            HStack(spacing: 6) {
                PulsingDot(paused: recorder.paused)
                Image(systemName: recorder.micSilent ? "mic.slash.fill" : recorder.mode == .online ? "video.fill" : "person.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(recorder.micSilent ? Color.orange : .white.opacity(0.6))
                    .symbolEffect(.pulse, isActive: recorder.micSilent)
                StarFlash(count: recorder.markCount)
            }
        case .starting, .saving:
            ProgressView().controlSize(.mini).tint(.white)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 13))
        case .idle:
            if queue.active != nil {
                ProgressView().controlSize(.mini).tint(.white)
            } else if queue.justFinished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 14))
            } else if NextMeeting.soon(calendar.next) != nil {
                Image(systemName: "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch recorder.phase {
        case .recording:
            HStack(spacing: 5) {
                Wave(level: max(recorder.levelMe, recorder.levelOthers), bars: 4, height: 12)
                if let start = recorder.startedAt {
                    ElapsedText(since: start, size: 11, compact: true)
                }
            }
        case .saving, .starting:
            Text("Saving").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        case .failed:
            Text("Problem").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
        case .idle:
            if let job = queue.active {
                HStack(spacing: 5) {
                    Image(systemName: job.stage == .reporting ? "doc.text" : "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    ElapsedText(since: job.since, size: 11, compact: true)
                }
            } else if queue.justFinished {
                Text("Ready").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
            } else if let next = calendar.next, NextMeeting.soon(next) != nil {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(NextMeeting.soon(next) ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .fixedSize()
                }
                .help(next.title)
            }
        }
    }
}

// MARK: - Open notch

private struct ExpandedView: View {
    @ObservedObject var ui: NotchUI
    @ObservedObject var recorder: Recorder
    @ObservedObject var queue: ProcessingQueue
    @ObservedObject var ask: Ask

    var body: some View {
        VStack(spacing: 12) {
            switch recorder.phase {
            case .recording:
                RecordingPanel(recorder: recorder, ask: ask)
            case .starting, .saving:
                BusyPanel(phase: recorder.phase)
            default:
                IdlePanel(ui: ui, recorder: recorder, queue: queue, ask: ask)
            }
        }
        .padding(.top, ui.notch.height + 8)
        .padding(.horizontal, 30)
        .padding(.bottom, 14)
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct IdlePanel: View {
    @ObservedObject var ui: NotchUI
    @ObservedObject var recorder: Recorder
    @ObservedObject var queue: ProcessingQueue
    @ObservedObject var ask: Ask

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                ProjectMenu(recorder: recorder)
                Spacer()
                Button {
                    // meet.new makes a fresh Google Meet in the browser; record it straight away.
                    NSWorkspace.shared.open(URL(string: "https://meet.new")!)
                    Task { await recorder.start(.online) }
                } label: { Label("New Meet", systemImage: "plus.circle.fill").font(.system(size: 11.5, weight: .semibold)) }
                    .buttonStyle(PillButtonStyle(tint: .white.opacity(0.12)))
                    .help("Start a new Google Meet and record it")
                SettingsMenu(recorder: recorder, ui: ui)
            }

            HStack(spacing: 10) {
                ModeTile(icon: "video.fill", title: "Online meeting", subtitle: "Zoom, Meet, Teams, WhatsApp") {
                    Task { await recorder.start(.online) }
                }
                ModeTile(icon: "person.2.fill", title: "In-person meeting", subtitle: "Laptop mic, whole room") {
                    Task { await recorder.start(.room) }
                }
            }

            AskField(ask: ask)
            if ask.state != .idle { AnswerCard(ask: ask) }

            footer
        }
    }

    @ViewBuilder private var footer: some View {
        if let notice = recorder.notice {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(notice).lineLimit(2)
                Spacer(minLength: 0)
                if recorder.needsScreenPermission {
                    Button("Open Settings") { recorder.openScreenPermission() }
                        .buttonStyle(PillButtonStyle(tint: .white.opacity(0.14)))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.85))
        }
        if queue.listed.isEmpty {
            if recorder.notice == nil {
                Text(ConfigStore.shared.liveEngine == "soniox" ? "Recordings stay on this Mac · live text via Soniox" : "Recordings stay on this Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 6) {
                ForEach(queue.listed) { job in
                    JobRow(job: job, position: queue.jobs.filter { $0.stage == .waiting }.firstIndex { $0.id == job.id },
                           open: { queue.open(job) }, discard: { queue.discard(job) })
                }
            }
        }
    }
}

private struct JobRow: View {
    let job: ProcessingQueue.Job
    /// Place in line, for a job that is still waiting.
    let position: Int?
    let open: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 9) {
                icon.frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if job.stage.isActive {
                    ElapsedText(since: job.since, size: 11, compact: true).foregroundStyle(.white.opacity(0.6))
                }
                if job.stage.isActive || job.stage == .waiting {
                    Button(action: discard) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.35))
                        .help("Stop and move this recording to the Trash")
                } else if case .ready = job.stage {
                    Button { AppDelegate.showEditor(folder: job.folder) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.5))
                        .help("Fix words in the transcript")
                    Button("Open", action: open).buttonStyle(PillButtonStyle(tint: .white.opacity(0.14)))
                }
            }
            if job.stage.isActive { Shimmer() }
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.stage {
        case .waiting: Image(systemName: "clock").foregroundStyle(.white.opacity(0.45))
        case .transcribing, .reporting: ProgressView().controlSize(.mini).tint(.white)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var detail: String {
        switch job.stage {
        case .waiting: "Waiting in line" + (position.map { $0 > 0 ? " (#\($0 + 1))" : "" } ?? "")
        case .transcribing: "Step 1 of 2 · Turning speech into text on this Mac"
        case .reporting: "Step 2 of 2 · Claude is writing the report"
        case .ready(let report): report ? "Report ready" : "Transcript ready, report not written"
        case .failed(let reason): reason
        }
    }
}

/// A light sweeping across a thin bar: shows the work is alive even when no number moves.
private struct Shimmer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, accent, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: geo.size.width * (CGFloat(t) * 1.35 - 0.35))
                }
                .clipShape(Capsule())
            }
            .frame(height: 3)
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}

private struct RecordingPanel: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var ask: Ask

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    PulsingDot(paused: recorder.paused)
                    Text(recorder.micSilent ? "Mic hears nothing" : title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(recorder.micSilent ? Color.orange : .white.opacity(0.9))
                    ProjectMenu(recorder: recorder)
                }
                Spacer()
                if let start = recorder.startedAt {
                    ElapsedText(since: start, size: 22)
                }
            }

            VStack(spacing: 8) {
                if recorder.mode == .online {
                    Meter(label: "Others", level: recorder.levelOthers, tint: .cyan)
                    Meter(label: "Me", level: recorder.paused ? 0 : recorder.levelMe, tint: .mint, muted: recorder.paused)
                } else {
                    Meter(label: "Room", level: recorder.paused ? 0 : recorder.levelMe, tint: .mint, muted: recorder.paused)
                }
            }

            LiveFeed(entries: recorder.liveEntries, draft: recorder.liveDraft, busy: recorder.liveBusy, mode: recorder.mode) {
                if let folder = recorder.folder { ask.catchUp(folder: folder) }
            }
            if ask.state != .idle { AnswerCard(ask: ask) }

            NoteField(recorder: recorder)

            HStack(spacing: 8) {
                DiscardButton(recorder: recorder)

                MarkButton(recorder: recorder)

                Button { recorder.togglePause() } label: {
                    Label(pauseTitle, systemImage: pauseIcon).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: .white.opacity(0.12)))

                Button { Task { await recorder.stop() } } label: {
                    Label("Stop & Save", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: accent))
            }
        }
    }

    private var title: String {
        if recorder.paused && recorder.mode == .room { return "Paused" }
        return recorder.mode == .online ? "Online" : "In person"
    }

    private var pauseTitle: String {
        switch (recorder.mode, recorder.paused) {
        case (.online, false): "Mute my mic"
        case (.online, true): "Unmute my mic"
        case (.room, false): "Pause"
        case (.room, true): "Resume"
        }
    }

    private var pauseIcon: String {
        switch (recorder.mode, recorder.paused) {
        case (.online, false): "mic.slash.fill"
        case (.online, true): "mic.fill"
        case (.room, false): "pause.fill"
        case (.room, true): "play.fill"
        }
    }
}

/// Marks the moment and shows it worked: the star bounces and the label says so for a moment.
private struct MarkButton: View {
    @ObservedObject var recorder: Recorder
    @State private var flashed = false

    var body: some View {
        Button { recorder.mark() } label: {
            Label(flashed ? "Marked!" : "Mark", systemImage: "star.fill")
                .symbolEffect(.bounce, value: recorder.markCount)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)
        }
        .buttonStyle(PillButtonStyle(tint: flashed ? Color.yellow.opacity(0.35) : .white.opacity(0.12)))
        .scaleEffect(flashed ? 1.06 : 1)
        .help("Mark this moment (⌃⌥M)")
        .onChange(of: recorder.markCount) { _, _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { flashed = true }
            Task {
                try? await Task.sleep(for: .seconds(1.3))
                withAnimation(.easeOut(duration: 0.3)) { flashed = false }
            }
        }
    }
}

/// Throws the recording away. The first click asks, the second one discards; the folder goes
/// to the Trash, not straight to deletion.
private struct DiscardButton: View {
    @ObservedObject var recorder: Recorder
    @State private var confirming = false

    var body: some View {
        Button {
            if confirming {
                Task { await recorder.discard() }
            } else {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { confirming = true }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(.easeOut(duration: 0.2)) { confirming = false }
                }
            }
        } label: {
            if confirming {
                Label("Discard?", systemImage: "trash.fill").fixedSize()
            } else {
                Image(systemName: "trash").frame(width: 18)
            }
        }
        .buttonStyle(PillButtonStyle(tint: confirming ? Color.red.opacity(0.75) : .white.opacity(0.12)))
        .help("Throw this recording away without transcribing it")
    }
}

private struct BusyPanel: View {
    let phase: Phase

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var title: String {
        switch phase {
        case .starting: "Starting"
        default: "Finishing the transcript"
        }
    }

    private var subtitle: String {
        "One moment"
    }
}

// MARK: - Pieces

private struct ModeTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Circle().fill(accent.opacity(hovering ? 1 : 0.85))
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.13 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.18 : 0.06))
            )
            .scaleEffect(hovering ? 1.025 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
    }
}

private struct Meter: View {
    let label: String
    let level: Float
    let tint: Color
    var muted = false

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * CGFloat(min(1, level))))
                        .opacity(muted ? 0.25 : 1)
                }
            }
            .frame(height: 6)
            .environment(\.layoutDirection, .leftToRight)
            .animation(.easeOut(duration: 0.12), value: level)
            Image(systemName: muted ? "mic.slash.fill" : "waveform")
                .font(.system(size: 10))
                .foregroundStyle(muted ? .orange : .white.opacity(0.35))
                .frame(width: 14)
        }
    }
}

/// Bars that breathe with the voice level and keep a slight motion even in silence.
private struct Wave: View {
    let level: Float
    let bars: Int
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = 0.55 + 0.45 * abs(sin(t * 7 + Double(i) * 1.3))
                    Capsule()
                        .fill(accent)
                        .frame(width: 2.5, height: max(3, height * CGFloat(min(1, level * 1.6)) * wobble))
                }
            }
            .frame(height: height)
        }
    }
}

private struct PulsingDot: View {
    let paused: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(accent.opacity(0.35)).frame(width: 14, height: 14)
                .scaleEffect(pulse && !paused ? 1.25 : 0.6)
                .opacity(pulse && !paused ? 0 : 0.9)
            Circle().fill(paused ? Color.orange : accent).frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

private struct ElapsedText: View {
    let since: Date
    let size: CGFloat
    /// Drops the hours while under an hour, so it fits beside the notch.
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(format(seconds))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .lineLimit(1)
                .fixedSize()
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private func format(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        if compact && h == 0 { return String(format: "%02d:%02d", m, s) }
        return String(format: compact ? "%d:%02d:%02d" : "%02d:%02d:%02d", h, m, s)
    }
}

private struct SettingsMenu: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var ui: NotchUI
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Menu {
            Button("Open Zubda") { AppDelegate.showMain() }
            Button("Settings…") { AppDelegate.showSettings() }
            Button("Open Meetings Archive") { Transcriber.openArchive() }
            Button("Open Recordings Folder") { recorder.openLastFolder() }
            Toggle("Open at Login", isOn: $launchAtLogin)
            Toggle("Live Captions Under the Notch", isOn: $ui.captions)
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onChange(of: launchAtLogin) { _, enabled in
            if enabled { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

private struct PromptView: View {
    let prompt: AutoPilot.Prompt
    @ObservedObject var autopilot: AutoPilot
    @ObservedObject var recorder: Recorder

    var body: some View {
        switch prompt {
        case .meeting(let event):
            card(icon: "calendar", tint: accent, title: event.title, subtitle: when(event)) {
                ProjectMenu(recorder: recorder)
                Spacer(minLength: 0)
                Button("Not now") { autopilot.dismissStart() }
                    .buttonStyle(PillButtonStyle(tint: .white.opacity(0.12)))
                if let link = event.link {
                    Button {
                        NSWorkspace.shared.open(link)
                        autopilot.acceptStart()
                    } label: { Label("Join & Record", systemImage: "video.fill") }
                        .buttonStyle(PillButtonStyle(tint: accent))
                } else {
                    Button { autopilot.acceptStart() } label: { Label("Record", systemImage: "record.circle") }
                        .buttonStyle(PillButtonStyle(tint: accent))
                }
            }
        case .start(let app):
            card(icon: "waveform.circle.fill", tint: accent,
                 title: "\(app) is using your mic", subtitle: "Record this meeting? Pick the client first.") {
                ProjectMenu(recorder: recorder)
                Spacer(minLength: 0)
                Menu("Not now") {
                    Button("Not now") { autopilot.dismissStart() }
                    Button("Never ask for \(app)") { autopilot.ignorePromptedApp() }
                } primaryAction: {
                    autopilot.dismissStart()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                    .buttonStyle(PillButtonStyle(tint: .white.opacity(0.12)))
                Button { autopilot.acceptStart() } label: { Label("Record", systemImage: "record.circle") }
                    .buttonStyle(PillButtonStyle(tint: accent))
            }
        case .morning(let lines):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "sun.max.fill").font(.system(size: 22)).foregroundStyle(.yellow).symbolEffect(.pulse)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Good morning").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Today's meetings and what's still open").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Button("Got it") { autopilot.dismissMorning() }.buttonStyle(PillButtonStyle(tint: .white.opacity(0.12)))
                }
                ForEach(lines.prefix(7), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(accent)
                        Text(line).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
        case .end(let reason, let deadline):
            card(icon: "stop.circle.fill", tint: .orange, title: "Meeting over?", subtitle: reason) {
                Button("Keep recording") { autopilot.keepRecording() }
                    .buttonStyle(PillButtonStyle(tint: .white.opacity(0.12)))
                Button { autopilot.stopNow() } label: { Countdown(deadline: deadline) }
                    .buttonStyle(PillButtonStyle(tint: accent))
            }
        }
    }

    private func card<Buttons: View>(icon: String, tint: Color, title: String, subtitle: String,
                                     @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 24)).foregroundStyle(tint).symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if prompt.wantsBrief, let brief = recorder.brief {
                BriefView(project: recorder.project, brief: brief)
            }
            HStack(spacing: 8) { buttons() }
        }
    }

    private func when(_ event: CalendarWatcher.Meeting) -> String {
        let minutes = Int((event.start.timeIntervalSinceNow / 60).rounded())
        let time = minutes > 0 ? "Starts in \(minutes) min" : minutes == 0 ? "Starting now" : "Started \(-minutes) min ago"
        let people = event.attendees.count > 1 ? " · \(event.attendees.count) people" : ""
        return time + people
    }
}

extension AutoPilot.Prompt {
    /// Start prompts show what was left open last time with the client.
    var wantsBrief: Bool {
        switch self {
        case .start, .meeting: true
        case .end, .morning: false
        }
    }
}

private struct BriefView: View {
    let project: String
    let brief: Brief

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Last time with \(project) · \(brief.when)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            ForEach(brief.items.prefix(4), id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(accent)
                    Text(item).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .environment(\.layoutDirection, .rightToLeft)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
    }
}

private struct AskField: View {
    @ObservedObject var ask: Ask
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(accent)
            TextField("Ask about your meetings…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($focused)
                .disabled(ask.busy)
                .onSubmit {
                    ask.ask(text)
                    text = ""
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(focused ? 0.12 : 0.07)))
        .onTapGesture {
            NSApp.windows.first { $0 is NotchPanel }?.makeKey()
            focused = true
        }
    }
}

private struct AnswerCard: View {
    @ObservedObject var ask: Ask

    var body: some View {
        switch ask.state {
        case .idle:
            EmptyView()
        case .asking(let question, let since):
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(question).lineLimit(1).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                    ElapsedText(since: since, size: 11, compact: true).foregroundStyle(.white.opacity(0.6))
                    Button { ask.cancel() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                }
                Text("Claude is searching your meetings…")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Shimmer()
            }
        case .answered(let question, let answer):
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(question).lineLimit(1).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                    Button { ask.copyAnswer() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("Copy answer")
                    Button { ask.clear() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                }
                ScrollView {
                    Text((try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, .rightToLeft)
                }
                .frame(height: 138)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
        case .failed(_, let reason):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                Spacer(minLength: 0)
                Button { ask.clear() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct Countdown: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
            Label("Stop & Save (\(left)s)", systemImage: "stop.fill")
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

/// The meeting as a running conversation: who said what, line by line, as Whisper writes it.
/// Lines arrive in batches about ten seconds behind the speech, and the header says so.
private struct LiveFeed: View {
    let entries: [Recorder.LiveEntry]
    let draft: Recorder.Draft?
    let busy: Bool
    let mode: RecordingMode
    let catchUp: () -> Void

    private var wordMode: Bool { ConfigStore.shared.wordByWord }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(busy ? Color.cyan : Color.white.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .symbolEffect(.pulse, isActive: busy)
                Text(wordMode ? "Live transcript" : busy ? "Writing down the last few seconds…" : "Live transcript")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                Text(ConfigStore.shared.liveEngine == "soniox" ? "under a second behind" : wordMode ? "about 1–2 s behind" : "about 10 s behind")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                Button(action: catchUp) {
                    Label("Catch me up", systemImage: "sparkles").font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .help("Claude sums up the last 5 minutes")
            }
            .animation(.easeInOut(duration: 0.2), value: busy)

            ScrollViewReader { reader in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 7) {
                        if entries.isEmpty {
                            Text(wordMode ? "Words show up here as people talk." : "The first lines appear about ten seconds after people start talking.")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                        ForEach(entries) { entry in
                            LiveRow(entry: entry, mode: mode)
                                .id(entry.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                        if let draft {
                            DraftRow(draft: draft).id("draft")
                        } else if busy && !entries.isEmpty && !wordMode {
                            TypingDots().frame(maxWidth: .infinity, alignment: .leading).id("typing")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: entries.count) { _, _ in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        reader.scrollTo(entries.last?.id, anchor: .bottom)
                    }
                }
                .onChange(of: draft) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("draft", anchor: .bottom) }
                }
            }
            .frame(height: 128)
            // Older lines fade out under the header instead of being cut off.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18)],
                                 startPoint: .top, endPoint: .bottom))
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: entries)
        }
    }
}

private struct LiveRow: View {
    let entry: Recorder.LiveEntry
    let mode: RecordingMode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(who)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                Text(clock)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                TypedText(text: entry.text, animate: entry.typed && Date().timeIntervalSince(entry.shownAt) < 1)
                if let translation = entry.translation {
                    Text(translation)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(accent.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, translation.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } ? .rightToLeft : .leftToRight)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(entry.mentioned ? Color.orange.opacity(0.22) : tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(entry.mentioned ? Color.orange.opacity(0.8) : .clear, lineWidth: 1))
    }

    private var who: String { Voice.label(entry.track, entry.speaker) }

    private var tint: Color { Voice.tint(entry.track, entry.speaker) }

    private var clock: String {
        let s = Int(entry.at)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Names and colours for who is talking. Soniox numbers the voices on a shared track, so a
/// room becomes Speaker 1, Speaker 2…, and several people on a call become Guest 1, Guest 2….
enum Voice {
    private static let palette: [Color] = [.cyan, .orange, .pink, .purple, .yellow, .green, .indigo]

    static func label(_ track: String, _ speaker: String?) -> String {
        switch track {
        case "me": return "Me"
        case "mark": return "★ Mark"
        case "notice": return "⏱ Time"
        case "others": return speaker.map { "Guest \($0)" } ?? "Others"
        default: return speaker.map { "Speaker \($0)" } ?? "Room"
        }
    }

    static func tint(_ track: String, _ speaker: String?) -> Color {
        switch track {
        case "me": return .mint
        case "mark": return .yellow
        case "notice": return .white.opacity(0.55)
        default:
            guard let speaker, let n = Int(speaker), n > 0 else { return track == "others" ? .cyan : .white.opacity(0.75) }
            return palette[(n - 1) % palette.count]
        }
    }
}

/// What is being said right now: confirmed words in white, the tentative tail dimmed, the way
/// it settles as Whisper becomes sure of it.
private struct DraftRow: View {
    let draft: Recorder.Draft

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Voice.label(draft.track, draft.speaker))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Voice.tint(draft.track, draft.speaker))
                PulsingDot(paused: false).scaleEffect(0.6)
            }
            .frame(width: 60, alignment: .leading)
            (Text(draft.fixed).foregroundColor(.white.opacity(0.88))
             + Text(draft.fixed.isEmpty ? "" : " ")
             + Text(draft.tentative).foregroundColor(.white.opacity(0.4)))
                .font(.system(size: 12))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .rightToLeft)
                .animation(.easeOut(duration: 0.15), value: draft)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// Reveals a line word by word. The full text sits invisibly underneath so the row has its
/// final size from the start and the feed doesn't jump while it types.
private struct TypedText: View {
    let text: String
    let animate: Bool
    var size: CGFloat = 12
    var lines = 3
    @State private var shown = 0

    private var words: [Substring] { text.split(separator: " ") }

    var body: some View {
        ZStack(alignment: .topLeading) {
            line(text).opacity(0)
            line(words.prefix(shown).joined(separator: " "))
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task(id: text) {
            guard animate else {
                shown = words.count
                return
            }
            shown = 0
            for count in 1...max(1, words.count) {
                withAnimation(.easeOut(duration: 0.12)) { shown = count }
                try? await Task.sleep(for: .seconds(Recorder.secondsPerWord))
            }
        }
    }

    private func line(_ string: String) -> some View {
        Text(string)
            .font(.system(size: size, weight: lines == 1 ? .medium : .regular))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Captions under the closed notch: the newest lines roll up like a teleprompter, typed
/// word by word, older lines fading out at the top.
private struct Teleprompter: View {
    let entries: [Recorder.LiveEntry]
    let draft: Recorder.Draft?
    let level: Float

    var body: some View {
        ZStack {
            Orb(level: level)
            captions
        }
    }

    /// Two fixed rows, like film subtitles: the line before (dim) and what is being said now
    /// (bright). Each row is one line that keeps the newest words when it's too long, and lines
    /// up on the right for Arabic, so nothing overlaps or jumps around.
    private var captions: some View {
        let now = current
        let before = previous(excluding: now)
        return VStack(spacing: 5) {
            CaptionRow(text: before?.text ?? "", tentative: "", tint: before.map { Voice.tint($0.track, $0.speaker) },
                       size: 11.5, opacity: 0.5)
            CaptionRow(text: now?.text ?? "", tentative: now?.tentative ?? "", tint: now.map { Voice.tint($0.track, $0.speaker) },
                       size: 13, opacity: 0.95)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .clipped()
    }

    private struct Line {
        let id: String
        let text: String
        var tentative = ""
        let track: String
        let speaker: String?
    }

    /// What is being said right now: the draft, or else the newest finished line.
    private var current: Line? {
        if let draft {
            return Line(id: "draft", text: draft.fixed, tentative: draft.tentative, track: draft.track, speaker: draft.speaker)
        }
        guard let last = spoken.last else { return nil }
        return Line(id: last.id.uuidString, text: last.translation ?? last.text, track: last.track, speaker: last.speaker)
    }

    private func previous(excluding now: Line?) -> Line? {
        let list = spoken
        let index = draft == nil ? list.count - 2 : list.count - 1
        guard index >= 0 else { return nil }
        let entry = list[index]
        return Line(id: entry.id.uuidString, text: entry.translation ?? entry.text, track: entry.track, speaker: entry.speaker)
    }

    /// Lines people said (marks and time notices stay in the open notch's feed).
    private var spoken: [Recorder.LiveEntry] {
        entries.filter { $0.track != "mark" && $0.track != "notice" }
    }
}

/// One subtitle row: a coloured dot for who is talking, then the words on one line.
private struct CaptionRow: View {
    let text: String
    let tentative: String
    let tint: Color?
    let size: CGFloat
    let opacity: Double

    private var arabic: Bool {
        (text + tentative).unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(tint ?? .clear).frame(width: 5, height: 5)
            (Text(text).foregroundColor(.white.opacity(opacity))
             + Text(text.isEmpty || tentative.isEmpty ? "" : " ")
             + Text(tentative).foregroundColor(.white.opacity(opacity * 0.5)))
                .font(.system(size: size, weight: size > 12 ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.head)
                .shadow(color: .black.opacity(0.7), radius: 3)
            Spacer(minLength: 0)
        }
        .frame(height: size + 6)
        .environment(\.layoutDirection, arabic ? .rightToLeft : .leftToRight)
        .animation(.easeOut(duration: 0.15), value: text + tentative)
    }
}

/// A soft glow drifting behind the captions. Three blurred blobs move on slow, different paths
/// and swell with the voice level, so the closed notch breathes with the conversation.
private struct Orb: View {
    let level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let swell = 1 + CGFloat(min(1, level * 1.4)) * 0.35
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(Color(red: 0.25, green: 0.4, blue: 1.0), size: h * 1.5 * swell,
                         x: w * (0.5 + 0.18 * sin(t * 0.45)), y: h * (0.85 + 0.12 * cos(t * 0.6)))
                    blob(Color(red: 0.55, green: 0.3, blue: 1.0), size: h * 1.2 * swell,
                         x: w * (0.5 + 0.26 * cos(t * 0.33 + 1)), y: h * (0.95 + 0.1 * sin(t * 0.5)))
                    blob(Color(red: 0.1, green: 0.75, blue: 1.0), size: h * 0.9 * swell,
                         x: w * (0.5 + 0.22 * sin(t * 0.7 + 2)), y: h * (0.8 + 0.14 * cos(t * 0.42 + 1)))
                }
                .blur(radius: h * 0.34)
                .opacity(0.8 + Double(min(1, level * 1.4)) * 0.2)
            }
            .animation(.easeOut(duration: 0.25), value: level)
        }
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size * 0.6).position(x: x, y: y)
    }
}

/// When the next calendar meeting is close enough to show in the closed notch.
@MainActor
enum NextMeeting {
    static func soon(_ meeting: CalendarWatcher.Meeting?) -> String? {
        guard let meeting else { return nil }
        let minutes = Int((meeting.start.timeIntervalSinceNow / 60).rounded(.up))
        let config = ConfigStore.shared
        guard config.showCountdown, minutes > 0, Double(minutes) <= config.countdownMinutes else { return nil }
        return "in \(minutes)m"
    }
}

/// Voice notes and spoken notes, opening from the notch on their own.
private struct VoiceCard: View {
    let card: VoiceNotes.Card
    @ObservedObject var voice: VoiceNotes

    var body: some View {
        switch card {
        case .new(let url):
            VStack(spacing: 12) {
                header(icon: "waveform.badge.mic", title: "New WhatsApp voice note", subtitle: "Transcribed here, on this Mac")
                HStack(spacing: 8) {
                    Spacer()
                    Button("Later") { voice.dismiss() }.buttonStyle(PillButtonStyle(tint: .white.opacity(0.12)))
                    Button { Task { await voice.transcribe(url) } } label: { Label("Transcribe", systemImage: "text.quote") }
                        .buttonStyle(PillButtonStyle(tint: accent))
                }
            }
        case .working(let message):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text(message).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(.top, 6)
        case .recordingNote(let since):
            HStack(spacing: 10) {
                PulsingDot(paused: false)
                Text("Listening… press ⌃⌥N again to save the note")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                ElapsedText(since: since, size: 12, compact: true)
            }
            .padding(.top, 6)
        case .result(let title, let text):
            VStack(spacing: 8) {
                HStack {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Button { voice.copy() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("Copy")
                    Button { voice.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                }
                ScrollView {
                    Text(text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, .rightToLeft)
                }
                .frame(height: 128)
                HStack(spacing: 8) {
                    Button { Task { await voice.askClaude(reply: false) } } label: { Label("Summarise", systemImage: "sparkles") }
                        .buttonStyle(PillButtonStyle(tint: .white.opacity(0.12)))
                    Button { Task { await voice.askClaude(reply: true) } } label: { Label("Suggest a reply", systemImage: "arrowshape.turn.up.left") }
                        .buttonStyle(PillButtonStyle(tint: .white.opacity(0.12)))
                    Spacer()
                }
            }
        }
    }

    private func header(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(accent).symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
    }
}

/// Three dots that bounce while Whisper is working, like someone typing.
private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .offset(y: -3 * max(0, sin(t * 6 - Double(i) * 0.7)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(0.07)))
        }
    }
}

private struct NoteField: View {
    @ObservedObject var recorder: Recorder
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            TextField("Add a note and press Return", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit {
                    recorder.mark(note: text)
                    text = ""
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(focused ? 0.12 : 0.07)))
        .onTapGesture {
            // Typing needs the panel to be the key window; it stays non-activating.
            NSApp.windows.first { $0 is NotchPanel }?.makeKey()
            focused = true
        }
    }
}

/// A star that pops out of the closed notch each time a moment is marked.
private struct StarFlash: View {
    let count: Int
    @State private var visible = false

    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.yellow)
            .scaleEffect(visible ? 1 : 0.2)
            .opacity(visible ? 1 : 0)
            .frame(width: visible ? 12 : 0)
            .onChange(of: count) { _, _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { visible = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(.easeOut(duration: 0.3)) { visible = false }
                }
            }
    }
}

private struct ProjectMenu: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        Menu {
            ForEach(recorder.projects, id: \.self) { name in
                Button {
                    recorder.project = name
                } label: {
                    if name == recorder.project { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button("New Project…") { askForProject() }
            Button("Other Names for \(recorder.project)…") { askForAliases() }
                .disabled(recorder.project == "General")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(accent)
                Text(recorder.project).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recordings and reports are grouped by project")
    }

    /// Names the calendar might use for this client: Arabic spelling, contact names, brands.
    private func askForAliases() {
        let alert = NSAlert()
        alert.messageText = "Other names for \(recorder.project)"
        alert.informativeText = "Separate with commas. When a calendar meeting's title, notes or guests contain one of these, it is filed under \(recorder.project)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = (recorder.aliases[recorder.project] ?? []).joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            recorder.setAliases(field.stringValue.components(separatedBy: CharacterSet(charactersIn: ",،")), for: recorder.project)
        }
    }

    private func askForProject() {
        let alert = NSAlert()
        alert.messageText = "New project"
        alert.informativeText = "Meetings recorded under it are compared with each other in the reports."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { recorder.addProject(field.stringValue) }
    }
}

private struct PillButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(Capsule().fill(tint))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

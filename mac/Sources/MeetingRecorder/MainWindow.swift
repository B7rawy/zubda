import AppKit
import SwiftUI

/// The main window: everything recorded, in one place. The notch stays the quick way in.
enum SidebarSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case meetings = "Meetings"
    case search = "Search"
    case voice = "Voice notes"
    case notes = "Notes"
    case clients = "Clients"
    case ask = "Ask Claude"
    case settings = "Settings"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "square.grid.2x2"
        case .meetings: "person.2.wave.2"
        case .search: "text.magnifyingglass"
        case .voice: "waveform"
        case .notes: "note.text"
        case .clients: "folder"
        case .ask: "sparkles"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }

    /// Sidebar groups: what you recorded, then tools, then settings.
    static let library: [SidebarSection] = [.home, .meetings, .search, .voice, .notes]
    static let workspace: [SidebarSection] = [.clients, .ask]
}

let brand = Color(red: 1.0, green: 0.27, blue: 0.23)
/// One corner radius for everything inside the window.
let radius: CGFloat = 8

extension View {
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct MainView: View {
    @ObservedObject var library: Library
    @ObservedObject var recorder: Recorder
    @ObservedObject var calendar: CalendarWatcher
    @ObservedObject var ui: NotchUI
    @ObservedObject var voice: VoiceNotes
    @ObservedObject var ask: Ask
    @ObservedObject var config = ConfigStore.shared
    @ObservedObject var nav = Navigator.shared
    @AppStorage("sidebarCollapsed") private var collapsed = false

    private var section: SidebarSection { nav.section }

    /// Pages that fill the window themselves instead of scrolling as a column.
    private var fullHeight: Bool { section == .search || (section == .meetings && nav.meeting != nil) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                TopBar(title: section.rawValue, recorder: recorder) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { collapsed.toggle() }
                }
                Divider().opacity(0.6)
                if fullHeight {
                    page.padding(.horizontal, 28).padding(.vertical, 20)
                } else {
                    ScrollView {
                        page
                            .frame(maxWidth: 1000, alignment: .leading)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 28)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .padding([.vertical, .trailing], 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 960, minHeight: 640)
        .onAppear { library.reload() }
        .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { _ in library.reload() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                if !collapsed {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Zubda").font(.system(size: 13.5, weight: .semibold))
                        Text(recorder.phase == .recording ? "Recording now" : "Ready")
                            .font(.system(size: 11)).foregroundStyle(recorder.phase == .recording ? brand : .secondary)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, collapsed ? 8 : 10)
            .padding(.top, 44)
            .padding(.bottom, 20)

            group("Library", SidebarSection.library)
            group("Workspace", SidebarSection.workspace).padding(.top, 14)

            Spacer()
            if !collapsed { SetupChecklist(config: config, calendar: calendar).transition(.opacity) }
            item(.about).padding(.top, 8)
            item(.settings)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
        .frame(width: collapsed ? 64 : 228)
        .clipped()
    }

    private func group(_ title: String, _ items: [SidebarSection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if collapsed {
                Divider().padding(.horizontal, 8).padding(.bottom, 6).opacity(title == "Library" ? 0 : 1)
            } else {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
            ForEach(items) { item($0) }
        }
    }

    private func item(_ entry: SidebarSection) -> some View {
        let selected = section == entry
        return Button {
            nav.section = entry
            if entry != .meetings { nav.meeting = nil }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: collapsed ? 15 : 13, weight: .medium))
                    .foregroundStyle(selected ? brand : .secondary)
                    .frame(width: collapsed ? 24 : 18)
                if !collapsed {
                    Text(entry.rawValue).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    Spacer()
                }
                if !collapsed, let count = count(for: entry), count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                }
            }
            .padding(.horizontal, collapsed ? 10 : 10)
            .padding(.vertical, collapsed ? 9 : 7)
            .background(RoundedRectangle(cornerRadius: radius).fill(selected ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.rawValue)
    }

    private func count(for entry: SidebarSection) -> Int? {
        switch entry {
        case .meetings: library.meetings.count
        case .voice: library.voiceNotes.count
        case .notes: library.notes.count
        default: nil
        }
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch section {
        case .home: HomePage(library: library, recorder: recorder, calendar: calendar, open: { nav.section = $0 })
        case .meetings:
            if let folder = nav.meeting, let meeting = library.meetings.first(where: { $0.folder == folder }) ?? Library.meeting(folder) {
                MeetingDetail(meeting: meeting) { nav.meeting = nil }
                    .id(meeting.id)
            } else {
                MeetingsPage(library: library)
            }
        case .search: SearchPage()
        case .settings: SettingsView(recorder: recorder, ui: ui, voice: voice, embedded: true).frame(maxWidth: .infinity, alignment: .leading)
        case .voice: VoicePage(library: library, voice: voice)
        case .notes: NotesPage(library: library, voice: voice)
        case .clients: ClientsPage(library: library, recorder: recorder)
        case .ask: AskPage(ask: ask, recorder: recorder)
        case .about: AboutPage(library: library)
        }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    let title: String
    @ObservedObject var recorder: Recorder
    let toggleSidebar: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleSidebar) { Image(systemName: "sidebar.left").font(.system(size: 14)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Show or hide the sidebar labels")
                .keyboardShortcut("s", modifiers: [.command, .control])
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            if recorder.phase == .recording, let start = recorder.startedAt {
                HStack(spacing: 6) {
                    Circle().fill(brand).frame(width: 7, height: 7)
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        let s = Int(context.date.timeIntervalSince(start))
                        Text(String(format: "%02d:%02d", s / 60, s % 60)).monospacedDigit()
                    }
                    Button("Stop") { Task { await recorder.stop() } }
                }
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: radius).fill(brand.opacity(0.12)))
            } else {
                Menu {
                    Button("Online meeting") { Task { await recorder.start(.online) } }
                    Button("In-person meeting") { Task { await recorder.start(.room) } }
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .disabled(recorder.isBusy)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 50)
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var library: Library
    @ObservedObject var recorder: Recorder
    @ObservedObject var calendar: CalendarWatcher
    @ObservedObject var config = ConfigStore.shared
    let open: (SidebarSection) -> Void
    @State private var filter = "All"

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.system(size: 24, weight: .semibold))
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                hero
                statsGrid.frame(width: 300)
            }
            .frame(height: 196)

            ClaudeCard(recorder: recorder)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Recent activity").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Picker("", selection: $filter) {
                        ForEach(["All", "Meetings", "Voice", "Notes"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
                if groups.isEmpty {
                    Text("Nothing here yet. Hover over the notch or press Record to start.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90).card()
                }
                ForEach(groups, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(dayTitle(group.day))
                            .font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.prefix(10).enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().padding(.leading, 56) }
                                ActivityRow(item: item)
                            }
                        }
                        .card()
                    }
                }
            }
        }
    }

    private var groups: [(day: Date, items: [Library.Activity])] {
        library.activityByDay.prefix(8).compactMap { group in
            let items = group.items.filter { item in
                switch (filter, item) {
                case ("All", _), ("Meetings", .meeting), ("Voice", .voice), ("Notes", .note): true
                default: false
                }
            }
            return items.isEmpty ? nil : (group.day, items)
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "TODAY" }
        if Calendar.current.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()
    }

    private var greeting: String {
        let name = config.userName.isEmpty ? "" : ", \(config.userName.components(separatedBy: " ")[0])"
        let hour = Calendar.current.component(.hour, from: Date())
        return (hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening") + name
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black)
            GlowField().clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                if let next = calendar.current ?? calendar.next {
                    Label(calendar.current == nil ? "Up next" : "Happening now", systemImage: "calendar")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                    Text(next.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(next.start.formatted(date: .omitted, time: .shortened)
                         + (next.attendees.count > 1 ? " · \(next.attendees.count) people" : ""))
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                } else {
                    Label(calendar.access == .granted ? "No meetings coming up" : "Calendar not connected",
                          systemImage: "calendar")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                    Text("Start a recording").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    Text("Transcribed on this Mac, then summarised by Claude.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    heroButton("Record online", icon: "video.fill", filled: true) { Task { await recorder.start(.online) } }
                    heroButton("In person", icon: "person.2.fill", filled: false) { Task { await recorder.start(.room) } }
                }
                .disabled(recorder.isBusy)
            }
            .padding(22)
        }
    }

    private func heroButton(_ title: String, icon: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: radius).fill(filled ? brand : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private var statsGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            StatTile(icon: "person.2.wave.2", value: "\(library.meetings.count)", label: "Meetings")
            StatTile(icon: "clock", value: hours, label: "Recorded")
            StatTile(icon: "star", value: "\(library.totalMarks)", label: "Marked moments")
            StatTile(icon: "waveform", value: "\(library.voiceNotes.count + library.notes.count)", label: "Voice & notes")
        }
    }

    private var hours: String {
        let m = library.totalMinutes
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

private struct StatTile: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(brand)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 93, alignment: .topLeading)
        .card()
    }
}

private struct ActivityRow: View {
    let item: Library.Activity
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: radius).fill(tint.opacity(0.12))
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let badge { Badge(text: badge.0, color: badge.1) }
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    if let meta { Text(meta).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .opacity(isMeeting ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(hovering && isMeeting ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var isMeeting: Bool {
        if case .meeting = item { return true }
        return false
    }

    private var icon: String {
        switch item {
        case .meeting(let m): m.inPerson ? "person.2.fill" : "video.fill"
        case .voice: "waveform"
        case .note: "note.text"
        }
    }

    private var tint: Color {
        switch item {
        case .meeting: brand
        case .voice: .green
        case .note: .orange
        }
    }

    private var title: String {
        switch item {
        case .meeting(let m): m.client == "General" ? m.title : "\(m.client) · \(m.title)"
        case .voice: "WhatsApp voice note"
        case .note: "Spoken note"
        }
    }

    private var badge: (String, Color)? {
        guard case .meeting(let m) = item else { return nil }
        if m.recording { return ("Recording", brand) }
        if m.hasReport { return ("Report", .green) }
        if m.hasTranscript { return ("Transcript", .blue) }
        return ("Processing", .orange)
    }

    private var meta: String? {
        switch item {
        case .meeting(let m):
            let parts = [m.minutes > 0 ? "\(m.minutes) min" : "< 1 min", m.marks > 0 ? "\(m.marks) ★" : nil]
            return parts.compactMap { $0 }.joined(separator: " · ")
        case .voice(let v):
            return v.length.isEmpty ? nil : v.length
        case .note:
            return nil
        }
    }

    /// One clean line: the first sentence of the summary, without Markdown leftovers.
    private var detail: String {
        let raw: String
        switch item {
        case .meeting(let m): raw = m.summary
        case .voice(let v): raw = v.text
        case .note(let n): raw = n.text
        }
        let cleaned = raw.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
        let sentence = cleaned.split(whereSeparator: { ".؟?!".contains($0) }).first.map(String.init) ?? cleaned
        return sentence.trimmingCharacters(in: .whitespaces)
    }

    private func open() {
        guard case .meeting(let m) = item else { return }
        Navigator.shared.open(meeting: m.folder)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
    }
}

// MARK: - Meetings

private struct MeetingsPage: View {
    @ObservedObject var library: Library
    @State private var search = ""
    @State private var client = Navigator.shared.clientFilter ?? "All"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search titles and summaries", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: 320)
                .card()
                Spacer()
                Button { AppDelegate.importRecording() } label: { Label("Import recording", systemImage: "square.and.arrow.down") }
                Button { Navigator.shared.openSearch() } label: { Label("Search every word", systemImage: "text.magnifyingglass") }
                    .onAppear { Navigator.shared.clientFilter = nil }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["All"] + library.clients, id: \.self) { name in
                        Button(name) { client = name }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(client == name ? .white : .primary)
                            .background(RoundedRectangle(cornerRadius: radius).fill(client == name ? brand : Color.primary.opacity(0.06)))
                    }
                }
            }
            if filtered.isEmpty {
                Text("No meetings match.").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90).card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, meeting in
                        if index > 0 { Divider().padding(.leading, 56) }
                        ActivityRow(item: .meeting(meeting))
                    }
                }
                .card()
            }
        }
    }

    private var filtered: [Library.Meeting] {
        library.meetings.filter { m in
            (client == "All" || m.client == client)
                && (search.isEmpty || (m.title + " " + m.summary + " " + m.client).localizedCaseInsensitiveContains(search))
        }
    }
}

private struct ComingNext: View {
    let section: SidebarSection

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: section.icon).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("\(section.rawValue) is coming in the next step").font(.system(size: 14, weight: .medium))
            Text("For now it's in the notch and Settings.").font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .card()
    }
}

// MARK: - Pieces

/// The setup steps still to do, shown above Settings until all are done.
private struct SetupChecklist: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject var calendar: CalendarWatcher

    var body: some View {
        let steps: [(String, Bool)] = [
            ("Your name and language", !config.userName.isEmpty),
            ("Connect your calendar", calendar.access == .granted),
            ("Connect Claude", config.claudeConnected),
        ]
        if steps.contains(where: { !$0.1 }) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Finish setting up").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(steps.filter(\.1).count)/\(steps.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(steps.filter(\.1).count), total: Double(steps.count)).tint(brand)
                ForEach(steps, id: \.0) { step in
                    HStack(spacing: 7) {
                        Image(systemName: step.1 ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11.5)).foregroundStyle(step.1 ? .green : .secondary)
                        Text(step.0).font(.system(size: 11.5)).foregroundStyle(step.1 ? .secondary : .primary)
                    }
                }
                Button("Continue setup") { AppDelegate.showOnboarding() }
                    .font(.system(size: 11.5, weight: .medium))
                    .buttonStyle(.plain).foregroundStyle(brand)
            }
            .padding(12)
            .card()
        }
    }
}

/// Slow drifting glow for the dark hero card, the same family as the notch's captions.
private struct GlowField: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Circle().fill(Color(red: 1.0, green: 0.3, blue: 0.25)).frame(width: h * 1.1)
                        .position(x: w * (0.8 + 0.07 * sin(t * 0.3)), y: h * (0.55 + 0.15 * cos(t * 0.4)))
                    Circle().fill(Color(red: 0.45, green: 0.3, blue: 1.0)).frame(width: h * 0.9)
                        .position(x: w * (0.62 + 0.1 * cos(t * 0.25 + 1)), y: h * (0.9 + 0.1 * sin(t * 0.35)))
                    Circle().fill(Color(red: 0.1, green: 0.7, blue: 1.0)).frame(width: h * 0.7)
                        .position(x: w * (0.95 + 0.05 * sin(t * 0.45 + 2)), y: h * (0.2 + 0.12 * cos(t * 0.3 + 1)))
                }
                .blur(radius: h * 0.34)
                .opacity(0.7)
            }
        }
        .allowsHitTesting(false)
    }
}

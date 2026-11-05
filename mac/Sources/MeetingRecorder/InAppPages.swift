import AppKit
import SwiftUI
import WebKit

/// Where the main window should go. Anything in the app that used to open a page in the
/// browser asks this instead, so reports, transcripts and search stay inside the app.
@MainActor
final class Navigator: ObservableObject {
    static let shared = Navigator()
    @Published var section: SidebarSection = .home
    /// The meeting open in the main window, if any.
    @Published var meeting: URL?
    /// Client to filter the meetings list by, set from the Clients page.
    @Published var clientFilter: String?
    /// Seconds to open the meeting's transcript at (from Spotlight), used once.
    var jump: Double?

    func open(meeting folder: URL) {
        meeting = folder
        section = .meetings
        AppDelegate.showMain()
    }

    func openSearch() {
        meeting = nil
        section = .search
        AppDelegate.showMain()
    }
}

/// A report, transcript or archive page rendered inside the app. Links between our own pages
/// stay inside; anything else (there shouldn't be any) is refused.
struct PageView: NSViewRepresentable {
    let url: URL
    /// Folder the page may read from (its audio file, other meetings for the archive).
    let access: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadFileURL(url, allowingReadAccessTo: access)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url?.standardizedFileURL != url.standardizedFileURL {
            view.loadFileURL(url, allowingReadAccessTo: access)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(folder: access) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let folder: URL
        init(folder: URL) { self.folder = folder }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == "mrclip", let seconds = Double(url.absoluteString.dropFirst("mrclip:".count)) {
                await Clips.share(folder: folder, at: seconds, from: webView)
                return .cancel
            }
            return url.isFileURL ? .allow : .cancel
        }
    }
}

/// One meeting inside the main window: report or transcript, with the player built into the page.
struct MeetingDetail: View {
    let meeting: Library.Meeting
    let back: () -> Void
    @State private var tab = Navigator.shared.jump == nil ? "Report" : "Transcript"
    @State private var jump = Navigator.shared.jump
    @State private var naming = false
    @State private var voices: [String] = []
    /// Bumped after renaming so the page reloads with the names.
    @State private var version = 0

    private var page: URL? {
        let name = tab == "Report" ? "report.html" : "transcript.html"
        let url = meeting.folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(action: back) { Label("Meetings", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $tab) {
                    Text("Report").tag("Report")
                    Text("Transcript").tag("Transcript")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                if !voices.isEmpty {
                    Button { naming = true } label: { Label("Name speakers", systemImage: "person.2") }
                }
                Button { AppDelegate.showEditor(folder: meeting.folder) } label: { Label("Edit transcript", systemImage: "pencil") }
                    .disabled(!meeting.hasTranscript)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.client == "General" ? meeting.title : "\(meeting.client) · \(meeting.title)")
                    .font(.system(size: 20, weight: .semibold))
                Text([meeting.started?.formatted(date: .abbreviated, time: .shortened),
                      meeting.minutes > 0 ? "\(meeting.minutes) min" : nil,
                      meeting.inPerson ? "In person" : "Online",
                      meeting.marks > 0 ? "\(meeting.marks) marked" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            if let page {
                PageView(url: tab == "Transcript" ? page.withMoment(jump) : page, access: meeting.folder)
                    .id("\(page.path)-\(version)")
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "hourglass").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text(tab == "Report" ? "The report isn't ready yet." : "The transcript isn't ready yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            voices = Promises.voices(meeting.folder)
            Navigator.shared.jump = nil
        }
        .sheet(isPresented: $naming) {
            NameSpeakers(voices: voices) { names in
                naming = false
                guard !names.isEmpty else { return }
                Task {
                    _ = await Transcriber.renameSpeakers(folder: meeting.folder, names: names)
                    voices = Promises.voices(meeting.folder)
                    version += 1
                }
            }
        }
    }
}

/// Who each numbered voice is. Leave a field empty to keep the number.
private struct NameSpeakers: View {
    let voices: [String]
    let done: ([String: String]) -> Void
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who is who?").font(.system(size: 16, weight: .semibold))
            Text("The names replace the numbers in the transcript and the report.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(voices, id: \.self) { voice in
                HStack {
                    Text(voice).frame(width: 90, alignment: .leading)
                        .environment(\.layoutDirection, .rightToLeft)
                    TextField("Name", text: Binding(get: { names[voice] ?? "" }, set: { names[voice] = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { done([:]) }.keyboardShortcut(.cancelAction)
                Button("Save") { done(names.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Search every word ever said, using the archive page, inside the app.
struct SearchPage: View {
    @State private var ready = false

    var body: some View {
        Group {
            if ready {
                PageView(url: Recorder.meetingsFolder.appendingPathComponent("index.html"), access: Recorder.meetingsFolder)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            } else {
                ProgressView("Building the index…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await Transcriber.buildArchive()
            ready = true
        }
    }
}

private extension URL {
    /// The page opened at a moment: render.py's player reads #t= and shows that line.
    func withMoment(_ seconds: Double?) -> URL {
        guard let seconds, var parts = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        parts.fragment = "t=\(Int(seconds))"
        return parts.url ?? self
    }
}

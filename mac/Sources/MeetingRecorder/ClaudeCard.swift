import AppKit
import SwiftUI

/// Home's Claude card: is Claude connected, and questions that open in Claude Desktop itself
/// (a test question first), so the user sees their own Claude read the meetings.
struct ClaudeCard: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var config = ConfigStore.shared
    @State private var desktop = ConfigStore.claudeDesktopConnected
    @State private var code = ConfigStore.claudeCodeConnected
    @State private var connecting = false

    static let testPrompt = "استخدم Zubda وقولّي في سطرين: شايف كام ميتنج، وآخر ميتنج كان مع مين وإمتى وكان عن إيه."

    private var prompts: [String] {
        var list = ["لخصلي آخر ميتنج", "إيه الوعود اللي عليّا الأسبوع ده؟", "العميل طلب إيه في آخر ٣ ميتنجات؟"]
        if recorder.phase == .recording { list.insert("تابع الميتنج اللي شغال دلوقتي وقولّي أهم حاجة اتقالت", at: 0) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.orange.opacity(0.15))
                    Image(systemName: "sparkles").foregroundStyle(.orange).font(.system(size: 16, weight: .semibold))
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude").font(.system(size: 15, weight: .semibold))
                    Text("Claude reads your meetings, even one that's still going.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                status("Claude Desktop", desktop)
                status("Claude Code", code)
                if !desktop || !code {
                    Button(connecting ? "Connecting…" : "Connect") { connect() }.disabled(connecting)
                }
                Button {
                    send(Self.testPrompt)
                } label: {
                    Label("Test in Claude Desktop", systemImage: "checkmark.bubble")
                }
                .help("Opens Claude Desktop with a question about your meetings; press Return there")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("ASK CLAUDE DESKTOP").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                FlowRow(spacing: 8) {
                    ForEach(prompts, id: \.self) { prompt in
                        Button { send(prompt) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(prompt).font(.system(size: 12.5))
                            }
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Capsule().fill(prompt.hasPrefix("تابع") ? brand.opacity(0.18) : Color.primary.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(prompt.hasPrefix("تابع") ? brand.opacity(0.5) : .clear))
                            .environment(\.layoutDirection, .rightToLeft)
                        }
                        .buttonStyle(.plain)
                        .help("Opens a new chat in Claude Desktop with this question; press Return there")
                    }
                }
                Text("Opens a new chat in Claude Desktop with the question written; press Return to send.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .card()
        .onAppear(perform: refresh)
        // Coming back from Claude Desktop after clicking Install on the extension.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func status(_ name: String, _ on: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(on ? .primary : .secondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .help(on ? "\(name) can read your meetings" : "\(name) isn't connected yet")
    }

    private func refresh() {
        desktop = ConfigStore.claudeDesktopConnected
        code = ConfigStore.claudeCodeConnected
    }

    private func connect() {
        connecting = true
        Task {
            _ = await Transcriber.connectClaude()
            refresh()
            connecting = false
        }
    }

    /// A new Claude Desktop chat with the question already written (its claude:// link); the
    /// user reads it and presses Return, so nothing is sent without them.
    private func send(_ prompt: String) {
        var parts = URLComponents(string: "claude://claude.ai/new")!
        parts.queryItems = [URLQueryItem(name: "q", value: prompt)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }
}

/// Lays chips out left to right and wraps them onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

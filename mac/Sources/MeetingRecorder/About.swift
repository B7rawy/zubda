import AppKit
import SwiftUI

/// About: the app, the person who made it, and what is stored on this Mac.
struct AboutPage: View {
    @ObservedObject var library: Library
    @ObservedObject var config = ConfigStore.shared
    @State private var storage: String = "…"

    static let repo = URL(string: "https://github.com/B7rawy/zubda")!
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            HStack(alignment: .top, spacing: 16) {
                maker
                yourData
            }
            privacy
            built
        }
        .task { storage = await Self.size(of: Recorder.meetingsFolder) }
    }

    // MARK: Sections

    private var hero: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 76, height: 76)
                .shadow(color: brand.opacity(0.35), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 5) {
                Text("Zubda").font(.system(size: 26, weight: .bold))
                Text("The bottom line of every meeting. Records it, writes down every word, and lets Claude understand it. Free and open source.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Pill(text: "Version \(version)")
                    Pill(text: "MIT licence")
                    Pill(text: "macOS · Apple silicon")
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                LinkButton(title: "Source code", icon: "chevron.left.forwardslash.chevron.right", url: Self.repo, primary: true)
                LinkButton(title: "Report a problem", icon: "exclamationmark.bubble",
                           url: Self.repo.appendingPathComponent("issues"))
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [brand.opacity(0.16), brand.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(brand.opacity(0.22)))
    }

    private var maker: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Made by")
            HStack(spacing: 14) {
                Group {
                    if let photo = NSImage(contentsOf: Paths.script("assets/maker.jpg")) {
                        Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(colors: [brand, brand.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                            Text("KE").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 64, height: 64, alignment: .top)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(brand.opacity(0.5), lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Kareem Elbhrawy").font(.system(size: 16, weight: .semibold))
                    Text("Full-stack & AI developer · Cairo").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("I built this for my own client meetings in Egyptian and Gulf Arabic, then made it free for everyone. If it helps you, say hi.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                LinkRow(icon: "globe", title: "kareemelbhrawy.com", url: URL(string: "https://kareemelbhrawy.com")!)
                LinkRow(icon: "chevron.left.forwardslash.chevron.right", title: "github.com/B7rawy", url: URL(string: "https://github.com/B7rawy")!)
                LinkRow(icon: "person.crop.square", title: "linkedin.com/in/b7rawy", url: URL(string: "https://linkedin.com/in/b7rawy")!)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private var yourData: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Your data")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                Stat(value: "\(library.meetings.count)", label: "Meetings")
                Stat(value: hours, label: "Recorded")
                Stat(value: "\(library.clients.filter { $0 != "General" }.count)", label: "Clients")
                Stat(value: "\(library.totalMarks)", label: "Marked moments")
                Stat(value: "\(library.voiceNotes.count)", label: "Voice notes")
                Stat(value: "\(library.notes.count)", label: "Notes")
            }
            HStack(spacing: 10) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(storage + " on this Mac").font(.system(size: 12.5, weight: .medium))
                    Text(Recorder.meetingsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Recorder.meetingsFolder]) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Where your meetings go")
            HStack(alignment: .top, spacing: 12) {
                Fact(icon: "lock.fill", tint: .green, title: "Audio stays here",
                     detail: "Recordings are saved in your folder above. Nothing is uploaded to us; there is no server.")
                Fact(icon: config.liveEngine == "soniox" ? "cloud.fill" : "cpu", tint: config.liveEngine == "soniox" ? .orange : .green,
                     title: config.liveEngine == "soniox" ? "Live text: Soniox" : "Transcribed on this Mac",
                     detail: config.liveEngine == "soniox"
                        ? "While recording, audio streams to Soniox with your own key. Change it in Settings → Recording."
                        : "Whisper runs on this Mac's chip. No audio leaves it.")
                Fact(icon: "sparkles", tint: .purple, title: "Reports: your Claude",
                     detail: config.claudeConnected
                        ? "Reports are written by your own Claude account, and Claude can read your meetings."
                        : "Reports are written by your own Claude account. Connect Claude in Settings to ask it about meetings.")
            }
        }
        .padding(18)
        .card()
    }

    private var built: some View {
        HStack(spacing: 16) {
            Text("Built with").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(["Swift & SwiftUI", "Whisper (MLX)", "Soniox", "Claude", "sherpa-onnx"], id: \.self) { Pill(text: $0) }
            Spacer()
            Text("Made in Cairo").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    private var hours: String {
        let minutes = library.totalMinutes
        return minutes >= 60 ? String(format: "%.1f h", Double(minutes) / 60) : "\(minutes) min"
    }

    private static func size(of folder: URL) async -> String {
        await Task.detached(priority: .utility) {
            var total: Int64 = 0
            if let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
                while let url = items.nextObject() as? URL {
                    total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }.value
    }
}

// MARK: Pieces

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

private struct Pill: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

private struct Fact: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 15))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.03)))
    }
}

private struct LinkRow: View {
    let icon: String
    let title: String
    let url: URL
    @State private var hover = false
    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(brand)
                Text(title).font(.system(size: 12.5))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct LinkButton: View {
    let title: String
    let icon: String
    let url: URL
    var primary = false
    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 150).padding(.vertical, 7)
                .foregroundStyle(primary ? .white : .primary)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(primary ? brand : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

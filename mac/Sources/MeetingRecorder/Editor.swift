import AppKit
import SwiftUI

/// Fix words Whisper got wrong. Saving re-renders the page; "Save & redo report" also asks
/// Claude for a fresh report from the corrected text.
struct TranscriptEditor: View {
    let folder: URL
    @State private var text = ""
    @State private var original = ""
    @State private var status: String?
    @State private var working = false

    private var file: URL { folder.appendingPathComponent("transcript.md") }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.lastPathComponent).font(.system(size: 13, weight: .semibold))
                    Text("Fix names or words, keep the [time] and speaker at the start of each line.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .environment(\.layoutDirection, .rightToLeft)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                if let status { Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Save") { save(redoReport: false) }
                    .disabled(text == original || working)
                Button("Save & redo report") { save(redoReport: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 520)
        .onAppear {
            text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            original = text
        }
    }

    private func save(redoReport: Bool) {
        try? text.write(to: file, atomically: true, encoding: .utf8)
        original = text
        working = true
        status = redoReport ? "Claude is rewriting the report…" : "Saved."
        Task {
            await Transcriber.render(folder.appendingPathComponent("transcript.md"))
            if redoReport {
                for name in ["report.md", "report.html"] {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                }
                let wrote = await Transcriber.writeReport(folder: folder)
                status = wrote ? "Report rewritten from the corrected transcript." : "Couldn't write the report (is claude logged in?)."
                if wrote { Navigator.shared.open(meeting: folder) }
            }
            working = false
        }
    }
}

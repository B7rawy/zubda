import Foundation
import Translation

/// Wraps Apple's on-device Translation. Needs the language pair downloaded in
/// System Settings → General → Language & Region → Translation Languages.
@available(macOS 26.0, *)
enum TranslationBridge {
    @MainActor private static var sessions: [String: TranslationSession] = [:]

    @MainActor
    static func translate(_ text: String, from source: String, to target: String,
                          missing: (Bool) -> Void) async -> String? {
        let key = "\(source)>\(target)"
        let session = sessions[key] ?? TranslationSession(
            installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target)
        )
        sessions[key] = session
        do {
            let response = try await session.translate(text)
            missing(false)
            return response.targetText
        } catch {
            missing(true)
            sessions[key] = nil
            return nil
        }
    }
}

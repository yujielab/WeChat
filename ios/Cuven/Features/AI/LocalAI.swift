import SwiftUI
import Speech
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device intelligence (Apple Machine Learning: the Foundation
/// Models framework and Speech): reply ideas, finishing a half-written
/// message, a conversation's summary and voice messages as text, all worked
/// out on the iPhone. Nothing is sent anywhere for them. Where the device or
/// region has no Apple Intelligence model, these quietly aren't offered.
@MainActor
enum LocalAI {
    /// The on-device language model is ready (a supported device, Apple
    /// Intelligence on, the model downloaded).
    static var available: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    /// The model's context is small: only the latest few thousand characters go in.
    private static func clipped(_ lines: [String], limit: Int = 2800) -> String {
        var out: [String] = []
        var total = 0
        for line in lines.reversed() {
            total += line.count + 1
            if total > limit { break }
            out.append(line)
        }
        return out.reversed().joined(separator: "\n")
    }

    /// Up to three short replies to the end of a conversation ("Me:" / "Them:" lines).
    static func replies(to lines: [String]) async -> [String] {
        #if canImport(FoundationModels)
        guard available, !lines.isEmpty else { return [] }
        let session = LanguageModelSession(instructions: """
            You suggest replies in a chat app. Write in the language the conversation uses. \
            Each reply is short and natural, the way a friend would text; no greetings or sign-offs, \
            no emoji unless the conversation uses them.
            """)
        let prompt = "Conversation, oldest first:\n\(clipped(lines))\n\nSuggest three different replies \"Me\" could send next."
        do {
            let r = try await session.respond(to: prompt, generating: ReplyIdeas.self)
            return Array(r.content.replies
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”")) }
                .filter { !$0.isEmpty && $0.count <= 80 }
                .prefix(3))
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// The rest of a half-written message: a few words, in its language.
    static func continuation(of draft: String, after lines: [String]) async -> String {
        #if canImport(FoundationModels)
        guard available, !draft.isEmpty else { return "" }
        let session = LanguageModelSession(instructions: """
            You finish the user's half-written chat message. Answer with only the words that come next \
            (a few words, at most the end of the sentence), in the same language and tone. \
            Never repeat what is already written; no quotes.
            """)
        let prompt = "Recent messages:\n\(clipped(lines, limit: 1500))\n\nThe user has written so far: \(draft)"
        do {
            let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3))
            return r.content.trimmingCharacters(in: .newlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        } catch {
            return ""
        }
        #else
        return ""
        #endif
    }

    /// A few short points on what a conversation has been about.
    static func summary(of lines: [String]) async -> String? {
        #if canImport(FoundationModels)
        guard available, !lines.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: """
            You summarise chat conversations for one of the people in them, briefly and neutrally, \
            in the language the conversation uses: two to four short bullet points ("• "), \
            plans and questions still open first.
            """)
        do {
            let r = try await session.respond(to: "Summarise this conversation:\n\(clipped(lines, limit: 3200))")
            return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The lines a conversation's prompt is made of: its latest text messages.
    static func lines(_ messages: [Message], me: String?, names: (String) -> String) -> [String] {
        messages.suffix(40).compactMap { m in
            guard !m.isRevoked else { return nil }
            let who = m.sender == me ? "Me" : names(m.sender)
            switch m.type {
            case "text": return "\(who): \(m.body)"
            case "location": return "\(who): [shared a place: \(m.meta?.name ?? "")]"
            case "image", "video", "drawing", "sticker", "voice": return "\(who): [\(m.type)]"
            default: return nil
            }
        }
    }
}

#if canImport(FoundationModels)
@Generable
struct ReplyIdeas {
    @Guide(description: "Three different short replies, each under twelve words, in the conversation's language.")
    var replies: [String]
}
#endif

// MARK: - Voice messages as text

/// Voice messages turned into words on the device (Speech, on-device
/// recognition where the language has it), kept for this session.
@MainActor
@Observable
final class Transcripts {
    static let shared = Transcripts()
    var text: [String: String] = [:]
    var working: Set<String> = []
    var failed: Set<String> = []

    func transcribe(_ m: Message) {
        guard text[m.id] == nil, !working.contains(m.id), let url = m.meta?.url else { return }
        failed.remove(m.id)
        working.insert(m.id)
        Task {
            let words = await Self.recognise(path: url, type: m.meta?.type)
            working.remove(m.id)
            if let words, !words.isEmpty {
                withAnimation(Motion.ui) { text[m.id] = words }
            } else {
                failed.insert(m.id)
            }
        }
    }

    private static func recognise(path: String, type: String?) async -> String? {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized, let data = await ImageStore.shared.data(path) else { return nil }
        let ext = (type ?? "").contains("webm") ? "webm" : ((type ?? "").contains("wav") ? "wav" : "m4a")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: file)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        guard let recognizer, recognizer.isAvailable else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        // On the device where the language allows it: nothing leaves the iPhone.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return await withCheckedContinuation { c in
            recognizer.recognitionTask(with: request) { result, error in
                if once.done { return }
                if let result, result.isFinal {
                    once.done = true
                    c.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    once.done = true
                    c.resume(returning: nil)
                }
            }
        }
    }
}

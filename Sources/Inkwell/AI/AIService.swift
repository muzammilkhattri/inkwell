import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AISummary: Hashable { var text: String; var actions: [String] }

enum AIError: LocalizedError {
    case notConfigured, missingKey, refused(String), http(Int, String), unavailable(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Turn on an AI model in Settings → AI."
        case .missingKey: return "Add your API key in Settings → AI."
        case .refused(let s): return "The model declined: \(s)"
        case .http(let c, let s): return "AI request failed (\(c)): \(s)"
        case .unavailable(let s): return s
        }
    }
}

/// Summaries, suggested replies and rewrites using the provider picked in Settings → AI.
enum AIService {
    @MainActor static var keyName: String { "ai-key-\(MailStore.shared.settings.aiProvider.rawValue)" }

    @MainActor static var isEnabled: Bool { MailStore.shared.settings.aiProvider != .off }

    @MainActor
    static func complete(system: String, prompt: String, maxTokens: Int = 2048) async throws -> String {
        let s = MailStore.shared.settings
        let model = s.aiModel.isEmpty ? s.aiProvider.defaultModel : s.aiModel
        let key = Keychain.get("ai-key-\(s.aiProvider.rawValue)") ?? ""
        switch s.aiProvider {
        case .off: throw AIError.notConfigured
        case .apple: return try await apple(system: system, prompt: prompt)
        case .anthropic:
            guard !key.isEmpty else { throw AIError.missingKey }
            return try await anthropic(key: key, model: model, system: system, prompt: prompt, maxTokens: maxTokens)
        case .openai:
            guard !key.isEmpty else { throw AIError.missingKey }
            return try await openAICompatible(base: "https://api.openai.com/v1", key: key, model: model, system: system, prompt: prompt)
        case .openrouter:
            guard !key.isEmpty else { throw AIError.missingKey }
            return try await openAICompatible(base: "https://openrouter.ai/api/v1", key: key, model: model, system: system, prompt: prompt)
        case .ollama:
            return try await openAICompatible(base: "http://localhost:11434/v1", key: nil, model: model, system: system, prompt: prompt)
        case .lmstudio:
            return try await openAICompatible(base: "http://localhost:1234/v1", key: nil, model: model, system: system, prompt: prompt)
        }
    }

    // MARK: providers

    /// Claude Messages API over raw HTTP (no official Swift SDK).
    private static func anthropic(key: String, model: String, system: String, prompt: String, maxTokens: Int) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        if model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5") || model.hasPrefix("claude-fable") {
            // Email tasks are light: keep effort low for speed/cost. Server-side fallback on refusals.
            body["output_config"] = ["effort": "low"]
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.http(status, "bad response") }
        guard status == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data, as: UTF8.self)
            throw AIError.http(status, msg)
        }
        if json["stop_reason"] as? String == "refusal" {
            let details = (json["stop_details"] as? [String: Any])?["explanation"] as? String ?? "refusal"
            throw AIError.refused(details)
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    private static func openAICompatible(base: String, key: String?, model: String, system: String, prompt: String) async throws -> String {
        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.http(status, String(decoding: data.prefix(400), as: UTF8.self))
        }
        let choices = json["choices"] as? [[String: Any]] ?? []
        return (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    private static func apple(system: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw AIError.unavailable("Apple Intelligence isn't available on this Mac. Pick another model in Settings → AI.")
            }
            let session = LanguageModelSession(instructions: system)
            return try await session.respond(to: prompt).content
        }
        #endif
        throw AIError.unavailable("On-device AI needs macOS 26 with Apple Intelligence.")
    }

    // MARK: features

    static func threadText(_ items: [(MessageRecord, String)], redact: Bool) -> String {
        items.map { m, body in
            let b = String(HTMLText.stripQuoted(body).prefix(6000))
            return "From: \(m.from.display) <\(m.from.email)>\nDate: \(m.date.formatted())\nSubject: \(m.subject)\n\n\(redact ? Classifier.redactSecrets(b) : b)"
        }.joined(separator: "\n\n---\n\n")
    }

    @MainActor
    static func summarize(_ items: [(MessageRecord, String)]) async throws -> String {
        try await complete(system: "You summarize email conversations for a busy person. Reply with 2-4 short bullet points using '• '. Lead with what is being asked of the reader (if anything) and any deadlines. No preamble.",
                           prompt: threadText(items, redact: MailStore.shared.settings.hideOneTimeCodesFromAI), maxTokens: 600)
    }

    @MainActor
    static func summarizeStructured(_ items: [(MessageRecord, String)]) async throws -> AISummary {
        let out = try await complete(system: "You summarize email conversations for a busy person. Write one or two plain sentences summarizing the thread. Then, for each thing the reader needs to do, add a separate line starting with 'TODO: ' (short imperative, max 8 words). No other formatting.",
                                     prompt: threadText(items, redact: MailStore.shared.settings.hideOneTimeCodesFromAI), maxTokens: 500)
        var text: [String] = []; var actions: [String] = []
        for line in out.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.uppercased().hasPrefix("TODO:") { actions.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            else { text.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "•-* "))) }
        }
        return AISummary(text: text.joined(separator: " "), actions: actions)
    }

    @MainActor
    static func suggestReplies(_ items: [(MessageRecord, String)], myName: String) async throws -> [String] {
        let out = try await complete(system: "You draft short email replies on behalf of \(myName). Return exactly 3 alternative replies, each 1-3 sentences, in the language of the conversation, separated by a line containing only '###'. No greetings like 'Here are', no numbering, no signature.",
                                     prompt: threadText(Array(items.suffix(4)), redact: true), maxTokens: 800)
        return out.components(separatedBy: "###").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3).map { $0 }
    }

    enum RewriteStyle: String, CaseIterable, Identifiable {
        case shorten = "Shorten", soften = "Make friendlier", formal = "Make more formal", fix = "Fix spelling & grammar", expand = "Expand", translate = "Translate to English"
        var id: String { rawValue }
    }

    @MainActor
    static func rewrite(_ text: String, style: RewriteStyle, language: String? = nil) async throws -> String {
        let instruction: String = {
            switch style {
            case .shorten: return "Make this email shorter and clearer, keeping all key information."
            case .soften: return "Make this email warmer and friendlier without changing its meaning."
            case .formal: return "Make this email more formal and professional."
            case .fix: return "Fix spelling, grammar and punctuation. Keep wording otherwise the same."
            case .expand: return "Expand this short draft into a complete, polite email."
            case .translate: return "Translate this email into \(language ?? "English"). Keep the tone."
            }
        }()
        return try await complete(system: "You edit email drafts. \(instruction) Return only the rewritten email body, with no preamble, no subject line and no quotes.", prompt: text, maxTokens: 2000)
    }
}

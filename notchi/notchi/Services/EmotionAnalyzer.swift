import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionAnalyzer")

struct ClaudeSettingsConfig {
    let apiURL: URL
    let apiKey: String
    let model: String

    nonisolated static let defaultBaseURL = "https://api.anthropic.com"
    nonisolated static let defaultAPIURL = URL(string: "\(defaultBaseURL)/v1/messages")!
    nonisolated static let defaultModel = EmotionAnalysisModel.claudeHaiku45.rawValue

    nonisolated static func load(from settingsURL: URL) -> ClaudeSettingsConfig? {
        let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionAnalyzer")
        guard let data = try? Data(contentsOf: settingsURL) else {
            return nil
        }

        do {
            return try parse(from: data)
        } catch {
            logger.error("Failed to parse Claude settings.json: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated static func loadFromDefaultLocation() -> ClaudeSettingsConfig? {
        load(from: ClaudeConfigDirectoryResolver.resolve().settingsURL)
    }

    nonisolated static func existsAtDefaultLocation() -> Bool {
        loadFromDefaultLocation() != nil
    }

    nonisolated static func parse(from data: Data) throws -> ClaudeSettingsConfig? {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let env = json?["env"] as? [String: String] ?? [:]

        let baseURL = env["ANTHROPIC_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL = (baseURL?.isEmpty == false) ? baseURL! : defaultBaseURL

        guard let authToken = env["ANTHROPIC_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authToken.isEmpty,
              let apiURL = buildMessagesURL(from: resolvedBaseURL) else {
            return nil
        }

        let model = env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeSettingsConfig(
            apiURL: apiURL,
            apiKey: authToken,
            model: (model?.isEmpty == false) ? model! : defaultModel
        )
    }

    nonisolated static func buildMessagesURL(from baseURL: String) -> URL? {
        guard let url = EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: baseURL) else {
            let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionAnalyzer")
            logger.error("Invalid ANTHROPIC_BASE_URL: \(baseURL, privacy: .public)")
            return nil
        }
        return url
    }
}

enum OpenAISettingsConfig {
    nonisolated static let defaultAPIURL = URL(string: "https://api.openai.com/v1/chat/completions")!
}

extension EmotionAnalysisProvider {
    nonisolated var defaultEndpointURL: URL {
        switch self {
        case .claude:
            ClaudeSettingsConfig.defaultAPIURL
        case .openAI:
            OpenAISettingsConfig.defaultAPIURL
        }
    }

    nonisolated private var endpointPathComponents: [String] {
        switch self {
        case .claude:
            ["v1", "messages"]
        case .openAI:
            ["v1", "chat", "completions"]
        }
    }

    nonisolated func endpointURL(fromBaseURL baseURL: String?) -> URL? {
        let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return defaultEndpointURL
        }

        let urlString = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: urlString),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        let baseComponents = components.path.split(separator: "/").map(String.init)
        let endpoint = endpointPathComponents
        let overlap = (0...min(baseComponents.count, endpoint.count))
            .reversed()
            .first { Array(baseComponents.suffix($0)) == Array(endpoint.prefix($0)) } ?? 0
        components.path = "/" + (baseComponents + endpoint.dropFirst(overlap)).joined(separator: "/")
        return components.url
    }
}

private struct HaikuResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let text: String?
    }
}

private struct OpenAIChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct EmotionResponse: Decodable {
    let emotion: String
    let intensity: Double
}

struct EmotionAnalysisTestResult {
    let emotion: String
    let intensity: Double
    let latencyMilliseconds: Int
}

enum EmotionAnalysisRequestError: LocalizedError {
    case missingAPIKey(EmotionAnalysisProvider)
    case invalidBaseURL
    case httpStatus(provider: String, statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            String(localized: "Missing \(provider.displayName) API key")
        case .invalidBaseURL:
            String(localized: "Invalid API base URL")
        case .httpStatus(let provider, let statusCode):
            String(localized: "\(provider) API returned HTTP \(statusCode)")
        case .invalidResponse:
            String(localized: "Invalid emotion analysis response")
        }
    }

    var shortLabel: String {
        switch self {
        case .missingAPIKey:
            String(localized: "Missing")
        case .invalidBaseURL:
            String(localized: "Bad URL")
        case .httpStatus(_, let statusCode):
            String(localized: "HTTP \(statusCode)")
        case .invalidResponse:
            String(localized: "Invalid")
        }
    }
}

private struct EmotionAnalysisResponseParser {
    private static let validEmotions: Set<String> = ["happy", "sad", "neutral"]

    static func parse(_ text: String) throws -> (emotion: String, intensity: Double) {
        let jsonString = extractJSON(from: text)
        let emotionResponse = try JSONDecoder().decode(EmotionResponse.self, from: Data(jsonString.utf8))

        let emotion = validEmotions.contains(emotionResponse.emotion) ? emotionResponse.emotion : "neutral"
        let intensity = min(max(emotionResponse.intensity, 0.0), 1.0)

        return (emotion, intensity)
    }

    static func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code blocks: ```json ... ``` or ``` ... ```
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        return cleaned
    }
}

protocol EmotionAnalysisProviding {
    var providerName: String { get }
    func analyze(prompt: String, systemPrompt: String) async throws -> (emotion: String, intensity: Double)
}

private struct ClaudeEmotionAnalysisProvider: EmotionAnalysisProviding {
    let apiURL: URL
    let apiKey: String
    let model: String

    var providerName: String { "Claude" }

    func analyze(prompt: String, systemPrompt: String) async throws -> (emotion: String, intensity: Double) {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 50,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmotionAnalysisRequestError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            logger.warning("Claude API returned HTTP \(httpResponse.statusCode)")
            throw EmotionAnalysisRequestError.httpStatus(provider: providerName, statusCode: httpResponse.statusCode)
        }

        let haikuResponse = try JSONDecoder().decode(HaikuResponse.self, from: data)

        guard let text = haikuResponse.content.first?.text else {
            throw EmotionAnalysisRequestError.invalidResponse
        }

        return try EmotionAnalysisResponseParser.parse(text)
    }
}

private struct OpenAIEmotionAnalysisProvider: EmotionAnalysisProviding {
    let apiURL: URL
    let apiKey: String
    let model: String

    var providerName: String { "OpenAI" }

    func analyze(prompt: String, systemPrompt: String) async throws -> (emotion: String, intensity: Double) {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 80,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "emotion_analysis",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "emotion": [
                                "type": "string",
                                "enum": ["happy", "sad", "neutral"]
                            ],
                            "intensity": [
                                "type": "number",
                                "minimum": 0,
                                "maximum": 1
                            ]
                        ],
                        "required": ["emotion", "intensity"]
                    ]
                ]
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmotionAnalysisRequestError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            logger.warning("OpenAI API returned HTTP \(httpResponse.statusCode)")
            throw EmotionAnalysisRequestError.httpStatus(provider: providerName, statusCode: httpResponse.statusCode)
        }

        let chatResponse = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)

        guard let text = chatResponse.choices.first?.message.content else {
            throw EmotionAnalysisRequestError.invalidResponse
        }

        return try EmotionAnalysisResponseParser.parse(text)
    }
}

@MainActor
final class EmotionAnalyzer {
    static let shared = EmotionAnalyzer()

    private static let systemPrompt = """
        Classify the emotional tone of the user's message into exactly one emotion and an intensity score.
        Emotions: happy, sad, neutral.
        Happy: explicit praise ("great job", "you are so good"), gratitude, celebration, affection toward the assistant ("I love you", "love u", "you're the best"), positive profanity ("LETS FUCKING GO").
        Sad: frustration, anger, insults, complaints, feeling stuck, disappointment, negative profanity.
        Neutral: instructions, requests, task descriptions, questions, enthusiasm about work, factual statements. Exclamation marks or urgency about a task do NOT make it happy — only genuine positive sentiment toward the AI or outcome does.
        Default to neutral when unsure. Most coding instructions are neutral regardless of tone.
        Direct affection or praise aimed at the assistant is happy, not neutral, even when casual or abbreviated.
        Intensity: 0.0 (barely noticeable) to 1.0 (very strong). ALL CAPS text indicates stronger emotion — increase intensity by 0.2-0.3 compared to the same message in lowercase.
        Reply with ONLY valid JSON: {"emotion": "...", "intensity": ...}
        """
    private static let testPrompt = "Thanks, this looks great!"

    private init() {}

    func analyze(_ prompt: String) async -> (emotion: String, intensity: Double)? {
        await analyze(prompt: prompt, using: resolveProvider())
    }

    func analyze(prompt: String, using provider: EmotionAnalysisProviding?) async -> (emotion: String, intensity: Double)? {
        guard let provider else {
            return nil
        }

        let start = ContinuousClock.now
        do {
            let result = try await provider.analyze(prompt: prompt, systemPrompt: Self.systemPrompt)
            return result
        } catch {
            let elapsed = ContinuousClock.now - start
            logger.error("\(provider.providerName, privacy: .public) API failed (\(elapsed, privacy: .public)): \(error.localizedDescription)")
            return nil
        }
    }

    private func resolveProvider() -> EmotionAnalysisProviding? {
        switch AppSettings.emotionAnalysisProvider {
        case .claude:
            return resolveClaudeProvider()
        case .openAI:
            return resolveOpenAIProvider()
        }
    }

    static func manualEndpointURL(for provider: EmotionAnalysisProvider) -> URL? {
        provider.endpointURL(fromBaseURL: AppSettings.apiBaseURL(for: provider))
    }

    private func resolveClaudeProvider() -> ClaudeEmotionAnalysisProvider? {
        if let apiKey = KeychainManager.getAnthropicApiKey(allowInteraction: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            guard let apiURL = Self.manualEndpointURL(for: .claude) else {
                return nil
            }
            return ClaudeEmotionAnalysisProvider(
                apiURL: apiURL,
                apiKey: apiKey,
                model: AppSettings.selectedEmotionAnalysisModel(for: .claude).rawValue
            )
        }

        guard let config = ClaudeSettingsConfig.loadFromDefaultLocation() else {
            return nil
        }

        return ClaudeEmotionAnalysisProvider(
            apiURL: config.apiURL,
            apiKey: config.apiKey,
            model: AppSettings.storedEmotionAnalysisModel(for: .claude)?.rawValue ?? config.model
        )
    }

    private func resolveOpenAIProvider() -> OpenAIEmotionAnalysisProvider? {
        guard let apiKey = KeychainManager.getOpenAIApiKey(allowInteraction: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty,
              let apiURL = Self.manualEndpointURL(for: .openAI) else {
            return nil
        }

        return OpenAIEmotionAnalysisProvider(
            apiURL: apiURL,
            apiKey: apiKey,
            model: AppSettings.selectedEmotionAnalysisModel(for: .openAI).rawValue
        )
    }

    func testConfiguration(
        provider: EmotionAnalysisProvider,
        model: EmotionAnalysisModel,
        apiKey: String?,
        baseURL: String?
    ) async throws -> EmotionAnalysisTestResult {
        let analysisProvider = try resolveProvider(provider: provider, model: model, apiKey: apiKey, baseURL: baseURL)
        let start = ContinuousClock.now
        let result = try await analysisProvider.analyze(prompt: Self.testPrompt, systemPrompt: Self.systemPrompt)
        let elapsed = (ContinuousClock.now - start).components
        let latency = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)

        return EmotionAnalysisTestResult(
            emotion: result.emotion,
            intensity: result.intensity,
            latencyMilliseconds: latency
        )
    }

    private func resolveProvider(
        provider: EmotionAnalysisProvider,
        model: EmotionAnalysisModel,
        apiKey: String?,
        baseURL: String?
    ) throws -> EmotionAnalysisProviding {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch provider {
        case .claude:
            if !trimmedKey.isEmpty {
                guard let apiURL = provider.endpointURL(fromBaseURL: baseURL) else {
                    throw EmotionAnalysisRequestError.invalidBaseURL
                }
                return ClaudeEmotionAnalysisProvider(
                    apiURL: apiURL,
                    apiKey: trimmedKey,
                    model: model.rawValue
                )
            }

            if let config = ClaudeSettingsConfig.loadFromDefaultLocation() {
                return ClaudeEmotionAnalysisProvider(
                    apiURL: config.apiURL,
                    apiKey: config.apiKey,
                    model: model.rawValue
                )
            }

            throw EmotionAnalysisRequestError.missingAPIKey(provider)
        case .openAI:
            guard !trimmedKey.isEmpty else {
                throw EmotionAnalysisRequestError.missingAPIKey(provider)
            }

            guard let apiURL = provider.endpointURL(fromBaseURL: baseURL) else {
                throw EmotionAnalysisRequestError.invalidBaseURL
            }

            return OpenAIEmotionAnalysisProvider(
                apiURL: apiURL,
                apiKey: trimmedKey,
                model: model.rawValue
            )
        }
    }
}

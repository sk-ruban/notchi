import Foundation
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionAnalyzer")

nonisolated private struct ClaudeSettingsFile: Decodable {
    let env: [String: String]?
}

nonisolated struct ClaudeSettingsConfig {
    let apiURL: URL
    let apiKey: String
    let model: String

    static let defaultBaseURL = "https://api.anthropic.com"
    static let defaultAPIURL = URL(string: "\(defaultBaseURL)/v1/messages")!
    static let defaultModel = "claude-haiku-4-5-20251001"

    static func parse(from data: Data) throws -> ClaudeSettingsConfig? {
        let settings = try JSONDecoder().decode(ClaudeSettingsFile.self, from: data)
        let env = settings.env ?? [:]

        let baseURL = env["ANTHROPIC_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL = (baseURL?.isEmpty == false) ? baseURL! : defaultBaseURL

        guard let authToken = env["ANTHROPIC_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authToken.isEmpty,
              let apiURL = buildMessagesURL(from: resolvedBaseURL) else {
            logger.debug("Claude settings present but missing valid auth token or base URL")
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

    static func buildMessagesURL(from baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else {
            logger.error("Invalid ANTHROPIC_BASE_URL: \(baseURL, privacy: .public)")
            return nil
        }

        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch true {
        case normalizedPath.isEmpty:
            components.path = "/v1/messages"
        case normalizedPath.hasSuffix("/v1/messages") || normalizedPath == "v1/messages":
            components.path = "/\(normalizedPath)"
        case normalizedPath.hasSuffix("/v1") || normalizedPath == "v1":
            components.path = "/\(normalizedPath)/messages"
        default:
            components.path = "/\(normalizedPath)/v1/messages"
        }

        return components.url
    }
}

nonisolated private struct AnthropicResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let text: String?
    }
}

nonisolated private struct EmotionResponse: Decodable {
    let emotion: String
    let intensity: Double
}

private enum EmotionAnalyzerCodexCLIResolver {
    nonisolated static func resolveExecutableURL() -> URL? {
        for path in searchPaths() where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    nonisolated private static func searchPaths() -> [String] {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathEntries = environmentPath
            .split(separator: ":")
            .map { String($0) }
            .map { ($0 as NSString).appendingPathComponent("codex") }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let wellKnownPaths = [
            "\(home)/.local/bin/codex",
            "\(home)/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]

        return Array(NSOrderedSet(array: pathEntries + wellKnownPaths)) as? [String] ?? wellKnownPaths
    }
}

private enum CodexEmotionAnalyzer {
    nonisolated private static let timeout: TimeInterval = 12.0

    nonisolated static func analyze(prompt: String, systemPrompt: String) -> EmotionResponse? {
        guard let executableURL = EmotionAnalyzerCodexCLIResolver.resolveExecutableURL() else {
            return nil
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchi-emotion-\(UUID().uuidString)", isDirectory: true)
        let schemaURL = tempDirectory.appendingPathComponent("emotion-schema.json")
        let outputURL = tempDirectory.appendingPathComponent("emotion-output.json")

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try schemaJSONData().write(to: schemaURL, options: .atomic)
        } catch {
            logger.error("Failed to prepare Codex emotion analysis temp files: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempDirectory)
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.arguments = [
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "--sandbox", "read-only",
            "--output-schema", schemaURL.path,
            "-o", outputURL.path,
            promptText(for: prompt, systemPrompt: systemPrompt),
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch Codex for emotion analysis: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            terminate(process)
            logger.error("Codex emotion analysis timed out")
            return nil
        }

        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if process.terminationStatus != 0 {
            logger.error(
                "Codex emotion analysis failed with exit code \(process.terminationStatus, privacy: .public): \(stderr, privacy: .public)"
            )
            return nil
        }

        guard let data = try? Data(contentsOf: outputURL),
              let response = try? JSONDecoder().decode(EmotionResponse.self, from: data) else {
            logger.error("Codex emotion analysis completed without a valid JSON result")
            return nil
        }

        return response
    }

    nonisolated private static func schemaJSONData() throws -> Data {
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "emotion": [
                    "type": "string",
                    "enum": ["happy", "sad", "neutral"],
                ],
                "intensity": [
                    "type": "number",
                    "minimum": 0,
                    "maximum": 1,
                ],
            ],
            "required": ["emotion", "intensity"],
        ]

        return try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
    }

    nonisolated private static func promptText(for prompt: String, systemPrompt: String) -> String {
        """
        \(systemPrompt)

        Use the schema output. Do not call tools. Analyze only this user message:
        <user_message>
        \(prompt)
        </user_message>
        """
    }

    nonisolated private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}

@MainActor
final class EmotionAnalyzer {
    static let shared = EmotionAnalyzer()

    nonisolated private static let validEmotions: Set<String> = ["happy", "sad", "neutral"]

    nonisolated fileprivate static let systemPrompt = """
        Classify the emotional tone of the user's message into exactly one emotion and an intensity score.
        Emotions: happy, sad, neutral.
        Happy: explicit praise ("great job", "thank you!"), gratitude, celebration, positive profanity ("LETS FUCKING GO").
        Sad: frustration, anger, insults, complaints, feeling stuck, disappointment, negative profanity.
        Neutral: instructions, requests, task descriptions, questions, enthusiasm about work, factual statements. Exclamation marks or urgency about a task do NOT make it happy — only genuine positive sentiment toward the AI or outcome does.
        Default to neutral when unsure. Most coding instructions are neutral regardless of tone.
        Intensity: 0.0 (barely noticeable) to 1.0 (very strong). ALL CAPS text indicates stronger emotion — increase intensity by 0.2-0.3 compared to the same message in lowercase.
        Reply with ONLY valid JSON: {"emotion": "...", "intensity": ...}
        """

    private init() {}

    func analyze(_ prompt: String, provider: SessionProvider) async -> (emotion: String, intensity: Double) {
        let start = ContinuousClock.now

        guard AppSettings.isEmotionAnalysisEnabled else {
            logger.info("Emotion analysis disabled, using neutral fallback")
            return ("neutral", 0.0)
        }

        if provider == .codex,
           let result = await analyzeWithCodex(prompt) {
            let elapsed = ContinuousClock.now - start
            logger.info("Codex emotion analysis took \(elapsed, privacy: .public)")
            return result
        }

        guard let config = resolveAPIConfig() else {
            logger.info("No emotion analysis configuration available, using neutral fallback")
            return ("neutral", 0.0)
        }

        do {
            let response = try await callAnthropic(
                prompt: prompt,
                apiURL: config.apiURL,
                apiKey: config.apiKey,
                model: config.model
            )
            let elapsed = ContinuousClock.now - start
            logger.info("Anthropic emotion analysis took \(elapsed, privacy: .public)")
            return Self.normalizedResult(from: response)
        } catch {
            let elapsed = ContinuousClock.now - start
            logger.error("Anthropic emotion analysis failed (\(elapsed, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return ("neutral", 0.0)
        }
    }

    private func analyzeWithCodex(_ prompt: String) async -> (emotion: String, intensity: Double)? {
        let task = Task.detached(priority: .utility) { () -> (emotion: String, intensity: Double)? in
            guard let response = CodexEmotionAnalyzer.analyze(
                prompt: prompt,
                systemPrompt: Self.systemPrompt
            ) else {
                return nil
            }
            return Self.normalizedResult(from: response)
        }
        return await task.value
    }

    nonisolated private static func normalizedResult(from response: EmotionResponse) -> (emotion: String, intensity: Double) {
        let emotion = validEmotions.contains(response.emotion) ? response.emotion : "neutral"
        let intensity = min(max(response.intensity, 0.0), 1.0)
        return (emotion, intensity)
    }

    nonisolated private static func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

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

    private func resolveAPIConfig() -> (apiURL: URL, apiKey: String, model: String)? {
        guard let apiKey = KeychainManager.getAnthropicApiKey(allowInteraction: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            return loadClaudeSettingsConfig()
        }

        return (
            apiURL: ClaudeSettingsConfig.defaultAPIURL,
            apiKey: apiKey,
            model: ClaudeSettingsConfig.defaultModel
        )
    }

    private func loadClaudeSettingsConfig() -> (apiURL: URL, apiKey: String, model: String)? {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        guard let data = try? Data(contentsOf: settingsURL) else {
            return nil
        }

        do {
            guard let config = try ClaudeSettingsConfig.parse(from: data) else {
                return nil
            }
            return (
                apiURL: config.apiURL,
                apiKey: config.apiKey,
                model: config.model
            )
        } catch {
            logger.error("Failed to parse Claude settings.json: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func callAnthropic(prompt: String, apiURL: URL, apiKey: String, model: String) async throws -> EmotionResponse {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 50,
            "system": Self.systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            logger.warning("Anthropic emotion analysis returned HTTP \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        guard let text = anthropicResponse.content.first?.text else {
            throw URLError(.cannotParseResponse)
        }

        logger.debug("Anthropic emotion analysis raw response: \(text, privacy: .public)")

        let jsonString = Self.extractJSON(from: text)
        return try JSONDecoder().decode(EmotionResponse.self, from: Data(jsonString.utf8))
    }
}

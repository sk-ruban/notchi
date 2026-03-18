import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionAnalyzer")

private struct HaikuResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let text: String?
    }
}

private struct EmotionResponse: Decodable {
    let emotion: String
    let intensity: Double
}

@MainActor
final class EmotionAnalyzer {
    static let shared = EmotionAnalyzer()

    private static let defaultBaseURL = "https://api.anthropic.com"
    private static let model = "claude-haiku-4-5-20251001"
    private static let validEmotions: Set<String> = ["happy", "sad", "neutral"]

    private static let systemPrompt = """
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

    private static func getApiURL() -> URL {
        let baseURL = AppSettings.anthropicApiBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = baseURL.isEmpty ? defaultBaseURL : baseURL
        return URL(string: "\(url)/v1/messages")!
    }

    func analyze(_ prompt: String) async -> (emotion: String, intensity: Double) {
        let start = ContinuousClock.now

        guard let apiKey = AppSettings.anthropicApiKey, !apiKey.isEmpty else {
            logger.info("No Anthropic API key configured, skipping emotion analysis")
            return ("neutral", 0.0)
        }

        do {
            let result = try await callHaiku(prompt: prompt, apiKey: apiKey)
            let elapsed = ContinuousClock.now - start
            logger.info("Analysis took \(elapsed, privacy: .public)")
            return result
        } catch {
            let elapsed = ContinuousClock.now - start
            logger.error("Haiku API failed (\(elapsed, privacy: .public)): \(error.localizedDescription)")
            return ("neutral", 0.0)
        }
    }

    private static func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code blocks: ```json ... ``` or ``` ... ```
        if cleaned.hasPrefix("```") {
            // Remove opening ``` (with optional language tag)
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            // Remove closing ```
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Find first { to last } in case of surrounding text
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        return cleaned
    }

    private func callHaiku(prompt: String, apiKey: String) async throws -> (emotion: String, intensity: Double) {
        let apiURL = Self.getApiURL()
        logger.info("Using API URL: \(apiURL.absoluteString, privacy: .public)")
        
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": Self.model,
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
            logger.warning("Haiku API returned HTTP \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        let haikuResponse = try JSONDecoder().decode(HaikuResponse.self, from: data)

        guard let text = haikuResponse.content.first?.text else {
            throw URLError(.cannotParseResponse)
        }

        logger.debug("Haiku raw response: \(text, privacy: .public)")

        let jsonString = Self.extractJSON(from: text)
        let emotionResponse = try JSONDecoder().decode(EmotionResponse.self, from: Data(jsonString.utf8))

        let emotion = Self.validEmotions.contains(emotionResponse.emotion) ? emotionResponse.emotion : "neutral"
        let intensity = min(max(emotionResponse.intensity, 0.0), 1.0)

        return (emotion, intensity)
    }
}

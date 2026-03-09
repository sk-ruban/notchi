import Accelerate
import Foundation
import NaturalLanguage
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionAnalyzer")

enum EmotionAnalysisMode: String, CaseIterable {
    case simple = "simple"
    case api = "api"
    case disabled = "disabled"

    var displayName: String {
        switch self {
        case .simple: return "Simple"
        case .api: return "Anthropic API"
        case .disabled: return "Disabled"
        }
    }
}

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

    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-haiku-4-5-20251001"
    private static let validEmotions: Set<String> = Set(
        NotchiEmotion.allCases.filter { $0 != .sob }.map(\.rawValue)
    )

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

    // MARK: - On-Device Embedding Classification

    private static let ambiguityMargin = 0.05

    private static let happyAnchorStrings = [
        "great work thank you", "amazing I love it", "looks perfect now",
        "that works thanks", "this is so fun and exciting", "you did it congrats",
        "finally it works", "you're doing a great job",
    ]

    private static let sadAnchorStrings = [
        "bruh what did you do this is broken", "this is terrible and ugly",
        "why does it still not work", "I'm so frustrated it keeps failing",
        "we took steps back this is worse now", "it doesn't fucking work",
        "still not doing what I want", "back to a broken state again",
    ]

    private static let neutralAnchorStrings = [
        "fix this and deploy it", "commit and push the changes",
        "refactor the database module", "can you explain how this works",
        "continue please keep going", "build and run it", "try again ultrathink",
        "merge into main", "my codebase is confusing",
        "sorry that was wrong let me clarify", "use this other approach instead",
        "it works but it's not ideal", "what is the value for this",
    ]

    private struct AnchorSet {
        let vectors: [[Double]]
        let norms: [Double]
    }

    private static var _embedding: NLEmbedding?
    private static var _happyAnchors: AnchorSet?
    private static var _sadAnchors: AnchorSet?
    private static var _neutralAnchors: AnchorSet?
    private static var _initialized = false

    private static func ensureEmbedding() -> Bool {
        guard !_initialized else { return _embedding != nil }
        _initialized = true
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            logger.warning("NLEmbedding.sentenceEmbedding unavailable")
            return false
        }
        _embedding = embedding
        _happyAnchors = makeAnchorSet(happyAnchorStrings, embedding: embedding)
        _sadAnchors = makeAnchorSet(sadAnchorStrings, embedding: embedding)
        _neutralAnchors = makeAnchorSet(neutralAnchorStrings, embedding: embedding)
        let total = (_happyAnchors?.vectors.count ?? 0) + (_sadAnchors?.vectors.count ?? 0) + (_neutralAnchors?.vectors.count ?? 0)
        logger.info("Loaded sentence embedding with \(total) anchor vectors")
        return true
    }

    private static func makeAnchorSet(_ strings: [String], embedding: NLEmbedding) -> AnchorSet {
        let vectors = strings.compactMap { embedding.vector(for: $0) }
        let norms = vectors.map { vec -> Double in
            var norm = 0.0
            vDSP_dotprD(vec, 1, vec, 1, &norm, vDSP_Length(vec.count))
            return sqrt(norm)
        }
        return AnchorSet(vectors: vectors, norms: norms)
    }

    private static func minDistance(_ vec: [Double], vecNorm: Double, _ anchors: AnchorSet) -> Double {
        anchors.vectors.enumerated().reduce(999.0) { best, pair in
            let (i, anchor) = pair
            var dot = 0.0
            vDSP_dotprD(vec, 1, anchor, 1, &dot, vDSP_Length(vec.count))
            let denom = vecNorm * anchors.norms[i]
            guard denom > 0 else { return best }
            return min(best, 1.0 - (dot / denom))
        }
    }

    private init() {}

    func analyze(_ prompt: String) async -> (emotion: String, intensity: Double) {
        switch AppSettings.emotionAnalysisMode {
        case .simple:
            return analyzeLocally(prompt)
        case .api:
            return await analyzeWithAPI(prompt)
        case .disabled:
            return ("neutral", 0.0)
        }
    }

    // MARK: - On-Device (NLEmbedding)

    private static let maxPromptLength = 200

    private func analyzeLocally(_ prompt: String) -> (emotion: String, intensity: Double) {
        let start = ContinuousClock.now

        guard prompt.count <= Self.maxPromptLength else {
            return ("neutral", 0.0)
        }

        guard Self.ensureEmbedding(),
              let embedding = Self._embedding,
              let happyAnchors = Self._happyAnchors,
              let sadAnchors = Self._sadAnchors,
              let neutralAnchors = Self._neutralAnchors,
              let promptVec = embedding.vector(for: prompt.lowercased())
        else {
            logger.info("Embedding unavailable, defaulting to neutral")
            return ("neutral", 0.0)
        }

        var promptNorm = 0.0
        vDSP_dotprD(promptVec, 1, promptVec, 1, &promptNorm, vDSP_Length(promptVec.count))
        promptNorm = sqrt(promptNorm)

        let categories: [(String, Double)] = [
            ("happy", Self.minDistance(promptVec, vecNorm: promptNorm, happyAnchors)),
            ("sad", Self.minDistance(promptVec, vecNorm: promptNorm, sadAnchors)),
            ("neutral", Self.minDistance(promptVec, vecNorm: promptNorm, neutralAnchors)),
        ]
        let sorted = categories.sorted { $0.1 < $1.1 }
        let margin = sorted[1].1 - sorted[0].1

        let result: (emotion: String, intensity: Double)

        if margin < Self.ambiguityMargin {
            result = ("neutral", 0.0)
        } else if sorted[0].0 == "neutral" {
            result = ("neutral", 0.0)
        } else {
            result = (sorted[0].0, min(max(1.0 - sorted[0].1, 0.0), 1.0))
        }

        let elapsed = ContinuousClock.now - start
        logger.info("Local analysis took \(elapsed, privacy: .public): h=\(String(format: "%.3f", categories[0].1), privacy: .public) s=\(String(format: "%.3f", categories[1].1), privacy: .public) n=\(String(format: "%.3f", categories[2].1), privacy: .public) margin=\(String(format: "%.3f", margin), privacy: .public) -> \(result.emotion, privacy: .public) (\(String(format: "%.2f", result.intensity), privacy: .public))")

        return result
    }

    // MARK: - Claude API

    private func analyzeWithAPI(_ prompt: String) async -> (emotion: String, intensity: Double) {
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
        var request = URLRequest(url: Self.apiURL)
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

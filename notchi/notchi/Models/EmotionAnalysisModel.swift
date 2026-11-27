import Foundation

nonisolated struct EmotionAnalysisModel: Identifiable, Hashable {
    let rawValue: String
    let provider: EmotionAnalysisProvider
    private let presetName: String?

    var id: String { rawValue }

    var displayName: String { presetName ?? rawValue }

    var isPreset: Bool { presetName != nil }

    var maxOutputTokens: Int {
        guard isPreset else {
            return Self.customModelOutputTokens
        }
        switch provider {
        case .claude:
            return 50
        case .openAI:
            return 80
        }
    }

    // Reasoning models spend most of this on reasoning tokens: ~266 for a one-sentence prompt.
    static let customModelOutputTokens = 1024

    private init(rawValue: String, provider: EmotionAnalysisProvider, presetName: String?) {
        self.rawValue = rawValue
        self.provider = provider
        self.presetName = presetName
    }

    static func custom(_ rawValue: String, provider: EmotionAnalysisProvider) -> EmotionAnalysisModel {
        EmotionAnalysisModel(rawValue: rawValue, provider: provider, presetName: nil)
    }

    private static func preset(
        _ rawValue: String,
        _ presetName: String,
        _ provider: EmotionAnalysisProvider
    ) -> EmotionAnalysisModel {
        EmotionAnalysisModel(rawValue: rawValue, provider: provider, presetName: presetName)
    }

    static let claudeHaiku45 = preset("claude-haiku-4-5-20251001", "Claude Haiku 4.5", .claude)
    static let claudeSonnet46 = preset("claude-sonnet-4-6", "Claude Sonnet 4.6", .claude)
    static let openAIGPT54Nano = preset("gpt-5.4-nano", "GPT-5.4 nano", .openAI)
    static let openAIGPT54Mini = preset("gpt-5.4-mini", "GPT-5.4 mini", .openAI)
    static let openAIGPT41Mini = preset("gpt-4.1-mini", "GPT-4.1 mini", .openAI)

    static func models(for provider: EmotionAnalysisProvider) -> [EmotionAnalysisModel] {
        switch provider {
        case .claude:
            [.claudeHaiku45, .claudeSonnet46]
        case .openAI:
            [.openAIGPT54Mini, .openAIGPT54Nano, .openAIGPT41Mini]
        }
    }

    static func defaultModel(for provider: EmotionAnalysisProvider) -> EmotionAnalysisModel {
        switch provider {
        case .claude:
            .claudeHaiku45
        case .openAI:
            .openAIGPT54Mini
        }
    }

    static func resolve(_ rawValue: String, for provider: EmotionAnalysisProvider) -> EmotionAnalysisModel {
        models(for: provider).first { $0.rawValue == rawValue } ?? custom(rawValue, provider: provider)
    }

    // Identity is the id/provider pair: a fetched model and its preset are the same selection.
    static func == (lhs: EmotionAnalysisModel, rhs: EmotionAnalysisModel) -> Bool {
        lhs.rawValue == rhs.rawValue && lhs.provider == rhs.provider
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
        hasher.combine(provider)
    }
}

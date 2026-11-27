import Foundation

enum EmotionAnalysisProvider: String, CaseIterable, Identifiable {
    case claude
    case openAI = "openai"

    var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .openAI:
            "OpenAI"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .claude:
            String(localized: "Anthropic API Key")
        case .openAI:
            String(localized: "OpenAI API Key")
        }
    }

    var apiBaseURLPlaceholder: String {
        switch self {
        case .claude:
            "api.anthropic.com"
        case .openAI:
            "api.openai.com"
        }
    }

    var apiKeyURL: URL {
        switch self {
        case .claude:
            URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI:
            URL(string: "https://platform.openai.com/api-keys")!
        }
    }
}

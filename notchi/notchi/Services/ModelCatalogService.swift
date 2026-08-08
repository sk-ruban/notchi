import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "ModelCatalog")

private nonisolated struct ModelCatalogResponse: Decodable {
    let ids: [String]

    private struct Entry: Decodable {
        let id: String?
        let name: String?

        var identifier: String? {
            let value = (id ?? name)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case data
        case models
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            let entries = (try? container.decode([Entry].self, forKey: .data))
                ?? (try? container.decode([Entry].self, forKey: .models))
            if let entries {
                ids = entries.compactMap(\.identifier)
                return
            }
        }

        if let entries = try? [Entry](from: decoder) {
            ids = entries.compactMap(\.identifier)
            return
        }

        throw EmotionAnalysisRequestError.invalidResponse
    }
}

nonisolated enum ModelCatalogFilter {
    private static let nonChatFragments = [
        "embed",
        "whisper",
        "tts",
        "text-to-speech",
        "dall-e",
        "moderation",
        "transcribe",
        "realtime",
        "rerank",
    ]

    /// Returns everything rather than nothing when the filter would empty an unfamiliar catalog.
    static func chatCapable(_ ids: [String]) -> [String] {
        let filtered = ids.filter { id in
            let lowercased = id.lowercased()
            return !nonChatFragments.contains { lowercased.contains($0) }
        }
        return filtered.isEmpty ? ids : filtered
    }
}

@MainActor
final class ModelCatalogService {
    static let shared = ModelCatalogService()

    private init() {}

    func fetchModels(
        provider: EmotionAnalysisProvider,
        apiKey: String?,
        baseURL: String?
    ) async throws -> [EmotionAnalysisModel] {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !trimmedKey.isEmpty else {
            throw EmotionAnalysisRequestError.missingAPIKey(provider)
        }

        guard let url = provider.modelsEndpointURL(fromBaseURL: baseURL) else {
            throw EmotionAnalysisRequestError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch provider {
        case .claude:
            request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmotionAnalysisRequestError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            logger.warning("\(provider.displayName, privacy: .public) model list returned HTTP \(httpResponse.statusCode)")
            throw EmotionAnalysisRequestError.httpStatus(
                provider: provider.displayName,
                statusCode: httpResponse.statusCode
            )
        }

        let models = Self.models(from: data, for: provider)

        guard !models.isEmpty else {
            throw EmotionAnalysisRequestError.emptyModelCatalog
        }

        return models
    }

    nonisolated static func models(from data: Data, for provider: EmotionAnalysisProvider) -> [EmotionAnalysisModel] {
        guard let response = try? JSONDecoder().decode(ModelCatalogResponse.self, from: data) else {
            return []
        }

        var seen = Set<String>()
        return ModelCatalogFilter.chatCapable(response.ids)
            .filter { seen.insert($0).inserted }
            .map { EmotionAnalysisModel.resolve($0, for: provider) }
    }

}

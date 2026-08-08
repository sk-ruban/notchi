import SwiftUI

struct EmotionAnalysisSettingsView: View {
    private enum TestState {
        case idle
        case testing
        case success(EmotionAnalysisTestResult)
        case failure(String)
    }

    private enum CatalogState {
        case idle
        case loading
        case loaded(Int)
        case failure(String)
    }

    @State private var provider = AppSettings.emotionAnalysisProvider
    @State private var model = AppSettings.selectedEmotionAnalysisModel(for: AppSettings.emotionAnalysisProvider)
    @State private var apiKeyInput = AppSettings.apiKey(for: AppSettings.emotionAnalysisProvider) ?? ""
    @State private var baseURLInput = AppSettings.apiBaseURL(for: AppSettings.emotionAnalysisProvider) ?? ""
    @State private var isProviderPickerExpanded = false
    @State private var isModelPickerExpanded = false
    @State private var testState: TestState = .idle
    @State private var catalogState: CatalogState = .idle
    @State private var fetchedModels: [EmotionAnalysisModel] = []
    @State private var customModelInput = ""
    @State private var setupLinkShakePhase: CGFloat = 0
    @FocusState private var isAPIKeyFocused: Bool
    @FocusState private var isBaseURLFocused: Bool
    @FocusState private var isCustomModelFocused: Bool

    private var hasApiKey: Bool {
        !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelOptions: [EmotionAnalysisModel] {
        var seen = Set<EmotionAnalysisModel>()
        return (EmotionAnalysisModel.models(for: provider) + fetchedModels + [model])
            .filter { $0.provider == provider && seen.insert($0).inserted }
    }

    private var isFetchingModels: Bool {
        if case .loading = catalogState {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                descriptionSection
                providerSection
                modelSection
                apiKeySection
                baseURLSection
                testSection
                setupSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear {
            saveApiKey(for: provider)
            saveBaseURL(for: provider)
        }
        .animation(.spring(response: 0.3), value: isProviderPickerExpanded)
        .animation(.spring(response: 0.3), value: isModelPickerExpanded)
        .onChange(of: apiKeyInput) { _, _ in
            resetTestState()
            resetCatalogState()
        }
        .onChange(of: baseURLInput) { _, _ in
            resetTestState()
            resetCatalogState()
        }
        .onChange(of: isBaseURLFocused) { _, focused in
            guard !focused else { return }
            saveBaseURL(for: provider)
        }
        .onChange(of: isAPIKeyFocused) { _, focused in
            guard focused else { return }
            withAnimation(.linear(duration: 0.28)) {
                setupLinkShakePhase += 1
            }
        }
    }

    private var descriptionSection: some View {
        Text("Prompts are sent to the selected provider for emotion classification.")
            .panelFont(size: 11)
            .foregroundColor(TerminalColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                blurAPIKeyField()
                isProviderPickerExpanded.toggle()
            }) {
                SettingsRowView(icon: "switch.2", title: "Provider") {
                    HStack(spacing: 4) {
                        Text(provider.displayName)
                            .panelFont(size: 11)
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: isProviderPickerExpanded ? "chevron.up" : "chevron.down")
                            .panelFont(size: 9)
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
            }
            .buttonStyle(.plain)

            if isProviderPickerExpanded {
                providerPicker
            }
        }
    }

    private var providerPicker: some View {
        SettingsPicker(rowCount: EmotionAnalysisProvider.allCases.count) {
            ForEach(EmotionAnalysisProvider.allCases) { option in
                providerRow(option)
            }
        }
    }

    private func providerRow(_ option: EmotionAnalysisProvider) -> some View {
        Button(action: { selectProvider(option) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(provider == option ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)

                Text(option.displayName)
                    .panelFont(size: 11, weight: .medium)
                    .foregroundColor(provider == option ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(provider == option ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var apiKeySection: some View {
        HStack {
            Image(systemName: "key")
                .panelFont(size: 12)
                .foregroundColor(TerminalColors.secondaryText)
                .frame(width: 20)

            Text("API Key")
                .panelFont(size: 12)
                .foregroundColor(TerminalColors.primaryText)
                .layoutPriority(1)

            Spacer(minLength: 12)

            apiKeyStatusView
            apiKeyField
        }
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
    }

    @ViewBuilder
    private var apiKeyStatusView: some View {
        if !hasApiKey, provider == .claude, hasClaudeCodeFallback {
            statusBadge("Claude Code", color: TerminalColors.green)
        }
    }

    private var apiKeyField: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                SecureField("", text: $apiKeyInput)
                    .textFieldStyle(.plain)
                    .panelFont(size: 11, design: .monospaced)
                    .foregroundColor(TerminalColors.primaryText)
                    .padding(.horizontal, SettingsLayout.fieldHorizontalPadding)
                    .padding(.vertical, SettingsLayout.fieldVerticalPadding)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .focused($isAPIKeyFocused)
                    .onSubmit { saveApiKey(for: provider) }

                if apiKeyInput.isEmpty {
                    Text(provider.apiKeyPlaceholder)
                        .panelFont(size: 11, design: .monospaced)
                        .foregroundColor(TerminalColors.dimmedText)
                        .padding(.leading, SettingsLayout.fieldHorizontalPadding)
                        .allowsHitTesting(false)
                }
            }
            .frame(minWidth: 220, maxWidth: 300)

            Button(action: {
                blurAPIKeyField()
                saveApiKey(for: provider)
            }) {
                Image(systemName: hasApiKey ? "checkmark.circle.fill" : "arrow.right.circle")
                    .panelFont(size: 14)
                    .foregroundColor(hasApiKey ? TerminalColors.green : TerminalColors.dimmedText)
            }
            .buttonStyle(.plain)
        }
    }

    private var baseURLSection: some View {
        HStack {
            Image(systemName: "link")
                .panelFont(size: 12)
                .foregroundColor(TerminalColors.secondaryText)
                .frame(width: 20)

            Text("Base URL")
                .panelFont(size: 12)
                .foregroundColor(TerminalColors.primaryText)
                .layoutPriority(1)

            Spacer(minLength: 12)

            baseURLField
        }
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
    }

    private var baseURLField: some View {
        ZStack(alignment: .leading) {
            TextField("", text: $baseURLInput)
                .textFieldStyle(.plain)
                .panelFont(size: 11, design: .monospaced)
                .foregroundColor(TerminalColors.primaryText)
                .padding(.horizontal, SettingsLayout.fieldHorizontalPadding)
                .padding(.vertical, SettingsLayout.fieldVerticalPadding)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
                .focused($isBaseURLFocused)
                .onSubmit { saveBaseURL(for: provider) }

            if baseURLInput.isEmpty {
                Text(provider.apiBaseURLPlaceholder)
                    .panelFont(size: 11, design: .monospaced)
                    .foregroundColor(TerminalColors.dimmedText)
                    .padding(.leading, SettingsLayout.fieldHorizontalPadding)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 220, maxWidth: 300)
    }

    private var setupSection: some View {
        Button(action: openAPIKeyPage) {
            SettingsRowView(icon: "arrow.up.right.square", title: "Get API Key") {
                Image(systemName: "arrow.up.right")
                    .panelFont(size: 10)
                    .foregroundColor(TerminalColors.dimmedText)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isAPIKeyFocused ? TerminalColors.hoverBackground : Color.clear)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isAPIKeyFocused ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            )
        }
        .buttonStyle(.plain)
        .modifier(HorizontalShake(animatableData: setupLinkShakePhase))
        .animation(.easeInOut(duration: 0.15), value: isAPIKeyFocused)
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: testEmotionAnalysis) {
                SettingsRowView(icon: "bolt.horizontal", title: "Test") {
                    testStatusView
                }
            }
            .buttonStyle(.plain)
            .disabled(isTesting || !canTest)

            testDetailView
        }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testState {
        case .idle:
            if canTest {
                Image(systemName: "play.circle")
                    .panelFont(size: 13)
                    .foregroundColor(TerminalColors.dimmedText)
            } else {
                statusBadge(String(localized: "Missing key"), color: TerminalColors.red)
            }
        case .testing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .panelFont(size: 13)
                .foregroundColor(TerminalColors.green)
        case .failure(let message):
            statusBadge(message, color: TerminalColors.red)
        }
    }

    @ViewBuilder
    private var testDetailView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            testDetailText(String(localized: "Testing \(provider.displayName) with \(model.displayName)..."))
        case .success(let result):
            testDetailText(String(localized: "Result: \(testResultText(result))"))
        case .failure:
            testDetailText(canTest ? String(localized: "Could not verify this configuration.") : String(localized: "Add an API key to test this configuration."))
        }
    }

    private func testDetailText(_ text: String) -> some View {
        Text(text)
            .panelFont(size: 10)
            .foregroundColor(TerminalColors.dimmedText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 28)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: {
                    blurAPIKeyField()
                    isModelPickerExpanded.toggle()
                }) {
                    SettingsRowView(icon: "cpu", title: "Model") {
                        HStack(spacing: 4) {
                            Text(model.displayName)
                                .panelFont(size: 11)
                                .foregroundColor(TerminalColors.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: isModelPickerExpanded ? "chevron.up" : "chevron.down")
                                .panelFont(size: 9)
                                .foregroundColor(TerminalColors.dimmedText)
                        }
                    }
                }
                .buttonStyle(.plain)

                refreshModelsButton
            }

            if isModelPickerExpanded {
                modelPicker
            }

            catalogDetailView
        }
    }

    private var refreshModelsButton: some View {
        Button(action: refreshModelCatalog) {
            Group {
                if isFetchingModels {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .panelFont(size: 11)
                        .foregroundColor(hasApiKey ? TerminalColors.secondaryText : TerminalColors.dimmedText)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFetchingModels || !hasApiKey)
        .help("Fetch the models this endpoint serves")
    }

    @ViewBuilder
    private var catalogDetailView: some View {
        switch catalogState {
        case .idle, .loading:
            EmptyView()
        case .loaded(let count):
            testDetailText(String(localized: "Found \(count) models at this endpoint."))
        case .failure(let message):
            testDetailText(String(localized: "Could not list models: \(message)"))
        }
    }

    private var modelPicker: some View {
        SettingsPicker(rowCount: modelOptions.count + 1) {
            ForEach(modelOptions) { option in
                modelRow(option)
            }
            customModelRow
        }
    }

    private var customModelRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.clear)
                .frame(width: 6, height: 6)

            ZStack(alignment: .leading) {
                TextField("", text: $customModelInput)
                    .textFieldStyle(.plain)
                    .panelFont(size: 11, design: .monospaced)
                    .foregroundColor(TerminalColors.primaryText)
                    .focused($isCustomModelFocused)
                    .onSubmit(commitCustomModel)

                if customModelInput.isEmpty {
                    Text("Custom model id")
                        .panelFont(size: 11, design: .monospaced)
                        .foregroundColor(TerminalColors.dimmedText)
                        .allowsHitTesting(false)
                }
            }

            Button(action: commitCustomModel) {
                Image(systemName: "arrow.right.circle")
                    .panelFont(size: 12)
                    .foregroundColor(hasCustomModelInput ? TerminalColors.green : TerminalColors.dimmedText)
            }
            .buttonStyle(.plain)
            .disabled(!hasCustomModelInput)
        }
        .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
        .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
    }

    private var hasCustomModelInput: Bool {
        !customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func modelRow(_ option: EmotionAnalysisModel) -> some View {
        Button(action: { selectModel(option) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model == option ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)

                Text(option.displayName)
                    .panelFont(size: 11, weight: .medium)
                    .foregroundColor(model == option ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(model == option ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    private var fallbackStatusText: String {
        if provider == .claude, hasClaudeCodeFallback {
            return "Claude Code"
        }
        return String(localized: "Missing")
    }

    private var fallbackStatusColor: Color {
        provider == .claude && hasClaudeCodeFallback ? TerminalColors.green : TerminalColors.red
    }

    private var hasClaudeCodeFallback: Bool {
        ClaudeSettingsConfig.existsAtDefaultLocation()
    }

    private var canTest: Bool {
        hasApiKey || (provider == .claude && hasClaudeCodeFallback)
    }

    private var isTesting: Bool {
        if case .testing = testState {
            return true
        }
        return false
    }

    private func selectProvider(_ newProvider: EmotionAnalysisProvider) {
        blurAPIKeyField()
        guard newProvider != provider else { return }
        saveApiKey(for: provider)
        saveBaseURL(for: provider)
        provider = newProvider
        AppSettings.emotionAnalysisProvider = newProvider
        model = AppSettings.selectedEmotionAnalysisModel(for: newProvider)
        apiKeyInput = AppSettings.apiKey(for: newProvider) ?? ""
        baseURLInput = AppSettings.apiBaseURL(for: newProvider) ?? ""
        customModelInput = ""
        resetTestState()
        resetCatalogState()
    }

    private func selectModel(_ newModel: EmotionAnalysisModel) {
        blurAPIKeyField()
        isCustomModelFocused = false
        guard newModel != model else { return }
        model = newModel
        AppSettings.setEmotionAnalysisModel(newModel, for: provider)
        resetTestState()
    }

    private func commitCustomModel() {
        let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectModel(EmotionAnalysisModel.resolve(trimmed, for: provider))
        customModelInput = ""
        isCustomModelFocused = false
    }

    private func refreshModelCatalog() {
        blurAPIKeyField()
        guard !isFetchingModels else { return }
        // Deliberately does not persist the base URL: a refresh could then clear a stored one.
        catalogState = .loading

        let currentProvider = provider
        let currentAPIKey = apiKeyInput
        let currentBaseURL = baseURLInput

        Task { @MainActor in
            do {
                let models = try await ModelCatalogService.shared.fetchModels(
                    provider: currentProvider,
                    apiKey: currentAPIKey,
                    baseURL: currentBaseURL
                )
                guard isCurrentCatalogSnapshot(provider: currentProvider, apiKey: currentAPIKey, baseURL: currentBaseURL) else { return }
                fetchedModels = models
                catalogState = .loaded(models.count)
                isModelPickerExpanded = true
            } catch {
                guard isCurrentCatalogSnapshot(provider: currentProvider, apiKey: currentAPIKey, baseURL: currentBaseURL) else { return }
                catalogState = .failure(testErrorText(error))
            }
        }
    }

    private func resetCatalogState() {
        catalogState = .idle
        fetchedModels = []
    }

    private func isCurrentCatalogSnapshot(
        provider: EmotionAnalysisProvider,
        apiKey: String,
        baseURL: String
    ) -> Bool {
        self.provider == provider && apiKeyInput == apiKey && baseURLInput == baseURL
    }

    private func saveApiKey(for provider: EmotionAnalysisProvider) {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.setApiKey(trimmed.isEmpty ? nil : trimmed, for: provider)
    }

    private func saveBaseURL(for provider: EmotionAnalysisProvider) {
        AppSettings.setApiBaseURL(baseURLInput, for: provider)
    }

    private func openAPIKeyPage() {
        blurAPIKeyField()
        NSWorkspace.shared.open(provider.apiKeyURL)
    }

    private func testEmotionAnalysis() {
        blurAPIKeyField()
        guard !isTesting else { return }
        testState = .testing

        let currentProvider = provider
        let currentModel = model
        let currentAPIKey = apiKeyInput
        let currentBaseURL = baseURLInput

        Task { @MainActor in
            do {
                let result = try await EmotionAnalyzer.shared.testConfiguration(
                    provider: currentProvider,
                    model: currentModel,
                    apiKey: currentAPIKey,
                    baseURL: currentBaseURL
                )
                guard isCurrentTestSnapshot(provider: currentProvider, model: currentModel, apiKey: currentAPIKey, baseURL: currentBaseURL) else { return }
                testState = .success(result)
            } catch {
                guard isCurrentTestSnapshot(provider: currentProvider, model: currentModel, apiKey: currentAPIKey, baseURL: currentBaseURL) else { return }
                testState = .failure(testErrorText(error))
            }
        }
    }

    private func resetTestState() {
        testState = .idle
    }

    private func isCurrentTestSnapshot(
        provider: EmotionAnalysisProvider,
        model: EmotionAnalysisModel,
        apiKey: String,
        baseURL: String
    ) -> Bool {
        self.provider == provider && self.model == model && apiKeyInput == apiKey && baseURLInput == baseURL
    }

    private func blurAPIKeyField() {
        isAPIKeyFocused = false
    }

    private func testResultText(_ result: EmotionAnalysisTestResult) -> String {
        "\(result.emotion.capitalized) \(String(format: "%.2f", result.intensity)) - \(result.latencyMilliseconds)ms"
    }

    private func testErrorText(_ error: Error) -> String {
        if let requestError = error as? EmotionAnalysisRequestError {
            return requestError.shortLabel
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return String(localized: "Offline")
            case .timedOut:
                return String(localized: "Timeout")
            default:
                return String(localized: "Failed")
            }
        }

        return String(localized: "Failed")
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        SettingsStatusBadge(text: text, color: color)
    }
}

private struct HorizontalShake: GeometryEffect {
    var travelDistance: CGFloat = 3
    var cyclesPerUnit: CGFloat = 1
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travelDistance * sin(animatableData * .pi * 2 * cyclesPerUnit),
                y: 0
            )
        )
    }
}

enum SettingsScreen: Equatable {
    case general
    case appearance
    case emotionAnalysis
}

enum SettingsBackAction: Equatable {
    case popScreen
    case exitSettings
}

extension SettingsScreen {
    static func backAction(for path: [SettingsScreen]) -> SettingsBackAction {
        path.isEmpty ? .exitSettings : .popScreen
    }
}

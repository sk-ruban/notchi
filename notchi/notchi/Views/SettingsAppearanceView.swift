import SwiftUI

struct SettingsAppearanceView: View {
    @AppStorage(AppSettings.showSpriteWhenIdleKey) private var showSpriteWhenIdle = true
    @AppStorage(AppSettings.showGrassIslandKey) private var showGrassIsland = true
    @AppStorage(AppSettings.showGitBranchAndPullRequestKey) private var showGitBranchAndPullRequest = true

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            IslandBackgroundSettingsView()

            Divider().background(Color.white.opacity(0.08))

            ScreenPickerRow(screenSelector: ScreenSelector.shared)

            PanelSizeSettingsView()

            MainUsageBarSettingsView()

            Divider().background(Color.white.opacity(0.08))

            Button(action: { showSpriteWhenIdle.toggle() }) {
                SettingsRowView(icon: "pip.exit", title: "Show Sprite When Idle") {
                    ToggleSwitch(isOn: showSpriteWhenIdle)
                }
            }
            .buttonStyle(.plain)

            Button(action: { showGrassIsland.toggle() }) {
                SettingsRowView(icon: "leaf", title: "Show Island") {
                    ToggleSwitch(isOn: showGrassIsland)
                }
            }
            .buttonStyle(.plain)

            Button(action: { showGitBranchAndPullRequest.toggle() }) {
                SettingsRowView(icon: "arrow.triangle.branch", title: "Show Git Branch & PR") {
                    ToggleSwitch(isOn: showGitBranchAndPullRequest)
                }
            }
            .buttonStyle(.plain)

            Divider().background(Color.white.opacity(0.08))

            NotchLayoutSettingsView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PanelSizeSettingsView: View {
    @AppStorage(AppSettings.expandedPanelScaleKey) private var scaleRaw = ExpandedPanelScale.automatic.rawValue
    @State private var isExpanded = false

    private var scale: ExpandedPanelScale { ExpandedPanelScale(rawValue: scaleRaw) ?? .automatic }

    private func resolvedName(for option: ExpandedPanelScale) -> String {
        option.resolved(visibleScreenHeight: NotchPanelManager.shared.visibleScreenHeight).displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                SettingsRowView(icon: "arrow.up.left.and.arrow.down.right", title: "Panel Size") {
                    HStack(spacing: 4) {
                        Text(scale.displayName)
                            .panelFont(size: 11)
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .panelFont(size: 9)
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: SettingsLayout.pickerRowSpacing) {
                    ForEach(ExpandedPanelScale.allCases) { option in
                        optionRow(option)
                    }
                }
                .padding(.vertical, SettingsLayout.pickerInset)
                .background(TerminalColors.subtleBackground)
                .cornerRadius(8)
                .padding(.top, SettingsLayout.pickerInset)
            }
        }
        .animation(.spring(response: 0.3), value: isExpanded)
    }

    private func optionRow(_ option: ExpandedPanelScale) -> some View {
        let isSelected = scale == option
        return Button(action: {
            AppSettings.expandedPanelScale = option
            isExpanded = false
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)
                Text(option.displayName)
                    .panelFont(size: 11, weight: .medium)
                    .foregroundColor(isSelected ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    .lineLimit(1)
                Spacer()
                if option == .automatic {
                    Text(resolvedName(for: option))
                        .panelFont(size: 9)
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(isSelected ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MainUsageBarSettingsView: View {
    @AppStorage(AppSettings.mainUsageBarPeriodKey) private var periodRaw = MainUsageBarPeriod.session.rawValue
    @State private var isExpanded = false

    private var period: MainUsageBarPeriod { AppSettings.mainUsageBarPeriod(fromRaw: periodRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                SettingsRowView(icon: "chart.bar.xaxis", title: "Main Usage Bar") {
                    HStack(spacing: 4) {
                        Text(period.displayName)
                            .panelFont(size: 11)
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .panelFont(size: 9)
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                SettingsPicker(rowCount: MainUsageBarPeriod.allCases.count) {
                    ForEach(MainUsageBarPeriod.allCases) { option in
                        optionRow(option)
                    }
                }
            }
        }
        .animation(.spring(response: 0.3), value: isExpanded)
    }

    private func optionRow(_ option: MainUsageBarPeriod) -> some View {
        let isSelected = period == option
        return Button(action: {
            AppSettings.mainUsageBarPeriod = option
            isExpanded = false
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)
                Text(option.displayName)
                    .panelFont(size: 11, weight: .medium)
                    .foregroundColor(isSelected ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(isSelected ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NotchLayoutSettingsView: View {
    private enum Side { case left, right }

    @AppStorage(AppSettings.notchLeftContentKey) private var leftRaw = NotchSlotContent.ring.rawValue
    @AppStorage(AppSettings.notchRightContentKey) private var rightRaw = NotchSlotContent.latest.rawValue
    @State private var isLeftExpanded = false
    @State private var isRightExpanded = false

    private var left: NotchSlotContent { NotchSlotContent(rawValue: leftRaw) ?? .ring }
    private var right: NotchSlotContent { NotchSlotContent(rawValue: rightRaw) ?? .latest }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            sideRow(.left, icon: "rectangle.lefthalf.filled", title: "Notch Left", isExpanded: $isLeftExpanded)
            sideRow(.right, icon: "rectangle.righthalf.filled", title: "Notch Right", isExpanded: $isRightExpanded)
        }
        .animation(.spring(response: 0.3), value: isLeftExpanded)
        .animation(.spring(response: 0.3), value: isRightExpanded)
    }

    @ViewBuilder
    private func sideRow(_ side: Side, icon: String, title: LocalizedStringKey, isExpanded: Binding<Bool>) -> some View {
        let selection = side == .left ? left : right
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isExpanded.wrappedValue.toggle() }) {
                SettingsRowView(icon: icon, title: title) {
                    HStack(spacing: 4) {
                        Text(selection.displayName)
                            .panelFont(size: 11)
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                            .panelFont(size: 9)
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                picker(side)
            }
        }
    }

    private func picker(_ side: Side) -> some View {
        SettingsPicker(rowCount: NotchSlotContent.allCases.count) {
            ForEach(NotchSlotContent.allCases) { option in
                optionRow(side, option: option)
            }
        }
    }

    private func optionRow(_ side: Side, option: NotchSlotContent) -> some View {
        let selection = side == .left ? left : right
        let other = side == .left ? right : left
        let isSelected = selection == option
        let hint = pickHint(option: option, isSelected: isSelected, other: other)
        return Button(action: { select(option, for: side) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)
                Text(option.displayName)
                    .panelFont(size: 11, weight: .medium)
                    .foregroundColor(isSelected ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    .lineLimit(1)
                Spacer()
                if let hint {
                    Text(hint)
                        .panelFont(size: 9)
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(isSelected ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickHint(option: NotchSlotContent, isSelected: Bool, other: NotchSlotContent) -> String? {
        guard !isSelected else { return nil }
        if option == other, other != .nothing { return String(localized: "Swap") }
        if NotchSlotContent.conflict(option, other) { return String(localized: "Replace") }
        return nil
    }

    private func select(_ option: NotchSlotContent, for side: Side) {
        switch side {
        case .left:
            AppSettings.notchLeftContent = option
            isLeftExpanded = false
        case .right:
            AppSettings.notchRightContent = option
            isRightExpanded = false
        }
    }

}

private struct IslandBackgroundSettingsView: View {
    @AppStorage(AppSettings.islandBackgroundKey) private var backgroundRaw = IslandBackground.grassland.rawValue

    private var selection: IslandBackground { IslandBackground.resolve(backgroundRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.pickerInset) {
            SettingsRowView(icon: "photo", title: "Island Background") {
                if selection == .automatic {
                    Text("Cycles every 30 min")
                        .panelFont(size: 11)
                        .foregroundColor(TerminalColors.secondaryText)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                ForEach(IslandBackground.allCases) { option in
                    Button(action: { AppSettings.islandBackground = option }) {
                        preview(for: option)
                            .frame(height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                            .frame(maxWidth: .infinity)
                            .background(TerminalColors.subtleBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selection == option ? TerminalColors.green : .clear, lineWidth: 1)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NoHighlightButtonStyle())
                    .frame(maxWidth: .infinity)
                    .help(option.displayName)
                    .accessibilityLabel(option.displayName)
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private func preview(for option: IslandBackground) -> some View {
        if option == .automatic {
            HStack(spacing: 0) {
                ForEach(IslandBackground.terrains) { terrain in
                    IslandBackgroundView(background: terrain)
                }
            }
            .overlay {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.55), in: Circle())
            }
        } else {
            IslandBackgroundView(background: option)
        }
    }
}

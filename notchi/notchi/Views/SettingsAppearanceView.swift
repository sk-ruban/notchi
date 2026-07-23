import SwiftUI

struct SettingsAppearanceView: View {
    @AppStorage(AppSettings.hideSpriteWhenIdleKey) private var hideSpriteWhenIdle = false
    @AppStorage(AppSettings.hideGrassIslandKey) private var hideGrassIsland = false
    @AppStorage(AppSettings.expandOnHoverKey) private var expandOnHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Button(action: { hideSpriteWhenIdle.toggle() }) {
                SettingsRowView(icon: "pip.exit", title: "Hide Sprite When Idle") {
                    ToggleSwitch(isOn: hideSpriteWhenIdle)
                }
            }
            .buttonStyle(.plain)

            Button(action: { hideGrassIsland.toggle() }) {
                SettingsRowView(icon: "leaf", title: "Hide Grass Island") {
                    ToggleSwitch(isOn: hideGrassIsland)
                }
            }
            .buttonStyle(.plain)

            Button(action: { expandOnHover.toggle() }) {
                SettingsRowView(icon: "cursorarrow.motionlines", title: "Expand on Hover") {
                    ToggleSwitch(isOn: expandOnHover)
                }
            }
            .buttonStyle(.plain)

            NotchLayoutSettingsView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                            .font(.system(size: 11))
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(NotchSlotContent.allCases) { option in
                    optionRow(side, option: option)
                }
            }
            .padding(.vertical, SettingsLayout.pickerInset)
        }
        .frame(height: pickerHeight(optionCount: NotchSlotContent.allCases.count))
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    .lineLimit(1)
                Spacer()
                if let hint {
                    Text(hint)
                        .font(.system(size: 9))
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
        if option == other, other != .nothing { return String(localized: "swap") }
        if NotchSlotContent.conflict(option, other) { return String(localized: "replace") }
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

    private func pickerHeight(optionCount: Int) -> CGFloat {
        let rowHeight: CGFloat = 28
        let rowSpacing: CGFloat = 4
        let visibleCount = min(optionCount, 6)
        return CGFloat(visibleCount) * rowHeight + CGFloat(max(visibleCount - 1, 0)) * rowSpacing
    }
}

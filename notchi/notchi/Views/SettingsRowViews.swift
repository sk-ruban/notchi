import SwiftUI

struct NoHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Image previews and sprite targets should retain their colors while pressed.
        configuration.label
    }
}

struct SettingsStatusBadge: View {
    let text: String
    let color: Color

    @Environment(\.panelScale) private var panelScale

    var body: some View {
        Text(text)
            .panelFont(size: 10, weight: .medium)
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
            .frame(maxWidth: 160 * panelScale, alignment: .trailing)
    }
}

struct SettingsRowView<Trailing: View>: View {
    private enum Icon {
        case symbol(String)
        /// A template image in the asset catalog, for icons SF Symbols doesn't have.
        case asset(String)
    }

    private let icon: Icon
    let title: LocalizedStringKey
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.panelScale) private var panelScale

    private static var iconSize: CGFloat { 12 }
    // SF Symbols at a 12pt font draw about 16pt wide, so an image icon needs a bigger box to match them.
    private static var assetIconSize: CGFloat { 16 }
    private static var iconColumnWidth: CGFloat { 20 }

    init(icon: String, title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = .symbol(icon)
        self.title = title
        self.trailing = trailing
    }

    init(assetIcon: String, title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = .asset(assetIcon)
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            iconView
                .foregroundColor(TerminalColors.secondaryText)
                .frame(width: Self.iconColumnWidth * panelScale)

            Text(title)
                .panelFont(size: 12)
                .foregroundColor(TerminalColors.primaryText)

            Spacer()

            trailing()
        }
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .panelIcon(size: Self.iconSize)
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.assetIconSize * panelScale, height: Self.assetIconSize * panelScale)
        }
    }
}

struct ToggleSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? TerminalColors.green : Color.white.opacity(0.15))
                .frame(width: 32, height: 18)

            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

struct SettingsPicker<Content: View>: View {
    let rowCount: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if let viewportHeight = SettingsLayout.pickerViewportHeight(rowCount: rowCount) {
                ScrollView {
                    rows
                }
                .frame(height: viewportHeight)
            } else {
                rows
            }
        }
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.pickerRowSpacing) {
            content()
        }
        .padding(.vertical, SettingsLayout.pickerInset)
    }
}

/// The current value and expand chevron on the right of a collapsible picker's row.
struct SettingsPickerValue: View {
    let value: String
    let isExpanded: Bool
    var lineLimit: Int?
    var truncationMode: Text.TruncationMode = .tail

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .panelFont(size: 11)
                .foregroundColor(TerminalColors.secondaryText)
                .lineLimit(lineLimit)
                .truncationMode(truncationMode)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .panelFont(size: 9)
                .foregroundColor(TerminalColors.dimmedText)
        }
    }
}

/// The row that expands or collapses a settings picker.
struct SettingsPickerHeader: View {
    let icon: String
    let title: LocalizedStringKey
    let value: String
    let isExpanded: Bool
    var valueLineLimit: Int?
    var valueTruncationMode: Text.TruncationMode = .tail
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRowView(icon: icon, title: title) {
                SettingsPickerValue(
                    value: value,
                    isExpanded: isExpanded,
                    lineLimit: valueLineLimit,
                    truncationMode: valueTruncationMode
                )
            }
        }
        .buttonStyle(.plain)
    }
}

/// One choice in a `SettingsPicker`, with an optional dimmed hint on the right.
struct SettingsPickerOption: View {
    let title: String
    let isSelected: Bool
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)
                Text(title)
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
}

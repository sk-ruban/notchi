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

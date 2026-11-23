import SwiftUI

/// Name and color for one Claude account, opened from its row in Providers.
struct ClaudeAccountSettingsView: View {
    static func displayPath(for directory: URL) -> String {
        (directory.path as NSString).abbreviatingWithTildeInPath
    }

    let accountId: String

    @State private var nameInput = ""
    @FocusState private var isNameFocused: Bool
    @Environment(\.panelScale) private var panelScale

    private static let swatchSize: CGFloat = 16
    private static let nameFieldMaxWidth: CGFloat = 160
    private static let selectedRingWidth: CGFloat = 2
    private static let selectedRingInset: CGFloat = -3

    private var account: ClaudeAccount? {
        ClaudeAccountStore.shared.accounts.first { $0.id == accountId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            if let account {
                SettingsRowView(icon: "person", title: "Name") {
                    nameField
                        .frame(maxWidth: Self.nameFieldMaxWidth * panelScale)
                }

                SettingsRowView(icon: "paintpalette", title: "Color") {
                    HStack(spacing: 8 * panelScale) {
                        ForEach(ClaudeAccountColor.allCases, id: \.self) { color in
                            swatch(color, isSelected: color == account.color, account: account)
                        }
                    }
                }

                SettingsRowView(icon: "folder", title: "Folder") {
                    Text(Self.displayPath(for: account.directory))
                        .panelFont(size: 10, design: .monospaced)
                        .foregroundColor(TerminalColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("This account is no longer on this Mac.")
                    .panelFont(size: 11)
                    .foregroundColor(TerminalColors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { nameInput = account?.name ?? "" }
        .onChange(of: isNameFocused) { _, focused in
            if !focused { saveName() }
        }
        .onDisappear(perform: saveName)
    }

    private var nameField: some View {
        TextField("", text: $nameInput)
            .textFieldStyle(.plain)
            .panelFont(size: 11)
            .foregroundColor(TerminalColors.primaryText)
            .padding(.horizontal, SettingsLayout.fieldHorizontalPadding)
            .padding(.vertical, SettingsLayout.fieldVerticalPadding)
            .background(Color.white.opacity(0.06))
            .cornerRadius(6)
            .focused($isNameFocused)
            .onSubmit(saveName)
    }

    private func swatch(_ color: ClaudeAccountColor, isSelected: Bool, account: ClaudeAccount) -> some View {
        Button(action: { ClaudeAccountStore.shared.setColor(color, for: account) }) {
            Circle()
                .fill(color.color)
                .frame(width: Self.swatchSize * panelScale, height: Self.swatchSize * panelScale)
                .overlay {
                    if isSelected {
                        Circle()
                            .stroke(Color.white, lineWidth: Self.selectedRingWidth)
                            .padding(Self.selectedRingInset)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.displayName)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func saveName() {
        guard let account, nameInput != account.name else { return }
        ClaudeAccountStore.shared.rename(account, to: nameInput)
        nameInput = ClaudeAccountStore.shared.accounts.first { $0.id == accountId }?.name ?? nameInput
    }
}

import SwiftUI

struct SkinPickerRow: View {
    @State private var isPickerExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
            if isPickerExpanded {
                expandedPicker
            }
        }
        .animation(.spring(response: 0.3), value: isPickerExpanded)
    }

    private var collapsedRow: some View {
        Button(action: {
            isPickerExpanded.toggle()
        }) {
            HStack {
                Image(systemName: "paintbrush")
                    .font(.system(size: 12))
                    .foregroundColor(TerminalColors.secondaryText)
                    .frame(width: 20)

                Text("Skin")
                    .font(.system(size: 12))
                    .foregroundColor(TerminalColors.primaryText)

                Spacer()

                HStack(spacing: 4) {
                    Text(currentSkinLabel)
                        .font(.system(size: 11))
                        .foregroundColor(TerminalColors.secondaryText)
                    Image(systemName: isPickerExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .padding(.vertical, SettingsLayout.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var expandedPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SkinManager.shared.availableSkins) { skin in
                skinRow(skin)
            }

            Button(action: openSkinsFolder) {
                HStack {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundColor(TerminalColors.dimmedText)

                    Text("Open Skins Folder")
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.secondaryText)

                    Spacer()
                }
                .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
                .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
                .contentShape(Rectangle())
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, SettingsLayout.pickerInset)
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
    }

    private func skinRow(_ skin: DiscoveredSkin) -> some View {
        Button(action: {
            selectSkin(skin)
        }) {
            HStack {
                Circle()
                    .fill(SkinManager.shared.selectedSkinName == skin.id ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(skin.name)
                        .font(.system(size: 11))
                        .foregroundColor(SkinManager.shared.selectedSkinName == skin.id ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    if !skin.isDefault, let author = skin.manifest?.author {
                        Text("by \(author)")
                            .font(.system(size: 9))
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }

                Spacer()

                if SkinManager.shared.selectedSkinName == skin.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(SkinManager.shared.selectedSkinName == skin.id ? TerminalColors.hoverBackground : Color.clear)
            .contentShape(Rectangle())
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private var currentSkinLabel: String {
        SkinManager.shared.availableSkins.first(where: { $0.id == SkinManager.shared.selectedSkinName })?.name ?? "Default"
    }

    private func selectSkin(_ skin: DiscoveredSkin) {
        SkinManager.shared.selectedSkinName = skin.id
        collapseAfterDelay()
    }

    private func openSkinsFolder() {
        NSWorkspace.shared.open(SkinManager.shared.skinsDirectoryURL)
    }

    private func collapseAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            isPickerExpanded = false
        }
    }
}

#Preview {
    SkinPickerRow()
        .frame(width: 300)
        .padding()
        .background(Color.black)
}

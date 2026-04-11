import SwiftUI

struct ScreenPickerRow: View {
    @ObservedObject var screenSelector: ScreenSelector

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
            if screenSelector.isPickerExpanded {
                expandedPicker
            }
        }
        .animation(.spring(response: 0.3), value: screenSelector.isPickerExpanded)
    }

    private var collapsedRow: some View {
        Button(action: {
            screenSelector.isPickerExpanded.toggle()
        }) {
            HStack {
                Image(systemName: "display")
                    .font(.system(size: 12))
                    .foregroundColor(TerminalColors.secondaryText)
                    .frame(width: 20)

                Text("Screen")
                    .font(.system(size: 12))
                    .foregroundColor(TerminalColors.primaryText)

                Spacer()

                HStack(spacing: 4) {
                    Text(currentSelectionLabel)
                        .font(.system(size: 11))
                        .foregroundColor(TerminalColors.secondaryText)
                        .lineLimit(1)
                    Image(systemName: screenSelector.isPickerExpanded ? "chevron.up" : "chevron.down")
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
            screenOptionRow(
                label: "Automatic",
                sublabel: "Built-in or Main",
                isSelected: screenSelector.selectionMode == .automatic
            ) {
                screenSelector.selectAutomatic()
                triggerWindowRecreation()
                collapseAfterDelay()
            }

            ForEach(screenSelector.availableScreens, id: \.self) { screen in
                screenOptionRow(
                    label: screen.localizedName,
                    sublabel: screenSublabel(for: screen),
                    isSelected: screenSelector.selectionMode == .specificScreen &&
                               screenSelector.isSelected(screen)
                ) {
                    screenSelector.selectScreen(screen)
                    triggerWindowRecreation()
                    collapseAfterDelay()
                }
            }
        }
        .padding(.vertical, SettingsLayout.pickerInset)
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
    }

    private func screenOptionRow(
        label: String,
        sublabel: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? TerminalColors.primaryText : TerminalColors.secondaryText)

                    if let sublabel = sublabel {
                        Text(sublabel)
                            .font(.system(size: 9))
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(isSelected ? TerminalColors.hoverBackground : Color.clear)
            .contentShape(Rectangle())
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private var currentSelectionLabel: String {
        if screenSelector.selectionMode == .automatic {
            return "Auto"
        }
        return screenSelector.selectedScreen?.localizedName ?? "Auto"
    }

    private func screenSublabel(for screen: NSScreen) -> String? {
        var parts: [String] = []
        if screen.isBuiltIn {
            parts.append("Built-in")
        }
        if screen == NSScreen.main {
            parts.append("Main")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func triggerWindowRecreation() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func collapseAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            screenSelector.isPickerExpanded = false
        }
    }
}

#Preview {
    ScreenPickerRow(screenSelector: ScreenSelector.shared)
        .frame(width: 300)
        .padding()
        .background(Color.black)
}

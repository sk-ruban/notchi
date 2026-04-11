import SwiftUI

struct SoundPickerView: View {
    @State private var selector = SoundSelector()
    @State private var selectedSound = AppSettings.notificationSound

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
            if selector.isPickerExpanded {
                expandedPicker
            }
        }
        .animation(.spring(response: 0.3), value: selector.isPickerExpanded)
    }

    private var collapsedRow: some View {
        Button(action: {
            selector.isPickerExpanded.toggle()
        }) {
            HStack {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 12))
                    .foregroundColor(TerminalColors.secondaryText)
                    .frame(width: 20)

                Text("Notification Sound")
                    .font(.system(size: 12))
                    .foregroundColor(TerminalColors.primaryText)

                Spacer()

                HStack(spacing: 4) {
                    Text(AppSettings.isMuted ? "Muted" : selectedSound.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(TerminalColors.secondaryText)
                    Image(systemName: selector.isPickerExpanded ? "chevron.up" : "chevron.down")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(NotificationSound.allCases, id: \.self) { sound in
                    soundRow(sound)
                }
            }
            .padding(.vertical, SettingsLayout.pickerInset)
        }
        .frame(height: selector.expandedHeight)
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
    }

    private func soundRow(_ sound: NotificationSound) -> some View {
        Button(action: {
            selectSound(sound)
        }) {
            HStack {
                Circle()
                    .fill(selectedSound == sound ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)

                Text(sound.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(selectedSound == sound ? TerminalColors.primaryText : TerminalColors.secondaryText)

                Spacer()

                if sound != .none {
                    Image(systemName: "speaker.wave.1")
                        .font(.system(size: 9))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(selectedSound == sound ? TerminalColors.hoverBackground : Color.clear)
            .contentShape(Rectangle())
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func selectSound(_ sound: NotificationSound) {
        selectedSound = sound
        AppSettings.notificationSound = sound
        SoundService.shared.previewSound(sound)
    }
}

#Preview {
    SoundPickerView()
        .frame(width: 300)
        .padding()
        .background(Color.black)
}

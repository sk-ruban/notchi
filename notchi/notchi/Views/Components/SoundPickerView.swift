import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SoundPickerView: View {
    @State private var selector = SoundSelector()
    @State private var selectedSound = AppSettings.notificationSoundSelection
    @State private var customSounds = AppSettings.customNotificationSounds
    @State private var importErrorMessage: String?
    @State private var editingSoundID: UUID?
    @State private var editingSoundName = ""
    @State private var inlineRenameEventMonitor: Any?
    @FocusState private var focusedRenameSoundID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
            if selector.isPickerExpanded {
                expandedPicker
            }
        }
        .animation(.spring(response: 0.3), value: selector.isPickerExpanded)
        .onChange(of: focusedRenameSoundID) { _, newValue in
            if newValue == nil {
                commitInlineRename()
            }
        }
        .onDisappear {
            removeInlineRenameMonitor()
        }
        .alert("Sound Import Failed", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
    }

    private var collapsedRow: some View {
        Button(action: {
            commitInlineRename()
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
                    Text(AppSettings.isMuted ? String(localized: "Muted") : selectedSound.displayName(customSounds: customSounds))
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
                addCustomSoundRow

                ForEach(customSounds) { sound in
                    customSoundRow(sound)
                }

                ForEach(NotificationSound.displayOrder, id: \.self) { sound in
                    soundRow(sound)
                }
            }
            .padding(.vertical, SettingsLayout.pickerInset)
        }
        .frame(height: selector.expandedHeight(customSoundCount: customSounds.count))
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
    }

    private var addCustomSoundRow: some View {
        Button(action: addCustomSound) {
            HStack {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(TerminalColors.green)
                    .frame(width: 6, height: 6)

                Text("Add")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.primaryText)

                Spacer()
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .contentShape(Rectangle())
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func soundRow(_ sound: NotificationSound) -> some View {
        Button(action: {
            selectSound(sound)
        }) {
            HStack {
                Circle()
                    .fill(selectedSound == .system(sound) ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)

                Text(sound.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(selectedSound == .system(sound) ? TerminalColors.primaryText : TerminalColors.secondaryText)

                Spacer()

                if sound != .none {
                    Image(systemName: "speaker.wave.1")
                        .font(.system(size: 9))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(selectedSound == .system(sound) ? TerminalColors.hoverBackground : Color.clear)
            .contentShape(Rectangle())
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func customSoundRow(_ sound: CustomNotificationSound) -> some View {
        HStack(spacing: 8) {
            if editingSoundID == sound.id {
                HStack {
                    Circle()
                        .fill(selectedSound == .custom(sound.id) ? TerminalColors.green : Color.clear)
                        .frame(width: 6, height: 6)

                    TextField("", text: $editingSoundName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(TerminalColors.primaryText)
                        .accessibilityIdentifier(renameAccessibilityIdentifier(for: sound.id))
                        .focused($focusedRenameSoundID, equals: sound.id)
                        .onSubmit {
                            commitInlineRename()
                        }
                        .onExitCommand {
                            cancelInlineRename()
                        }

                    Spacer()
                }
            } else {
                Button(action: {
                    selectCustomSound(sound)
                }) {
                    HStack {
                        Circle()
                            .fill(selectedSound == .custom(sound.id) ? TerminalColors.green : Color.clear)
                            .frame(width: 6, height: 6)

                        Text(sound.displayName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundColor(selectedSound == .custom(sound.id) ? TerminalColors.primaryText : TerminalColors.secondaryText)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button(action: {
                beginInlineRename(sound)
            }) {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
                    .foregroundColor(TerminalColors.dimmedText)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)

            Button(action: {
                deleteCustomSound(sound)
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 9))
                    .foregroundColor(TerminalColors.dimmedText)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
        .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
        .background(selectedSound == .custom(sound.id) ? TerminalColors.hoverBackground : Color.clear)
        .contentShape(Rectangle())
        .cornerRadius(4)
    }

    private func selectSound(_ sound: NotificationSound) {
        commitInlineRename()
        selectedSound = .system(sound)
        AppSettings.notificationSoundSelection = selectedSound
        SoundService.shared.previewSound(selectedSound)
    }

    private func selectCustomSound(_ sound: CustomNotificationSound) {
        commitInlineRename()
        selectedSound = .custom(sound.id)
        AppSettings.notificationSoundSelection = selectedSound
        SoundService.shared.previewSound(selectedSound)
    }

    private func addCustomSound() {
        commitInlineRename()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let sound = try AppSettings.importCustomNotificationSound(from: url)
            refreshCustomSounds()
            selectCustomSound(sound)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func beginInlineRename(_ sound: CustomNotificationSound) {
        if editingSoundID == sound.id {
            focusedRenameSoundID = sound.id
            return
        }
        commitInlineRename()
        editingSoundID = sound.id
        editingSoundName = sound.displayName
        installInlineRenameMonitor()
        Task { @MainActor in
            focusedRenameSoundID = sound.id
        }
    }

    private func commitInlineRename() {
        guard let editingSoundID else { return }
        AppSettings.renameCustomNotificationSound(id: editingSoundID, displayName: editingSoundName)
        refreshCustomSounds()
        self.editingSoundID = nil
        editingSoundName = ""
        focusedRenameSoundID = nil
        removeInlineRenameMonitor()
    }

    private func cancelInlineRename() {
        editingSoundID = nil
        editingSoundName = ""
        focusedRenameSoundID = nil
        removeInlineRenameMonitor()
    }

    private func installInlineRenameMonitor() {
        removeInlineRenameMonitor()
        inlineRenameEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            Task { @MainActor in
                handleInlineRenameMouseDown(event)
            }
            return event
        }
    }

    private func removeInlineRenameMonitor() {
        guard let inlineRenameEventMonitor else { return }
        NSEvent.removeMonitor(inlineRenameEventMonitor)
        self.inlineRenameEventMonitor = nil
    }

    private func handleInlineRenameMouseDown(_ event: NSEvent) {
        guard let editingSoundID else { return }
        guard let hitView = event.window?.contentView?.hitTest(event.locationInWindow) else {
            commitInlineRename()
            return
        }

        if viewTreeContainsTextField(hitView) {
            return
        }

        if viewTreeContainsAccessibilityIdentifier(hitView, renameAccessibilityIdentifier(for: editingSoundID)) {
            return
        }

        commitInlineRename()
    }

    private func renameAccessibilityIdentifier(for id: UUID) -> String {
        "custom-sound-rename-\(id.uuidString)"
    }

    private func viewTreeContainsTextField(_ view: NSView) -> Bool {
        var currentView: NSView? = view
        while let view = currentView {
            if view is NSTextField {
                return true
            }
            currentView = view.superview
        }
        return false
    }

    private func viewTreeContainsAccessibilityIdentifier(_ view: NSView, _ identifier: String) -> Bool {
        var currentView: NSView? = view
        while let view = currentView {
            if view.accessibilityIdentifier() == identifier {
                return true
            }
            currentView = view.superview
        }
        return false
    }

    private func deleteCustomSound(_ sound: CustomNotificationSound) {
        if editingSoundID == sound.id {
            cancelInlineRename()
        } else {
            commitInlineRename()
        }
        AppSettings.deleteCustomNotificationSound(id: sound.id)
        refreshCustomSounds()
        selectedSound = AppSettings.notificationSoundSelection
    }

    private func refreshCustomSounds() {
        customSounds = AppSettings.customNotificationSounds
    }
}

#Preview {
    SoundPickerView()
        .frame(width: 300)
        .padding()
        .background(Color.black)
}

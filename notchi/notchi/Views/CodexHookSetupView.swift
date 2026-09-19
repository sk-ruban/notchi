import SwiftUI
import AppKit

struct CodexHookSetupView: View {
    let setup: CodexHookSetup?
    let isChecking: Bool
    let hasSession: Bool
    let recheck: () -> Void
    @State private var copied = false
    @State private var launchFailed = false
    @State private var isLaunching = false
    @Environment(\.panelScale) private var panelScale

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * panelScale) {
            Text(message)
                .panelFont(size: 10)
                .foregroundColor(TerminalColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if setup?.readiness != .approved, setup?.launchCommand != nil {
                VStack(alignment: .leading, spacing: 9 * panelScale) {
                    setupStep(1) {
                        Text("Open Codex in Terminal")
                    }
                    setupStep(2) {
                        Text("Run **/hooks** and approve all 3 Notchi hooks")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    setupStep(3) {
                        Text("Send a message in a new Codex chat")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 6 * panelScale) {
                if setup?.readiness != .approved, let command = setup?.launchCommand {
                    Button("Open in Terminal", action: openTerminal)
                        .buttonStyle(CodexSetupButtonStyle())
                        .disabled(isLaunching)
                    Button(copied ? "Copied" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .buttonStyle(CodexSetupButtonStyle())
                }

                Button(isChecking ? "Checking…" : "Check Again", action: recheck)
                    .buttonStyle(CodexSetupButtonStyle())
                    .disabled(isChecking)
            }

            if launchFailed {
                Text("Couldn’t open Terminal. Copy the command and paste it into your terminal instead.")
                    .panelFont(size: 10)
                    .foregroundColor(TerminalColors.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
        .padding(.bottom, 8 * panelScale)
    }

    private func setupStep<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8 * panelScale) {
            Text(number.formatted())
                .panelFont(size: 8, weight: .semibold)
                .foregroundColor(TerminalColors.secondaryText)
                .frame(width: 16 * panelScale, height: 16 * panelScale)
                .background(TerminalColors.hoverBackground, in: Circle())
                .accessibilityHidden(true)

            content()
                .panelFont(size: 10)
                .foregroundColor(TerminalColors.primaryText)
                .padding(.top, 1 * panelScale)
        }
    }

    private var message: String {
        guard let setup else { return String(localized: "Checking Codex approval…") }
        guard setup.executableURL != nil else {
            return String(localized: "Couldn’t find the Codex app or CLI. Install Codex, then check again.")
        }
        switch setup.readiness {
        case .approved:
            return hasSession
                ? String(localized: "Connected — Notchi has received activity from Codex.")
                : String(localized: "Approval complete. Start a new Codex chat and send a message to see your mascot. Existing chats may need to be reopened.")
        case .needsApproval:
            return String(localized: "Approve Notchi’s hooks to show your Codex mascot.")
        case .disabled:
            return String(localized: "Codex reports that Notchi’s hooks are disabled. Review them in /hooks. If your organization manages hooks, your administrator may need to enable them.")
        case .notRegistered:
            return String(localized: "Codex couldn’t find all three Notchi hooks. Turn the Codex toggle off and on to reinstall, then check again. If your organization restricts hooks, contact your administrator.")
        case .unverified:
            return String(localized: "Couldn’t verify Codex approval. Your Codex version may not support this check. Review /hooks if available, then try a new chat.")
        }
    }

    private func openTerminal() {
        guard let executable = setup?.executableURL else { return }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            launchFailed = true
            return
        }
        isLaunching = true
        Task { @MainActor in
            defer { isLaunching = false }
            do {
                let launcher = try CodexHookStatusService.writeLauncher(executable: executable)
                _ = try await NSWorkspace.shared.open(
                    [launcher],
                    withApplicationAt: terminal,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                launchFailed = false
            } catch {
                launchFailed = true
            }
        }
    }
}

private struct CodexSetupButtonStyle: ButtonStyle {
    @Environment(\.panelScale) private var panelScale
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .panelFont(size: 10, weight: .medium)
            .foregroundColor(TerminalColors.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 8 * panelScale)
            .padding(.vertical, 5 * panelScale)
            .background(
                isHovered || configuration.isPressed ? TerminalColors.hoverBackground : TerminalColors.subtleBackground,
                in: RoundedRectangle(cornerRadius: 4 * panelScale)
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .opacity(isEnabled ? 1 : 0.5)
    }
}

import ServiceManagement
import SwiftUI

struct PanelSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var hooksError = false
    @State private var apiKeyInput = AppSettings.anthropicApiKey ?? ""
    @State private var remoteTCPEnabled = AppSettings.isRemoteTCPEnabled
    @State private var copiedSetup = false
    @State private var copiedUninstall = false
    @ObservedObject private var updateManager = UpdateManager.shared
    private var usageConnected: Bool { ClaudeUsageService.shared.isConnected }
    private var hasApiKey: Bool { !apiKeyInput.isEmpty }

    private var hookStatusText: String {
        if hooksError { return "Error" }
        if hooksInstalled { return "Installed" }
        return "Not Installed"
    }

    private var hookStatusColor: Color {
        hooksInstalled && !hooksError ? TerminalColors.green : TerminalColors.red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    displaySection
                    Divider().background(Color.white.opacity(0.08))
                    togglesSection
                    Divider().background(Color.white.opacity(0.08))
                    actionsSection
                }
                .padding(.top, 10)
            }
            .scrollIndicators(.hidden)

            Spacer()

            quitSection
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenPickerRow(screenSelector: ScreenSelector.shared)

            SoundPickerView()
        }
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleLaunchAtLogin) {
                SettingsRowView(icon: "power", title: "Launch at Login") {
                    ToggleSwitch(isOn: launchAtLogin)
                }
            }
            .buttonStyle(.plain)

            Button(action: installHooksIfNeeded) {
                SettingsRowView(icon: "terminal", title: "Hooks") {
                    statusBadge(hookStatusText, color: hookStatusColor)
                }
            }
            .buttonStyle(.plain)

            Button(action: connectUsage) {
                SettingsRowView(icon: "gauge.with.dots.needle.33percent", title: "Claude Usage") {
                    statusBadge(
                        usageConnected ? "Connected" : "Not Connected",
                        color: usageConnected ? TerminalColors.green : TerminalColors.red
                    )
                }
            }
            .buttonStyle(.plain)

            apiKeyRow

            Button(action: toggleRemoteTCP) {
                SettingsRowView(icon: "network", title: "Remote Sessions") {
                    HStack(spacing: 4) {
                        if remoteTCPEnabled {
                            statusBadge("Port \(AppSettings.remoteTCPPort)", color: TerminalColors.green)
                        }
                        ToggleSwitch(isOn: remoteTCPEnabled)
                    }
                }
            }
            .buttonStyle(.plain)

            if remoteTCPEnabled {
                remoteSetupInfo
            }
        }
    }

    private var remoteSetupInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Show connected remotes
            if !SocketServer.shared.connectedRemotes.isEmpty {
                ForEach(Array(SocketServer.shared.connectedRemotes.sorted()), id: \.self) { ip in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                        Text(ip)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(TerminalColors.primaryText)

                        Spacer()

                        Button(action: { disconnectRemote(ip) }) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12))
                                .foregroundColor(TerminalColors.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 28)
                    .padding(.trailing, 4)
                }
            }

            // Show blocked remotes
            ForEach(Array(SocketServer.shared.blockedRemotes.sorted()), id: \.self) { ip in
                HStack(spacing: 6) {
                    Circle()
                        .fill(TerminalColors.red)
                        .frame(width: 6, height: 6)
                    Text(ip)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TerminalColors.dimmedText)
                        .strikethrough()

                    Spacer()

                    Button(action: { SocketServer.shared.unblockRemote(ip) }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 28)
                .padding(.trailing, 4)
            }

            // Show uninstall command hint
            if copiedUninstall {
                Text("Uninstall command copied — run on the remote machine")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.amber)
                    .padding(.leading, 28)
            }

            Text(SocketServer.shared.connectedRemotes.isEmpty ? "Run on remote machine:" : "Add another machine:")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.dimmedText)
                .padding(.leading, 28)

            HStack(spacing: 6) {
                Text(setupCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(TerminalColors.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Button(action: copySetupCommand) {
                    Image(systemName: copiedSetup ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(copiedSetup ? TerminalColors.green : TerminalColors.dimmedText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))
            .cornerRadius(6)
            .padding(.leading, 28)
        }
    }

    private var setupCommand: String {
        let host = detectedIP ?? "YOUR_MAC_IP"
        let port = AppSettings.remoteTCPPort
        return "curl -fsSL https://raw.githubusercontent.com/sk-ruban/notchi/main/scripts/remote-setup.sh | NOTCHI_HOST=\(host) NOTCHI_PORT=\(port) bash"
    }

    private var detectedIP: String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var tailscaleIP: String?
        var privateIP: String?

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr != nil,
                  addr.ifa_addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let ip = addr.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockAddr in
                UInt32(bigEndian: sockAddr.pointee.sin_addr.s_addr)
            }

            let a = (ip >> 24) & 0xFF
            let b = (ip >> 16) & 0xFF
            let c = (ip >> 8) & 0xFF
            let d = ip & 0xFF
            let ipStr = "\(a).\(b).\(c).\(d)"

            // Tailscale CGNAT range: 100.64.0.0/10
            if (ip & 0xFFC00000) == 0x64400000 {
                tailscaleIP = ipStr
            }
            // Private ranges: 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12
            else if (ip & 0xFFFF0000) == 0xC0A80000 ||  // 192.168.x.x
                    (ip & 0xFF000000) == 0x0A000000 ||   // 10.x.x.x
                    (ip & 0xFFF00000) == 0xAC100000 {    // 172.16-31.x.x
                if privateIP == nil { privateIP = ipStr }
            }
        }

        // Prefer Tailscale, then private LAN
        return tailscaleIP ?? privateIP
    }

    private static let uninstallCommand = """
        rm -f ~/.claude/hooks/notchi-hook.sh && \
        sed -i.bak '/NOTCHI_HOST/d;/NOTCHI_PORT/d;/Notchi remote/d' ~/.bashrc ~/.zshrc 2>/dev/null; \
        python3 -c "
        import json,os
        p=os.path.expanduser('~/.claude/settings.json')
        try:
         s=json.load(open(p))
         h=s.get('hooks',{})
         for e in list(h):
          h[e]=[x for x in h[e] if not any('notchi-hook.sh' in hk.get('command','') for hk in x.get('hooks',[]))]
          if not h[e]: del h[e]
         s['hooks']=h
         json.dump(s,open(p,'w'),indent=2,sort_keys=True)
        except: pass
        " && echo 'Notchi hook removed'
        """

    private func disconnectRemote(_ ip: String) {
        SocketServer.shared.removeRemote(ip)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.uninstallCommand, forType: .string)
        copiedUninstall = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            copiedUninstall = false
        }
    }

    private func copySetupCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupCommand, forType: .string)
        copiedSetup = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedSetup = false
        }
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRowView(icon: "brain", title: "Emotion Analysis") {
                statusBadge(
                    hasApiKey ? "Active" : "No Key",
                    color: hasApiKey ? TerminalColors.green : TerminalColors.red
                )
            }

            HStack(spacing: 6) {
                SecureField("", text: $apiKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TerminalColors.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .onSubmit { saveApiKey() }
                    .overlay(alignment: .leading) {
                        if apiKeyInput.isEmpty {
                            Text("Anthropic API Key")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(TerminalColors.dimmedText)
                                .padding(.leading, 8)
                                .allowsHitTesting(false)
                        }
                    }

                Button(action: saveApiKey) {
                    Image(systemName: hasApiKey ? "checkmark.circle.fill" : "arrow.right.circle")
                        .font(.system(size: 14))
                        .foregroundColor(hasApiKey ? TerminalColors.green : TerminalColors.dimmedText)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 28)
        }
    }

    private func saveApiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.anthropicApiKey = trimmed.isEmpty ? nil : trimmed
    }

    private func toggleRemoteTCP() {
        remoteTCPEnabled.toggle()
        AppSettings.isRemoteTCPEnabled = remoteTCPEnabled
        if remoteTCPEnabled {
            SocketServer.shared.startTCPServer(port: AppSettings.remoteTCPPort)
        } else {
            SocketServer.shared.stopTCPServer()
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { updateManager.checkForUpdates() }) {
                SettingsRowView(icon: "arrow.triangle.2.circlepath", title: "Check for Updates") {
                    updateStatusView
                }
            }
            .buttonStyle(.plain)

            Button(action: openGitHubRepo) {
                SettingsRowView(icon: "star", title: "Star on GitHub") {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func openGitHubRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sk-ruban/notchi")!)
    }

    private var quitSection: some View {
        Button(action: {
            NSApplication.shared.terminate(nil)
        }) {
            HStack {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                Text("Quit Notchi")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(TerminalColors.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(TerminalColors.red.opacity(0.1))
            .contentShape(Rectangle())
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }

    private func connectUsage() {
        ClaudeUsageService.shared.connectAndStartPolling()
    }

    private func installHooksIfNeeded() {
        guard !hooksInstalled else { return }
        hooksError = false
        let success = HookInstaller.installIfNeeded()
        if success {
            hooksInstalled = HookInstaller.isInstalled()
        } else {
            hooksError = true
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateManager.state {
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .upToDate:
            statusBadge("Up to date", color: TerminalColors.green)
        case .updateAvailable:
            statusBadge("Update available", color: TerminalColors.amber)
        case .downloading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .readyToInstall:
            statusBadge("Ready to install", color: TerminalColors.green)
        case .error(let message):
            statusBadge(message, color: TerminalColors.red)
        case .idle:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.dimmedText)
        }
    }
}

struct SettingsRowView<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.secondaryText)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.primaryText)

            Spacer()

            trailing()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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

#Preview {
    PanelSettingsView()
        .frame(width: 402, height: 400)
        .background(Color.black)
}

import AppKit

struct TerminalFocusDetector {
    // Keep focus detection and terminal jump targeting on the same supported app list.
    static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
        "com.raphaelamorim.rio",
        "org.tabby",
        "dev.commandline.waveterm",
        "dev.warp.Warp-Preview",
        "org.contourterminal.Contour",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce"
    ]

    static func isTerminalFocused() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontmostApp.bundleIdentifier else {
            return false
        }
        return terminalBundleIds.contains(bundleId)
    }
}

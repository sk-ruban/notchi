# Notchi

> [!IMPORTANT]
> If you're currently on Notchi `1.0.0`, please install `1.0.1` or later manually from the DMG [here](https://github.com/sk-ruban/notchi/releases/latest). The in-app updater in `1.0.0` is broken for that first upgrade, but should work thereafter.

A macOS notch companion that reacts to Claude Code activity in real-time.

https://github.com/user-attachments/assets/e417bd40-cae8-47c0-998a-905166cf3513

## What it does

- Reacts to Claude Code events in real-time (thinking, working, errors, completions)
- Analyzes conversation sentiment to show emotions (happy, sad, neutral, sob)
- Click to expand and see session time and usage quota
- Supports multiple concurrent Claude Code sessions with individual sprites
- Sound effects for events (optional, auto-muted when terminal is focused)
- Auto-updates via Sparkle

## Requirements

- macOS 15.0+ (Sequoia)
- MacBook with notch
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed

## Install

1. Download `Notchi-x.x.x.dmg` from the [latest GitHub Release](https://github.com/sk-ruban/notchi/releases/latest)
2. Open the DMG and drag Notchi to Applications
3. Launch Notchi — it auto-installs Claude Code hooks on first launch
4. A macOS keychain popup will appear asking to access Claude Code's cached OAuth token (used for API usage stats). Click **Always Allow** so it won't prompt again on future launches

   <img src="assets/keychain-popup.png" alt="Keychain access popup" width="450">

5. *(Optional)* Click the notch to expand → open Settings → paste your Anthropic API key. This enables sentiment analysis of your prompts so the mascot reacts emotionally

   <img src="assets/emotion-settings.png" alt="Emotion analysis settings" width="400">

6. Start using Claude Code and watch Notchi react

## How it works

```
Claude Code --> Hooks (shell scripts) --> Unix Socket --> Event Parser --> State Machine --> Animated Sprites
```

Notchi registers shell script hooks with Claude Code on launch. When Claude Code emits events (tool use, thinking, prompts, session start/end), the hook script sends JSON payloads to a Unix socket. The app parses these events, runs them through a state machine that maps to sprite animations (idle, working, sleeping, compacting, waiting), and uses the Anthropic API to analyze user prompt sentiment for emotional reactions.

Each Claude Code session gets its own sprite on the grass island. Clicking expands the notch panel to show a live activity feed, session info, and API usage stats.

## Contributing

If you have any bugs, ideas, or would like to contribute through pull requests, please check out [Contributing to Notchi](CONTRIBUTING.md).

## Community Ports

- [notchi-for-windows](https://github.com/AptatoX/notchi-for-windows) by [@AptatoX](https://github.com/AptatoX), a community-made Windows port of Notchi

## Credits

- [Claude Island](https://github.com/farouqaldori/claude-island) — design inspiration for the app
- [Readout](https://readout.org) — design inspiration for [notchi.app](https://notchi.app)
- [Aseprite](https://www.aseprite.org/) — sprite design

## License

GPL-3.0-only. See [LICENSE](LICENSE).

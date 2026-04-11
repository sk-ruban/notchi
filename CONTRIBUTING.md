# Contributing to Notchi

Thanks for your interest in contributing! This document covers how to report bugs, suggest features, and submit pull requests.

## Quick Guide

### I found a bug

Search [existing issues](https://github.com/sk-ruban/notchi/issues) first. If it hasn't been reported, open an issue with steps to reproduce, your macOS version, and any relevant logs.

### I have an idea for a feature

Open an issue describing what you'd like to see and why. Let's discuss scope and approach before any code gets written.

### I'd like to contribute code

1. Find an existing issue (or open one first to discuss your idea)
2. Comment on the issue to let others know you're working on it
3. Submit a PR that references the issue

Pull requests without a corresponding issue may be closed or sit indefinitely.

## Local Development

1. Clone the repo
2. Open `notchi/notchi.xcodeproj` in Xcode
3. Build and run (`⌘R`)

The app auto-installs Claude Code hooks on launch, so just start a Claude Code session to see it in action.

## Code Style

- Match existing patterns — read through the codebase before making changes
- `@MainActor` is the default isolation (project-wide setting)
- Prefer small, focused PRs over broad refactors
- Don't add unnecessary dependencies

## Hook Safety

**Never manually edit `~/.claude/settings.json`.** Hook changes go through:
- `notchi/notchi/Resources/notchi-hook.sh` (the hook script)
- `notchi/notchi/Services/HookInstaller.swift` (hook registration)

Rebuild and relaunch the app to apply hook changes.

## License

By contributing, you agree that your contributions will be licensed under GPL-3.0-only.

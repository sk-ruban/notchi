<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Notchi 1.3.0

This release adds Devin Desktop support with its own otter mascot, quota and cost tracking, labels Claude sessions with their Claude Code session names, and moves the hook socket to a private per-user location.

## Devin

- Tracks Devin Local sessions in Devin Desktop through hooks, installed automatically into `~/.config/devin/config.json`
- Adds otter sprites and a Devin Mascot slot in the notch
- Shows Devin's daily and weekly quota, rolling each window over once its reset time passes
- Shows "Teams plan · No daily or weekly quota" and ∞ for plans without a quota instead of full quota bars
- Adds a Devin cost chart and includes Devin in the All tab
- Fully quit and relaunch Devin Desktop after updating so it picks up the hooks. Devin Cloud sessions are not tracked yet

## Sessions

- Labels Claude sessions with their Claude Code session name, skipping generated names
- Ends Codex sessions when their thread is deleted in the Codex app
- Finds the Codex CLI bundled inside recent Codex desktop app builds, so hook approval verifies correctly
- Shows Installed for approved Codex hooks in Settings

## Prompt Bubble

- Truncates the collapsed prompt at a word boundary and keeps hover expansion inside the bubble
- Strips Claude Code's pasted content markup from prompts
- Keeps finished background subagent reports from replacing your last prompt

## Usage and Cost

- Shows ∞ in the collapsed ring for Codex accounts without a spending cap, and the ring now appears at 0% usage
- Refetches pricing when a scan finds unpriced models, without pausing scheduled scans

## Security

- Moves the hook socket from `/tmp` to an owner-only folder in `~/Library/Application Support/Notchi`, so other accounts on the Mac cannot receive hook events

## Localization

- Translates the Devin screens and the new quota labels into Japanese, Korean, Vietnamese, Simplified Chinese, and Traditional Chinese, and shows token counts in translations

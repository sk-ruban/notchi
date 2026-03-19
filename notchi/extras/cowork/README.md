# Notchi × Claude Cowork

Bridges **Claude Desktop's Cowork** (local agent mode) to the Notchi notch indicator, giving the same real-time status effect as Claude Code.

## How it works

Cowork stores each session under:

```
~/Library/Application Support/Claude/local-agent-mode-sessions/
  {machine-id}/{group-id}/
    local_{uuid}.json        ← session metadata (sessionId, cwd, isArchived, …)
    local_{uuid}/audit.jsonl ← append-only event log
```

`cowork-notchi-watcher.py` polls for new sessions and tails their `audit.jsonl`, translating events into Notchi's Unix socket protocol (`/tmp/notchi.sock`) — the same wire format used by `notchi-hook.sh` for Claude Code.

## Setup

### 1. Copy the watcher script

```bash
cp cowork-notchi-watcher.py ~/.claude/hooks/
chmod +x ~/.claude/hooks/cowork-notchi-watcher.py
```

### 2. Install the LaunchAgent (auto-start on login)

Edit `com.notchi.cowork-watcher.plist` and replace `YOUR_USERNAME` with your macOS username, then:

```bash
cp com.notchi.cowork-watcher.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.notchi.cowork-watcher.plist
```

### 3. Verify

```bash
launchctl list | grep cowork          # should show a PID
tail -f /tmp/cowork-notchi-watcher.log
```

Open a Cowork session — the Notchi notch should animate within a few seconds.

## Event mapping

| Cowork audit event | Notchi event | Status |
|---|---|---|
| `user` message (string content) | `UserPromptSubmit` | `processing` |
| `assistant` with `tool_use` | `PreToolUse` | `running_tool` |
| `user` with `tool_result` | `PostToolUse` | `processing` |
| Idle > 4 s | `Stop` | `waiting_for_input` |
| `isArchived: true` | `SessionEnd` | `waiting_for_input` |
| Idle > 10 min | `SessionEnd` | `waiting_for_input` |

## Configuration

At the top of `cowork-notchi-watcher.py`:

| Constant | Default | Description |
|---|---|---|
| `POLL_INTERVAL` | `0.4 s` | How often each session's audit.jsonl is read |
| `SCAN_INTERVAL` | `2.0 s` | How often the sessions directory is scanned for new sessions |
| `IDLE_TIMEOUT` | `4.0 s` | Silence before transitioning to `waiting_for_input` |
| `SESSION_END_TIMEOUT` | `600 s` | Inactivity before a session is considered ended |

Sessions with no activity in the last 30 minutes are ignored on startup to avoid stale sessions appearing in the notch.

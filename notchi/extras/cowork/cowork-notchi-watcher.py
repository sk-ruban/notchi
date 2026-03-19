#!/usr/bin/env python3
"""cowork-notchi-watcher.py

Watches Claude Desktop Cowork sessions and forwards events to notchi's Unix socket,
giving the same notch indicator effect as Claude Code (cc).

How it works:
  - Cowork stores sessions at:
      ~/Library/Application Support/Claude/local-agent-mode-sessions/
  - Each session has:
      local_{uuid}.json        → metadata (sessionId, cwd, isArchived, etc.)
      local_{uuid}/audit.jsonl → event log (same format as Claude Code JSONL)
  - This script watches for new sessions and tails their audit.jsonl,
    translating events to notchi's socket protocol.

Run automatically via LaunchAgent:
  ~/Library/LaunchAgents/com.notchi.cowork-watcher.plist
"""

import json
import os
import socket
import sys
import time
import threading
from pathlib import Path

SOCKET_PATH = "/tmp/notchi.sock"
SESSIONS_BASE = (
    Path.home() / "Library" / "Application Support" / "Claude" / "local-agent-mode-sessions"
)

POLL_INTERVAL = 0.4       # seconds between audit.jsonl reads
SCAN_INTERVAL = 2.0       # seconds between scans for new sessions
IDLE_TIMEOUT = 4.0        # seconds of silence → "waiting for input"
SESSION_END_TIMEOUT = 600  # 10 min with no activity → end session


# ─── notchi socket helper ──────────────────────────────────────────────────────

def send_notchi(session_id: str, cwd: str, event: str, status: str, **extra):
    if not Path(SOCKET_PATH).exists():
        return
    payload = {"session_id": session_id, "cwd": cwd, "event": event, "status": status}
    payload.update(extra)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(SOCKET_PATH)
        s.sendall(json.dumps(payload).encode())
        s.close()
    except Exception:
        pass


# ─── per-session watcher thread ───────────────────────────────────────────────

class AuditWatcher(threading.Thread):
    def __init__(self, session_id: str, cwd: str, audit_path: Path, meta_path: Path):
        super().__init__(daemon=True, name=f"cowork-{session_id[:8]}")
        self.session_id = session_id
        self.cwd = cwd
        self.audit_path = audit_path
        self.meta_path = meta_path
        self._stop_event = threading.Event()

    def stop(self):
        self._stop_event.set()

    def _is_archived(self) -> bool:
        try:
            with open(self.meta_path, encoding="utf-8") as f:
                return json.load(f).get("isArchived", False)
        except Exception:
            return False

    def run(self):
        # Determine initial status from metadata lastActivityAt
        try:
            with open(self.meta_path, encoding="utf-8") as f:
                meta = json.load(f)
            age_s = (time.time() * 1000 - meta.get("lastActivityAt", 0)) / 1000
            initial_status = "processing" if age_s < 60 else "waiting_for_input"
        except Exception:
            initial_status = "processing"

        send_notchi(self.session_id, self.cwd, "SessionStart", initial_status)

        # Start reading from current end of file (skip old history)
        try:
            last_pos = self.audit_path.stat().st_size if self.audit_path.exists() else 0
        except Exception:
            last_pos = 0

        # Init last_activity from metadata so old idle sessions time out immediately
        try:
            with open(self.meta_path, encoding="utf-8") as f:
                _meta = json.load(f)
            last_activity_ms = _meta.get("lastActivityAt", 0)
            last_activity = last_activity_ms / 1000 if last_activity_ms else time.time()
        except Exception:
            last_activity = time.time()
        is_processing = initial_status == "processing"

        while not self._stop_event.is_set():
            # Check archive status every cycle
            if self._is_archived():
                if is_processing:
                    send_notchi(self.session_id, self.cwd, "Stop", "waiting_for_input")
                send_notchi(self.session_id, self.cwd, "SessionEnd", "waiting_for_input")
                return

            # Read new lines from audit.jsonl
            try:
                if self.audit_path.exists():
                    with open(self.audit_path, "r", encoding="utf-8") as f:
                        f.seek(last_pos)
                        new_lines = f.readlines()
                        last_pos = f.tell()
                else:
                    new_lines = []
            except Exception:
                new_lines = []

            if new_lines:
                last_activity = time.time()
                for raw in new_lines:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        self._process_line(json.loads(raw))
                        is_processing = True
                    except Exception:
                        pass
            else:
                # No new data — check for idle/end transitions
                idle = time.time() - last_activity
                if is_processing and idle > IDLE_TIMEOUT:
                    send_notchi(self.session_id, self.cwd, "Stop", "waiting_for_input")
                    is_processing = False
                if idle > SESSION_END_TIMEOUT:
                    send_notchi(self.session_id, self.cwd, "SessionEnd", "waiting_for_input")
                    return

            time.sleep(POLL_INTERVAL)

    def _process_line(self, obj: dict):
        event_type = obj.get("type", "")

        if event_type == "user":
            msg = obj.get("message", {})
            if not isinstance(msg, dict):
                return
            role = msg.get("role", "")
            content = msg.get("content", "")

            if role == "user" and isinstance(content, str) and content:
                # Initial user message
                send_notchi(
                    self.session_id, self.cwd,
                    "UserPromptSubmit", "processing",
                    user_prompt=content,
                )
            elif isinstance(content, list):
                # Tool result
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "tool_result":
                        send_notchi(
                            self.session_id, self.cwd,
                            "PostToolUse", "processing",
                            tool_use_id=item.get("tool_use_id", ""),
                        )
                        break

        elif event_type == "assistant":
            msg = obj.get("message", {})
            if not isinstance(msg, dict):
                return
            content = msg.get("content", [])
            if isinstance(content, list):
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "tool_use":
                        send_notchi(
                            self.session_id, self.cwd,
                            "PreToolUse", "running_tool",
                            tool=item.get("name", "unknown"),
                            tool_use_id=item.get("id", ""),
                        )
                        break


# ─── main coordinator ─────────────────────────────────────────────────────────

class CoworkWatcher:
    def __init__(self):
        self._watchers: dict[str, AuditWatcher] = {}  # session_id → watcher
        self._seen_files: set[str] = set()

    def _scan(self):
        if not SESSIONS_BASE.exists():
            return

        for machine_dir in SESSIONS_BASE.iterdir():
            if not machine_dir.is_dir():
                continue
            for group_dir in machine_dir.iterdir():
                if not group_dir.is_dir():
                    continue
                for meta_file in group_dir.glob("local_*.json"):
                    if meta_file.name in self._seen_files:
                        continue
                    self._seen_files.add(meta_file.name)
                    self._maybe_start(meta_file, group_dir)

    def _maybe_start(self, meta_file: Path, group_dir: Path):
        try:
            with open(meta_file, encoding="utf-8") as f:
                meta = json.load(f)
        except Exception:
            return

        if meta.get("isArchived", False):
            return

        session_id = meta.get("sessionId", "")
        cwd = meta.get("cwd", "/")
        if not session_id or session_id in self._watchers:
            return

        # Skip sessions with no activity in the last 30 minutes
        last_activity_ms = meta.get("lastActivityAt", 0)
        if last_activity_ms and (time.time() * 1000 - last_activity_ms) / 1000 > 1800:
            return

        audit_path = group_dir / meta_file.stem / "audit.jsonl"

        w = AuditWatcher(session_id, cwd, audit_path, meta_file)
        w.start()
        self._watchers[session_id] = w

    def _cleanup(self):
        dead = [sid for sid, w in self._watchers.items() if not w.is_alive()]
        for sid in dead:
            del self._watchers[sid]

    def run(self):
        print(f"cowork-notchi-watcher started, watching {SESSIONS_BASE}", flush=True)
        while True:
            self._scan()
            self._cleanup()
            time.sleep(SCAN_INTERVAL)


if __name__ == "__main__":
    CoworkWatcher().run()

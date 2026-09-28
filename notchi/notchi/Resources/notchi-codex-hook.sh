#!/bin/bash
# Notchi Codex Hook - forwards Codex hook events to Notchi via Unix socket

SOCKET_PATH="$HOME/Library/Application Support/Notchi/notchi.sock"

[ -S "$SOCKET_PATH" ] && [ -O "$SOCKET_PATH" ] || exit 0
export NOTCHI_SOCKET_PATH="$SOCKET_PATH"

/usr/bin/python3 -I -c "
import json
import os
import socket
import subprocess
import sys
import time

try:
    input_data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

hook_event = input_data.get('hook_event_name', '')
status_map = {
    'SessionStart': 'waiting_for_input',
    'UserPromptSubmit': 'processing',
    'Stop': 'waiting_for_input',
}

output = {
    'provider': 'codex',
    'session_id': input_data.get('session_id', ''),
    'transcript_path': input_data.get('transcript_path'),
    'cwd': input_data.get('cwd', ''),
    'event': hook_event,
    'status': status_map.get(hook_event, input_data.get('status', 'unknown')),
    'permission_mode': input_data.get('permission_mode'),
    'interactive': True,
}

def process_table():
    try:
        ps_output = subprocess.check_output(
            ['/bin/ps', '-axo', 'pid=,ppid=,tty=,comm='],
            text=True,
            timeout=0.5,
        )
    except Exception:
        return {}

    table = {}
    for line in ps_output.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4 or not parts[0].isdigit() or not parts[1].isdigit():
            continue

        table[int(parts[0])] = {
            'ppid': int(parts[1]),
            'tty': parts[2],
            'command': os.path.basename(parts[3]).lower(),
        }

    return table

def codex_process_context():
    processes = process_table()
    pid = os.getppid()
    fallback = None
    visited = set()

    for _ in range(8):
        if pid in visited:
            break

        visited.add(pid)
        info = processes.get(pid)
        if info is None:
            break

        origin = 'cli' if info['tty'] != '??' else 'desktop'

        if 'codex' in info['command']:
            return (pid, origin)

        if fallback is None:
            # Known limitation: if Codex is hidden behind a differently named long-lived wrapper,
            # this fallback may track the wrapper/shell and leave the session visible longer.
            fallback = (pid, origin)

        if info['ppid'] <= 1 or info['ppid'] == pid:
            break

        pid = info['ppid']

    return fallback

def has_non_empty_list(value):
    return isinstance(value, list) and len(value) > 0

def input_has_attachments(data):
    for key in ('images', 'local_images', 'attachments', 'files'):
        if has_non_empty_list(data.get(key)):
            return True

    return False

def normalized_text(value):
    return value.strip() if isinstance(value, str) else ''

def transcript_user_message_attachment_state(path, normalized_prompt):
    if not path:
        return None

    try:
        with open(path, 'r', encoding='utf-8') as transcript:
            lines = transcript.readlines()
    except Exception:
        return None

    for line in reversed(lines[-200:]):
        try:
            event = json.loads(line)
        except Exception:
            continue

        payload = event.get('payload')
        if not isinstance(payload, dict) or payload.get('type') != 'user_message':
            continue

        if normalized_text(payload.get('message')) != normalized_prompt:
            return None

        return (
            has_non_empty_list(payload.get('images')) or
            has_non_empty_list(payload.get('local_images'))
        )

    return None

def latest_transcript_user_message_has_attachments(path, prompt):
    normalized_prompt = normalized_text(prompt)
    if not normalized_prompt:
        return False

    for attempt in range(5):
        state = transcript_user_message_attachment_state(path, normalized_prompt)
        if state is not None:
            return state

        if attempt < 4:
            time.sleep(0.05)

    return False

context = codex_process_context()
if context:
    output['codex_process_id'] = context[0]
    output['codex_origin'] = context[1]

prompt = input_data.get('prompt')
if prompt:
    output['user_prompt'] = prompt

if hook_event == 'UserPromptSubmit':
    output['has_attachments'] = (
        input_has_attachments(input_data) or
        latest_transcript_user_message_has_attachments(input_data.get('transcript_path'), prompt)
    )

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(os.environ['NOTCHI_SOCKET_PATH'])
    sock.sendall(json.dumps(output).encode())
    sock.close()
except Exception:
    pass
"

exit 0

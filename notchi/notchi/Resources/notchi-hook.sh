#!/bin/bash
# Notchi Hook - forwards Claude Code events to Notchi app via Unix socket

SOCKET_PATH="/tmp/notchi.sock"

# Exit silently if socket doesn't exist (app not running)
[ -S "$SOCKET_PATH" ] || exit 0

# Detect non-interactive (claude -p / --print) sessions
IS_INTERACTIVE=true
for CHECK_PID in $PPID $(ps -o ppid= -p $PPID 2>/dev/null | tr -d ' '); do
    if ps -o args= -p "$CHECK_PID" 2>/dev/null | grep -qE '(^| )(-p|--print)( |$)'; then
        IS_INTERACTIVE=false
        break
    fi
done
export NOTCHI_INTERACTIVE=$IS_INTERACTIVE

# Parse input and send to socket using Python
/usr/bin/python3 -c "
import json
import os
import socket
import subprocess
import sys

try:
    input_data = json.load(sys.stdin)
except:
    sys.exit(0)

hook_event = input_data.get('hook_event_name', '')

status_map = {
    'UserPromptSubmit': 'processing',
    'PreCompact': 'compacting',
    'SessionStart': 'waiting_for_input',
    'SessionEnd': 'ended',
    'PreToolUse': 'running_tool',
    'PostToolUse': 'processing',
    # Claude Code normally asks custom questions through PreToolUse; keep
    # PermissionRequest for compatibility with observed/beta event shapes.
    'PermissionRequest': 'waiting_for_input',
    'Stop': 'waiting_for_input',
    'SubagentStop': 'waiting_for_input'
}

output = {
    'provider': 'claude',
    'session_id': input_data.get('session_id', ''),
    'transcript_path': input_data.get('transcript_path', ''),
    'cwd': input_data.get('cwd', ''),
    'event': hook_event,
    'status': input_data.get('status', status_map.get(hook_event, 'unknown')),
    'pid': None,
    'tty': None,
    'interactive': os.environ.get('NOTCHI_INTERACTIVE', 'true') == 'true',
    'permission_mode': input_data.get('permission_mode', 'default')
}

def process_table():
    try:
        ps_output = subprocess.check_output(
            ['/bin/ps', '-axo', 'pid=,ppid=,command='],
            text=True,
            timeout=0.5,
        )
    except Exception:
        return {}

    table = {}
    for line in ps_output.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit() or not parts[1].isdigit():
            continue

        tokens = parts[2].split()
        argv0 = os.path.basename(tokens[0]).lower() if tokens else ''
        table[int(parts[0])] = {
            'ppid': int(parts[1]),
            'argv0': argv0,
        }

    return table

def claude_process_id():
    processes = process_table()
    pid = os.getppid()
    visited = set()

    for _ in range(8):
        if pid in visited:
            break

        visited.add(pid)
        info = processes.get(pid)
        if info is None:
            break

        argv0 = info['argv0']
        if argv0 in ('claude', 'claude-code'):
            return pid

        if info['ppid'] <= 1 or info['ppid'] == pid:
            break

        pid = info['ppid']

    return None

if hook_event in ('SessionStart', 'UserPromptSubmit'):
    process_id = claude_process_id()
    if process_id:
        output['claude_process_id'] = process_id

# Pass user prompt directly for UserPromptSubmit
if hook_event == 'UserPromptSubmit':
    prompt = input_data.get('prompt', '')
    if prompt:
        output['user_prompt'] = prompt

tool = input_data.get('tool_name', '')
if tool:
    output['tool'] = tool

tool_id = input_data.get('tool_use_id', '')
if tool_id:
    output['tool_use_id'] = tool_id

tool_input = input_data.get('tool_input', {})
if tool_input:
    output['tool_input'] = tool_input

permission_suggestions = input_data.get('permission_suggestions', [])
if permission_suggestions:
    output['permission_suggestions'] = permission_suggestions

def should_wait_for_response():
    if os.environ.get('NOTCHI_INTERACTIVE', 'true') != 'true':
        return False

    return hook_event == 'PermissionRequest'

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())
    if should_wait_for_response():
        sock.shutdown(socket.SHUT_WR)
        sock.settimeout(290)
        response_chunks = []
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response_chunks.append(chunk)
        if response_chunks:
            sys.stdout.write(b''.join(response_chunks).decode())
            sys.stdout.flush()
    sock.close()
except:
    pass
"

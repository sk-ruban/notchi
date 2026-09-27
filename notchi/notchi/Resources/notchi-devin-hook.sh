#!/bin/bash

SOCKET_PATH="/tmp/notchi.sock"

[ -S "$SOCKET_PATH" ] || exit 0

IS_INTERACTIVE=true
for CHECK_PID in $PPID $(ps -o ppid= -p $PPID 2>/dev/null | tr -d ' '); do
    if ps -o args= -p "$CHECK_PID" 2>/dev/null | grep -qE '(^| )(-p|--print)( |$)'; then
        IS_INTERACTIVE=false
        break
    fi
done
export NOTCHI_INTERACTIVE=$IS_INTERACTIVE

/usr/bin/python3 -I -c "
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
    'SessionStart': 'waiting_for_input',
    'SessionEnd': 'ended',
    'PreToolUse': 'running_tool',
    'PostToolUse': 'processing',
    'Stop': 'waiting_for_input'
}

cwd = os.environ.get('DEVIN_PROJECT_DIR') or input_data.get('cwd') or os.getcwd()

output = {
    'provider': 'devin',
    'session_id': input_data.get('session_id', ''),
    'cwd': cwd,
    'event': hook_event,
    'status': status_map.get(hook_event, 'unknown'),
    'interactive': os.environ.get('NOTCHI_INTERACTIVE', 'true') == 'true'
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

def devin_process_id():
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

        if info['argv0'] == 'devin':
            return pid

        if info['ppid'] <= 1 or info['ppid'] == pid:
            break

        pid = info['ppid']

    return None

if hook_event in ('SessionStart', 'UserPromptSubmit'):
    process_id = devin_process_id()
    if process_id:
        output['devin_process_id'] = process_id

if hook_event == 'UserPromptSubmit':
    prompt = input_data.get('prompt', '')
    if prompt:
        output['user_prompt'] = prompt

if hook_event == 'Stop':
    reply = input_data.get('last_assistant_message', '')
    if isinstance(reply, str) and reply:
        output['last_assistant_message'] = reply

tool = input_data.get('tool_name', '')
if tool:
    output['tool'] = tool

tool_id = input_data.get('tool_use_id', '')
if tool_id:
    output['tool_use_id'] = tool_id

tool_input = input_data.get('tool_input', {})
if tool_input:
    output['tool_input'] = tool_input

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())
    sock.close()
except:
    pass
"

exit 0

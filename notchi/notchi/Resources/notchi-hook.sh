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
    'PermissionRequest': 'waiting_for_input',
    'Stop': 'waiting_for_input',
    'SubagentStop': 'waiting_for_input'
}

output = {
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

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())
    sock.close()
except:
    pass
"

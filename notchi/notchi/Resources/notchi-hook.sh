#!/bin/bash
# Notchi Hook - forwards Claude Code events to Notchi app via Unix socket

SOCKET_PATH="/tmp/notchi.sock"

# Exit silently if socket doesn't exist (app not running)
[ -S "$SOCKET_PATH" ] || exit 0

# Parse input JSON and build output payload in a single Python call
/usr/bin/python3 -c "
import json
import sys

try:
    input_data = json.load(sys.stdin)
except:
    sys.exit(0)

hook_event = input_data.get('hook_event_name', '')

status_map = {
    'SessionStart': 'waiting_for_input',
    'SessionEnd': 'ended',
    'PreToolUse': 'running_tool',
    'PostToolUse': 'processing'
}

output = {
    'session_id': input_data.get('session_id', ''),
    'cwd': input_data.get('cwd', ''),
    'event': hook_event,
    'status': status_map.get(hook_event, 'unknown'),
    'pid': None,
    'tty': None
}

tool = input_data.get('tool_name', '')
if tool:
    output['tool'] = tool

tool_id = input_data.get('tool_use_id', '')
if tool_id:
    output['tool_use_id'] = tool_id

print(json.dumps(output))
" | nc -U "$SOCKET_PATH" 2>/dev/null &
exit 0

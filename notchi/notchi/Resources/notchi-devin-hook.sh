#!/bin/bash

SOCKET_PATH="$HOME/Library/Application Support/Notchi/notchi.sock"

[ -S "$SOCKET_PATH" ] && [ -O "$SOCKET_PATH" ] || exit 0
export NOTCHI_SOCKET_PATH="$SOCKET_PATH"

/usr/bin/python3 -I -c "
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
}

# Only these events read the process table; every other event skips ps and the subprocess import.
PROCESS_CONTEXT_EVENTS = ('SessionStart', 'UserPromptSubmit')
PRINT_MODE_FLAGS = ('-p', '--print')
# Print-mode detection depends on this read, so allow a loaded machine time to answer; a timeout
# would count a headless agent as interactive.
PROCESS_TABLE_TIMEOUT_SECONDS = 3
# Bulky tool input (file contents, diffs) is cut; notchi only shows short fields, and reads command in full.
MAX_TOOL_INPUT_TEXT = 2000
UNTRIMMED_TOOL_INPUT_KEYS = ('command',)
WHOLE_TOOL_INPUT_TOOLS = ('AskUserQuestion',)

def process_table():
    import subprocess
    try:
        ps_output = subprocess.check_output(
            ['/bin/ps', '-axo', 'pid=,ppid=,command='],
            text=True,
            timeout=PROCESS_TABLE_TIMEOUT_SECONDS,
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
            'tokens': tokens,
        }

    return table

def is_interactive(processes):
    # The hook shell's parent and grandparent: the agent, or a shell it wrapped the hook in.
    hook_shell = processes.get(os.getppid())
    pid = hook_shell['ppid'] if hook_shell else None
    for _ in range(2):
        info = processes.get(pid)
        if info is None:
            break
        if any(token in PRINT_MODE_FLAGS for token in info['tokens']):
            return False
        pid = info['ppid']
    return True

def devin_process_id(processes):
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

if hook_event in PROCESS_CONTEXT_EVENTS:
    processes = process_table()
    output['interactive'] = is_interactive(processes)
    process_id = devin_process_id(processes)
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

def trimmed_tool_input(value):
    if isinstance(value, str):
        return value[:MAX_TOOL_INPUT_TEXT]
    if isinstance(value, list):
        return [trimmed_tool_input(item) for item in value]
    if isinstance(value, dict):
        return {
            key: item if key in UNTRIMMED_TOOL_INPUT_KEYS else trimmed_tool_input(item)
            for key, item in value.items()
        }
    return value

tool_input = input_data.get('tool_input', {})
if tool_input:
    # Question cards are parsed from the input, so those stay whole.
    if tool not in WHOLE_TOOL_INPUT_TOOLS:
        tool_input = trimmed_tool_input(tool_input)
    output['tool_input'] = tool_input

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(os.environ['NOTCHI_SOCKET_PATH'])
    sock.sendall(json.dumps(output).encode())
    sock.close()
except:
    pass
"

exit 0

#!/bin/bash
# Notchi Hook - forwards Claude Code events to Notchi app via Unix socket

SOCKET_PATH="$HOME/Library/Application Support/Notchi/notchi.sock"

# Exit silently if socket doesn't exist (app not running)
[ -S "$SOCKET_PATH" ] && [ -O "$SOCKET_PATH" ] || exit 0
export NOTCHI_SOCKET_PATH="$SOCKET_PATH"

# Parse input and send to socket using Python
/usr/bin/python3 -I -c "
import json
import os
import socket
import sys

try:
    input_data = json.load(sys.stdin)
except:
    sys.exit(0)

if os.environ.get('DEVIN_PROJECT_DIR') and not input_data.get('transcript_path'):
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
    'permission_mode': input_data.get('permission_mode', 'default')
}

# Which Claude account (config dir) fired this. Sent verbatim: Claude Code names each account's
# keychain item after this exact string. Unset or empty means the default account.
claude_config_dir = os.environ.get('CLAUDE_CONFIG_DIR')
if claude_config_dir:
    output['claude_config_dir'] = claude_config_dir

# Only these events read the process table; every other event skips ps and the subprocess import.
PROCESS_CONTEXT_EVENTS = ('SessionStart', 'UserPromptSubmit', 'PermissionRequest')
PROCESS_ID_EVENTS = ('SessionStart', 'UserPromptSubmit')
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

def claude_process_id(processes):
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

process_table_read = False
if hook_event in PROCESS_CONTEXT_EVENTS:
    processes = process_table()
    process_table_read = bool(processes)
    output['interactive'] = is_interactive(processes)
    if hook_event in PROCESS_ID_EVENTS:
        process_id = claude_process_id(processes)
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
    # Permission and question answers echo the input back to Claude, so those stay whole.
    if hook_event in ('PreToolUse', 'PostToolUse') and tool not in WHOLE_TOOL_INPUT_TOOLS:
        tool_input = trimmed_tool_input(tool_input)
    output['tool_input'] = tool_input

permission_suggestions = input_data.get('permission_suggestions', [])
if permission_suggestions:
    output['permission_suggestions'] = permission_suggestions

def should_wait_for_response():
    # Without the process table a headless agent can't be ruled out, and waiting would stall it
    # for minutes; not waiting just leaves the prompt to Claude.
    return hook_event == 'PermissionRequest' and process_table_read and output.get('interactive', True)

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(os.environ['NOTCHI_SOCKET_PATH'])
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

exit 0

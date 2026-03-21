#!/bin/bash
# Notchi Remote Setup
# Run on a remote machine to connect Claude Code sessions to Notchi on your Mac.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sk-ruban/notchi/main/scripts/remote-setup.sh | NOTCHI_HOST=<mac-ip> NOTCHI_PORT=9876 bash

set -e

NOTCHI_HOST="${NOTCHI_HOST:-}"
NOTCHI_PORT="${NOTCHI_PORT:-9876}"

if [ -z "$NOTCHI_HOST" ]; then
    echo "Error: NOTCHI_HOST is required."
    echo "Usage: curl -fsSL <url> | NOTCHI_HOST=<mac-ip> bash"
    exit 1
fi

echo "Setting up Notchi remote hook..."
echo "  Host: $NOTCHI_HOST"
echo "  Port: $NOTCHI_PORT"

# Create hooks directory
mkdir -p ~/.claude/hooks

# Download hook script
HOOK_URL="https://raw.githubusercontent.com/sk-ruban/notchi/main/scripts/notchi-hook-remote.sh"
curl -fsSL "$HOOK_URL" -o ~/.claude/hooks/notchi-hook.sh
chmod +x ~/.claude/hooks/notchi-hook.sh
echo "  Installed hook script"

# Add environment variables to shell profile
add_env_to_profile() {
    local profile="$1"
    [ -f "$profile" ] || return 0
    if grep -q "NOTCHI_HOST" "$profile" 2>/dev/null; then
        # Update existing values
        sed -i.bak "s|export NOTCHI_HOST=.*|export NOTCHI_HOST=$NOTCHI_HOST|" "$profile"
        sed -i.bak "s|export NOTCHI_PORT=.*|export NOTCHI_PORT=$NOTCHI_PORT|" "$profile"
        rm -f "${profile}.bak"
        echo "  Updated $profile"
    else
        printf '\n# Notchi remote hook\nexport NOTCHI_HOST=%s\nexport NOTCHI_PORT=%s\n' "$NOTCHI_HOST" "$NOTCHI_PORT" >> "$profile"
        echo "  Added env vars to $profile"
    fi
}

# Try common shell profiles
for profile in ~/.bashrc ~/.zshrc; do
    add_env_to_profile "$profile"
done

# If no profile exists, create .bashrc
if [ ! -f ~/.bashrc ] && [ ! -f ~/.zshrc ]; then
    printf '# Notchi remote hook\nexport NOTCHI_HOST=%s\nexport NOTCHI_PORT=%s\n' "$NOTCHI_HOST" "$NOTCHI_PORT" > ~/.bashrc
    echo "  Created ~/.bashrc with env vars"
fi

# Configure Claude Code hooks
python3 -c "
import json, os

settings_path = os.path.expanduser('~/.claude/settings.json')
try:
    with open(settings_path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

command = '~/.claude/hooks/notchi-hook.sh'
hook_entry = [{'type': 'command', 'command': command}]
with_matcher = [{'matcher': '*', 'hooks': hook_entry}]
without_matcher = [{'hooks': hook_entry}]
pre_compact = [
    {'matcher': 'auto', 'hooks': hook_entry},
    {'matcher': 'manual', 'hooks': hook_entry}
]

hooks = settings.get('hooks', {})

events = {
    'UserPromptSubmit': without_matcher,
    'SessionStart': without_matcher,
    'PreToolUse': with_matcher,
    'PostToolUse': with_matcher,
    'PermissionRequest': with_matcher,
    'PreCompact': pre_compact,
    'Stop': without_matcher,
    'SubagentStop': without_matcher,
    'SessionEnd': without_matcher,
}

for event, config in events.items():
    existing = hooks.get(event, [])
    has_notchi = any(
        any('notchi-hook.sh' in h.get('command', '') for h in entry.get('hooks', []))
        for entry in existing
    )
    if not has_notchi:
        existing.extend(config)
        hooks[event] = existing

settings['hooks'] = hooks

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2, sort_keys=True)
" && echo "  Configured Claude Code hooks"

echo ""
echo "Done! Restart your shell or run: source ~/.bashrc"
echo "Then start Claude Code — your Notchi mascot on $NOTCHI_HOST will react."

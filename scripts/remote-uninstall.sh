#!/bin/bash
# Notchi Remote Uninstall
# Run on a remote machine to remove the Notchi hook.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sk-ruban/notchi/main/scripts/remote-uninstall.sh | bash

set -e

echo "Removing Notchi remote hook..."

# Remove hook script
rm -f ~/.claude/hooks/notchi-hook.sh
echo "  Removed hook script"

# Remove env vars from shell profiles
for profile in ~/.bashrc ~/.zshrc; do
    if [ -f "$profile" ] && grep -q "NOTCHI_HOST" "$profile" 2>/dev/null; then
        sed -i.bak '/NOTCHI_HOST/d;/NOTCHI_PORT/d;/Notchi remote/d' "$profile"
        rm -f "${profile}.bak"
        echo "  Cleaned $profile"
    fi
done

# Remove hooks from Claude Code settings
python3 -c "
import json, os

p = os.path.expanduser('~/.claude/settings.json')
try:
    with open(p) as f:
        s = json.load(f)
    h = s.get('hooks', {})
    for e in list(h):
        h[e] = [x for x in h[e] if not any('notchi-hook.sh' in hk.get('command', '') for hk in x.get('hooks', []))]
        if not h[e]:
            del h[e]
    if not h:
        del s['hooks']
    with open(p, 'w') as f:
        json.dump(s, f, indent=2, sort_keys=True)
    print('  Cleaned Claude Code settings')
except Exception:
    pass
"

echo ""
echo "Done! Notchi hook removed."

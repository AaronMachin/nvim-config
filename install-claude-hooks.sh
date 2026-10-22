#!/bin/bash
# Adds the floating terminal's Claude Code hooks (bin/floatterm-claude-hook, see
# lua/floatterm/claude.lua) to Claude's user settings, or removes them.
#
#   ./install-claude-hooks.sh [--uninstall] [settings file]
#
# The settings file is ~/.claude/settings.json unless given here or in
# $CLAUDE_SETTINGS_FILE. Everything else in it is left alone, running it again
# adds nothing, and --uninstall takes out only the hooks this added.

set -euo pipefail

uninstall=false
settings=""
for arg in "$@"; do
  case "$arg" in
    --uninstall) uninstall=true ;;
    -h | --help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) settings="$arg" ;;
  esac
done
settings="${settings:-${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}}"

repo=$(cd "$(dirname "$0")" && pwd -P)
# Quoted, as Claude runs the command through a shell.
command="\"$repo/bin/floatterm-claude-hook\""
events="SessionStart UserPromptSubmit Notification PostToolUse Stop SessionEnd"

# A symlinked settings file (kept in a dotfiles repo, say) is written through to the
# file it points at, so the link stays.
target=$settings
while [ -L "$target" ]; do
  link=$(readlink "$target")
  case "$link" in
    /*) target=$link ;;
    *) target="$(dirname "$target")/$link" ;;
  esac
done

# A missing, empty or whitespace-only file reads as {}. Anything else must be JSON,
# or the update below fails and nothing is written.
input=$target
if [ ! -f "$target" ] || ! grep -q '[^[:space:]]' "$target"; then
  if $uninstall; then
    echo "No settings in $settings, so nothing to remove."
    exit 0
  fi
  mkdir -p "$(dirname "$target")"
  input=/dev/null
fi

# Prints the updated settings, then the events changed, one per line, after a line
# holding only ---.
if command -v jq >/dev/null 2>&1; then
  update() {
    jq --arg command "$command" --arg events "$events" --argjson uninstall "$uninstall" '
      def ours: any(.hooks[]?; .command == $command);
      ($events | split(" ")) as $names
      | if $uninstall then
          [ $names[] as $e | select((.hooks[$e] // []) | any(ours)) | $e ] as $changed
          | reduce $changed[] as $e (.;
              .hooks[$e] |= ( map(.hooks |= map(select(.command != $command)))
                              | map(select((.hooks | length) > 0)) )
              | if (.hooks[$e] | length) == 0 then del(.hooks[$e]) else . end)
          | if ((.hooks // {}) | length) == 0 and ($changed | length) > 0 then del(.hooks) else . end
          | [., $changed]
        else
          [ $names[] as $e | select(((.hooks[$e] // []) | any(ours)) | not) | $e ] as $changed
          | reduce $changed[] as $e (.;
              .hooks[$e] = ((.hooks[$e] // []) + [{ hooks: [{ type: "command", command: $command, timeout: 5 }] }]))
          | [., $changed]
        end
      | (.[0] | tojson), "---", .[1][]
    ' -r < <(if [ "$input" = /dev/null ]; then echo '{}'; else cat "$input"; fi)
  }
else
  update() {
    python3 -I - "$input" "$command" "$events" "$uninstall" <<'PYTHON'
import json, sys
path, command, events, uninstall = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4] == "true"
with open(path) as f:
    data = json.loads(f.read() or "{}")
hooks = data.get("hooks") or {}
ours = lambda group: any(h.get("command") == command for h in group.get("hooks", []))
changed = []
for event in events:
    groups = hooks.get(event, [])
    if uninstall and any(ours(g) for g in groups):
        for g in groups:
            g["hooks"] = [h for h in g.get("hooks", []) if h.get("command") != command]
        groups = [g for g in groups if g["hooks"]]
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]
        changed.append(event)
    elif not uninstall and not any(ours(g) for g in groups):
        hooks[event] = groups + [{"hooks": [{"type": "command", "command": command, "timeout": 5}]}]
        changed.append(event)
if hooks:
    data["hooks"] = hooks
elif changed:
    data.pop("hooks", None)
print(json.dumps(data, ensure_ascii=False))
print("---")
print("\n".join(changed))
PYTHON
  }
fi

output=$(update)
changed=$(printf '%s\n' "$output" | sed '1,/^---$/d')
if [ -z "$changed" ]; then
  if $uninstall; then
    echo "The floatterm hooks aren't in $settings, so nothing changed."
  else
    echo "The floatterm hooks are already in $settings, so nothing changed."
  fi
  exit 0
fi

# Formatted into a temporary file beside the settings, then moved over them in one
# step, so Claude never reads a half-written file. It takes the old file's permissions.
tmp=$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX")
trap 'rm -f "$tmp"' EXIT
if command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$output" | sed -n 1p | jq . >"$tmp"
else
  printf '%s\n' "$output" | sed -n 1p | python3 -I -m json.tool --indent 2 >"$tmp"
fi
if [ -f "$target" ]; then
  # GNU stat takes -c; macOS's takes -f.
  mode=$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")
  chmod "$mode" "$tmp"
else
  chmod 644 "$tmp"
fi
mv -f "$tmp" "$target"

if $uninstall; then
  echo "Removed the floatterm hook from $settings for:"
else
  echo "Added $command to $settings for:"
fi
# shellcheck disable=SC2086 # one event per word
printf '  %s\n' $changed

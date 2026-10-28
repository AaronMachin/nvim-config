#!/bin/sh
# Runs the test suite (or one spec file) in a throwaway environment. See tests/README.md.
#
#   tests/run.sh                        every tests/*_spec.lua, in parallel
#   tests/run.sh tests/notes_spec.lua   one file
set -u

here=$(cd "$(dirname "$0")" && pwd)
config=$(dirname "$here")
lazy=${NVIM_TEST_LAZY:-$HOME/.local/share/nvim/lazy}
nvim=${NVIM_TEST_NVIM:-nvim}
file=${1:-}
if [ -n "$file" ]; then
  file=$(cd "$(dirname "$file")" && pwd)/$(basename "$file")
fi

if [ ! -d "$lazy/plenary.nvim" ]; then
  echo "plenary.nvim not found in $lazy (set NVIM_TEST_LAZY)" >&2
  exit 2
fi

root=$(mktemp -d "${TMPDIR:-/tmp}/nvim-config-tests.XXXXXX")
root=$(cd "$root" && pwd -P)
trap 'rm -rf "$root"' EXIT

mkdir -p "$root/data" "$root/state" "$root/cache" "$root/tmp" "$root/bin" "$root/claude-config" "$root/home"

# Anything that must never run for real fails loudly and leaves a note in guard.log.
for name in claude gh docker lazygit sail phpstan; do
  cat >"$root/bin/$name" <<GUARD
#!/bin/sh
echo "$name \$*" >>"$root/guard.log"
exit 97
GUARD
  chmod +x "$root/bin/$name"
done
# Terminal tabs opened with the default shell run this instead of a real shell.
printf '#!/bin/sh\nexec sleep 600\n' >"$root/bin/fakesh"
chmod +x "$root/bin/fakesh"

# git for the throwaway repos the tests build: no global or system config (hooks,
# signing), a known identity and main as the first branch.
cat >"$root/gitconfig" <<GIT
[user]
  name = Test
  email = test@example.com
[init]
  defaultBranch = main
[advice]
  detachedHead = false
[commit]
  gpgsign = false
GIT

export NVIM_TEST_ROOT="$root"
export NVIM_TEST_LAZY="$lazy"
export XDG_DATA_HOME="$root/data"
export XDG_STATE_HOME="$root/state"
export XDG_CACHE_HOME="$root/cache"
export TMPDIR="$root/tmp"
export CLAUDE_CONFIG_DIR="$root/claude-config"
export GIT_CONFIG_GLOBAL="$root/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export PATH="$root/bin:$PATH"
unset NVIM FLOATTERM_TAB_ID

dot_nvim_before=$([ -e "$config/.nvim" ] && echo yes || echo no)

cd "$config" || exit 2
if [ -n "$file" ]; then
  "$nvim" --headless --noplugin -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('$file')"
  status=$?
else
  "$nvim" --headless --noplugin -u tests/minimal_init.lua \
    -c "PlenaryBustedDirectory $config/tests {minimal_init = '$config/tests/minimal_init.lua', timeout = 150000}"
  status=$?
fi

if [ -s "$root/guard.log" ]; then
  echo "FAILED: something tried to run a guarded program:" >&2
  cat "$root/guard.log" >&2
  status=1
fi
if [ "$dot_nvim_before" = no ] && [ -e "$config/.nvim" ]; then
  echo "FAILED: the tests wrote into $config/.nvim" >&2
  status=1
fi
exit $status

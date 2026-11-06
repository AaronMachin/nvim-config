#!/bin/sh
# Starts nvim for a GIF recording: this config, the installed plugins, and nothing else of
# yours. Its own data, state and cache folders (plugins, Mason and the theme linked in
# read-only), a copy of docs/demo/app as the project, a plain zsh prompt, and stand-ins
# for claude and gh. Used by the .tape files; see docs/demo/README.md.
#
#   docs/demo/run-nvim.sh <seed.lua> [file to open]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
data=${NVIM_DEMO_DATA:-$HOME/.local/share/nvim}
root=$(mktemp -d "${TMPDIR:-/tmp}/nvim-demo.XXXXXX")
root=$(cd "$root" && pwd -P)

mkdir -p "$root/data/nvim/nvnotify" "$root/state" "$root/cache" "$root/zsh" "$root/bin"
for dir in lazy mason base46; do
  ln -s "$data/$dir" "$root/data/nvim/$dir"
done
cp -R "$here/app" "$root/demo-app"
(
  cd "$root/demo-app"
  git init -q
  export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.com GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.com
  git add README.md package.json && git commit -qm "Start the demo app"
  git add server.js && git commit -qm "Serve / and /health"
  echo "Run it with npm start." >>README.md && git commit -qam "Say how to run it"
)

cat >"$root/zsh/.zshrc" <<'RC'
PROMPT='%F{blue}%1~%f $ '
RC
for name in claude gh; do
  printf '#!/bin/sh\nexit 0\n' >"$root/bin/$name"
  chmod +x "$root/bin/$name"
done

cd "$root/demo-app"
export XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache"
export ZDOTDIR="$root/zsh" SHELL=/bin/zsh PATH="$root/bin:$PATH" NVIM_DEMO_SEEDS="$here"
unset NVIM JIRA_URL
seed=$1
shift
exec nvim -c "lua package.path = '$here/?.lua;' .. package.path" -c "luafile $here/$seed" "$@"

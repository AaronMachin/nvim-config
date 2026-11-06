# The README's GIFs

Recorded with [vhs](https://github.com/charmbracelet/vhs) from the `.tape` files here: `make gifs` re-records them all into `docs/gifs/`, `vhs docs/demo/tabs.tape` one.

Each tape starts nvim through `run-nvim.sh`, which gives it its own data, state and cache folders (your plugins, Mason and NvChad theme linked in), a copy of `app/` as the project, a plain zsh prompt and stand-ins for `claude` and `gh`. So nothing of yours shows up in a recording and nothing it does lands in your real nvim data.

`seed-*.lua` set up the tabs a tape needs (the Claude tabs are stand-ins with a status and title, not real sessions). vhs can't send Ctrl+Shift or Alt keys nvim reads, so `common.lua` maps Ctrl+G, Ctrl+B and Ctrl+N to opening the float, the tab bar and the next tab for the recordings.

The font is UbuntuMono Nerd Font Mono; change `Set FontFamily` in a tape for another Nerd Font.

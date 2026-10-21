# nvim config

My Neovim config, built on the [NvChad starter](https://github.com/NvChad/starter) (NvChad v2.5). NvChad itself is loaded as a plugin, so this repo only holds what I've changed on top of it.

To use it on a new machine, clone it to `~/.config/nvim` and open nvim. lazy.nvim installs the plugins at the versions in `lazy-lock.json`.

## What's added

- A floating terminal with tabs and rounded corners, leaving 10% of the screen open at the top and a small gap at the sides and bottom (`lua/floatterm`)
  - `<leader>tt` opens it, and `Ctrl+\` (or `Alt+i`) opens or hides it from anywhere, including inside it. Hiding keeps every tab running
  - Inside it, `Ctrl+t` opens a new tab and `Ctrl+|` moves to the next one, wrapping round. `Ctrl+|` needs a terminal app that sends it as its own key rather than as `Ctrl+\`
  - `exit` closes a tab, and closing the last one closes the float
  - `Ctrl+x` turns the terminal into a normal buffer for scrolling, searching and copying (`y` goes to the system clipboard). `i` goes back to typing
  - Docked (the default), `Ctrl+Shift+←/→/↑/↓` docks it to that edge at 90% of the screen. Pressing the same arrow again flips it between 90% and a 20% strip
  - `Ctrl+Shift+m` switches to a floating box a ninth of the screen, and the arrows then move it a square at a time round a 3×3 grid, stopping at the edges. `Ctrl+Shift+m` again docks it back where it was
  - A move that would leave the terminal under 5 rows or 20 columns does nothing. `:FloatTerm left|right|top|bottom|mode` does the same as the keys. Where it sits lasts until nvim restarts
  - A line of key hints sits in the gap above or below it (or in its bottom border when there's no gap). `Ctrl+Shift+h` hides or shows them
- `<leader>fw` is live grep with IntelliJ-style file masks (`lua/grepmask`)
  - `Ctrl+f` in the picker sets the mask, e.g. `*.php, !*Test.php, !vendor/**`. An empty mask clears it
  - `Ctrl+g` picks from recently used masks
  - Each project (git root) remembers its own mask. Masks are kept in `~/.local/share/nvim/grepmask.json`
- git-blame.nvim shows the blame for the current line

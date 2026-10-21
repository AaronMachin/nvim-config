# nvim config

My Neovim config, built on the [NvChad starter](https://github.com/NvChad/starter) (NvChad v2.5). NvChad itself is loaded as a plugin, so this repo only holds what I've changed on top of it.

To use it on a new machine, clone it to `~/.config/nvim` and open nvim. lazy.nvim installs the plugins at the versions in `lazy-lock.json`.

## What's added

- A floating terminal with tabs and rounded corners, leaving 10% of the screen open at the top and a small gap at the sides and bottom (`lua/floatterm`)
  - `<leader>tt` opens it, and `Ctrl+\` (or `Alt+i`) opens or hides it from anywhere, including inside it. Hiding keeps every tab running
  - Inside it, `Ctrl+t` opens a new tab and `Ctrl+|` moves to the next one, wrapping round. `Ctrl+|` needs a terminal app that sends it as its own key rather than as `Ctrl+\`
  - `exit` closes a tab, and closing the last one closes the float
- `<leader>fw` is live grep with IntelliJ-style file masks (`lua/grepmask`)
  - `Ctrl+f` in the picker sets the mask, e.g. `*.php, !*Test.php, !vendor/**`. An empty mask clears it
  - `Ctrl+g` picks from recently used masks
  - Each project (git root) remembers its own mask. Masks are kept in `~/.local/share/nvim/grepmask.json`
- git-blame.nvim shows the blame for the current line

# nvim config

My Neovim config, built on the [NvChad starter](https://github.com/NvChad/starter) (NvChad v2.5). NvChad itself is loaded as a plugin, so this repo only holds what I've changed on top of it.

To use it on a new machine, clone it to `~/.config/nvim` and open nvim. lazy.nvim installs the plugins at the versions in `lazy-lock.json`.

## What's added

- `<leader>tt` opens a floating terminal and `Ctrl+\` opens or closes it from anywhere, including inside it (same as NvChad's `Alt+i`, which needs Option set as Alt in the terminal app)
- `<leader>fw` is live grep with IntelliJ-style file masks (`lua/grepmask`)
  - `Ctrl+f` in the picker sets the mask, e.g. `*.php, !*Test.php, !vendor/**`. An empty mask clears it
  - `Ctrl+g` picks from recently used masks
  - Each project (git root) remembers its own mask. Masks are kept in `~/.local/share/nvim/grepmask.json`
- git-blame.nvim shows the blame for the current line

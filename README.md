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
- `<leader>fw` is live grep with IntelliJ-style file masks and search options (`lua/grepmask`)
  - `Ctrl+f` switches the search box to the mask, e.g. `*.php, !*Test.php, !vendor/**`, and results follow as you type. Recent masks show over the preview, and `↑/↓` tries each one. `Enter` or `Ctrl+f` keeps the mask and goes back to the search text. An empty mask clears it
  - Each project (git root) remembers its own mask. Masks are kept in `~/.local/share/nvim/grepmask.json`
  - What you type is searched for as written. `Ctrl+Shift+r` turns regex on, `Ctrl+Shift+c` match case and `Ctrl+Shift+w` whole word, shown in the title as `[.*]`, `[Cc]` and `[W]`. They last until nvim restarts
  - Lock files, SVGs, minified and generated files and `frontend/design-system/**` are left out by default, and the title shows `[default excludes]` while they are. `Ctrl+Shift+d` brings them back for that search
  - `Ctrl+↑/↓` steps through earlier searches, `Ctrl+Space` filters the current results without searching again, and `Ctrl+q` sends them to the quickfix list (then `:cdo s/old/new/gc | update` replaces across them)
- `<leader>fW` greps the word under the cursor as a whole word, or the selected text in visual mode
- `<leader>fr` reopens the last picker where you left it
- Git, on `<leader>g` (`lua/gitkeys`)
  - `<leader>gg` opens lazygit in a floating-terminal tab, which closes when you quit lazygit
  - `<leader>gs` status, `<leader>gb` branches (Enter switches), `<leader>gc` commits, `<leader>gf` this file's history
  - `]h` / `[h` jump between changed blocks. `<leader>gp` previews the block under the cursor, `<leader>ga` stages it (or the selected lines), `<leader>gr` undoes it (`u` brings it back), and `<leader>gd` diffs the file against the last commit
  - `<leader>gv` opens diffview with everything the branch changes since it left the default branch. Pressing it again closes it
  - `<leader>go` opens the file at the cursor's line (or the selection) on GitHub, on the current branch, which has to be pushed
  - git-blame.nvim shows the blame for the current line
- Language servers for PHP (intelephense), Vue (vue-language-server 2.2.8, with ts_ls for the TypeScript inside .vue files), TypeScript, HTML, CSS and JSON. NvChad's keys apply: `gd` definition, `gr` references, `<leader>ra` rename, `<leader>ca` code actions
  - Install them on a new machine with `:MasonInstall intelephense typescript-language-server vue-language-server@2.2.8 html-lsp css-lsp json-lsp`. Keep Vue on 2.x: 3.x needs a newer lspconfig than `lazy-lock.json` holds, so updating it in the Mason window (or `:MasonInstallAll`) breaks Vue navigation. nvim warns on startup if that happens
- Treesitter parsers for PHP, Vue, TypeScript, JavaScript, JSON, YAML, Markdown, SQL, Dockerfile and bash. There's no Blade parser in this nvim-treesitter version
- Format on save with each project's own tools, only where the project has them: its `vendor/bin/pint` for PHP, its `eslint --fix` for JS/TS/Vue (Prettier instead where there's a Prettier config but no ESLint one), and Prettier for CSS, JSON and YAML where there's a Prettier config. It runs after the write, so saving isn't held up
- Pest tests in a floating-terminal tab, through Sail when the project has it (`lua/testrun`): `<leader>tn` runs the `it()`/`test()` at or above the cursor, `<leader>tf` the file, `<leader>tl` the last run again

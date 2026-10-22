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
  - `<leader>go` opens the file at the cursor's line (or the selection) on GitHub, on the current branch (or the commit when HEAD is detached), which has to be pushed
  - git-blame.nvim shows the blame for the current line
- Language servers for PHP (intelephense), Vue (vue-language-server 2.2.8, with ts_ls for the TypeScript inside .vue files), TypeScript, HTML, CSS and JSON. NvChad's keys apply: `gd` definition, `gr` references, `<leader>ra` rename, `<leader>ca` code actions
  - Install them on a new machine with `:MasonInstall intelephense typescript-language-server vue-language-server@2.2.8 html-lsp css-lsp json-lsp`. Keep Vue on 2.x: 3.x needs a newer lspconfig than `lazy-lock.json` holds, so updating it in the Mason window (or `:MasonInstallAll`) breaks Vue navigation. nvim warns on startup if that happens
- Treesitter parsers for PHP, Vue, TypeScript, JavaScript, JSON, YAML, Markdown, SQL, Dockerfile and bash. There's no Blade parser in this nvim-treesitter version
- Format on save with each project's own tools, only where the project has them: its `vendor/bin/pint` for PHP, its `eslint --fix` for JS/TS/Vue (Prettier instead where there's a Prettier config but no ESLint one), and Prettier for CSS, JSON and YAML where there's a Prettier config. It runs after the write, so saving isn't held up
- Claude Code in floating-terminal tabs, one per git root, connected to nvim so it sees the file and selection and its edits open as diffs here (`lua/agent`)
  - `<leader>ac` opens or focuses Claude for this project. `:ClaudeCode` uses the same tabs
  - `<leader>as` pastes `@file#L12-30` for the selection (or the file) into Claude without sending it. `<leader>aq` pastes the quickfix list, `<leader>at` the last test run's output
  - `<leader>ae` explains the selection in a float, with no session needed. `q` closes it
  - `<leader>ar` opens diffview with everything changed since that Claude tab started. Press it again to close
  - `<leader>ay` / `<leader>an` accept or reject Claude's proposed edit
  - In a folder Claude doesn't trust yet, answer its trust prompt before sending anything, or the text is lost
- `<leader>gm` asks Claude for a commit message for what's staged, in the style of recent commits and starting with the branch's ticket. `:w` commits it
- `<leader>gj` opens the Jira ticket at the start of the branch name (SD-486-backend opens SD-486)
- Git worktrees (`lua/worktrees`)
  - `<leader>ww` lists the repo's worktrees with branch, uncommitted files, last commit's age and subject. `⌂` marks the main checkout, `●` the one nvim is in and `✳` one with a Claude tab
  - `Enter` moves nvim there: it saves a session for the worktree it leaves, closes its files and restores the other's session. Terminal tabs keep running. It refuses while a file has unsaved changes
  - `Ctrl+a` starts or focuses Claude in it. `Ctrl+s` checks its branch out in the main checkout: main's changes are stashed and the worktree is detached (its files stay as they are), after a confirm saying exactly that. It refuses while main has unsaved files or the worktree has a Claude tab, and offers to undo if a step fails
  - `<leader>wn` asks for a ticket key and a short name and makes `SD-501-backend` in `control-plane-sd-501-backend` from a freshly fetched `origin/main`, then offers to start Claude in it. It has no `vendor/` or `node_modules` yet
  - Sessions are kept in `~/.local/share/nvim/sessions`. Nothing restores one on startup, and quitting only saves over a session this nvim restored or saved itself
- Pinned files with harpoon, a list per project and branch, with one shared list for any detached HEAD (`lua/pins`): `<leader>pa` pins the file, `<leader>pp` opens the list (edit it like a buffer to reorder or remove), `<leader>1`..`<leader>4` jump to a pin
- `s` plus two letters jumps to any word on screen (flash.nvim)
- Laravel pickers (`lua/laravel`): `<leader>lr` lists the routes and Enter opens the controller at the method (`Ctrl+l` reloads them). `<leader>lj` lists what the method under the cursor (or the class) uses, its `<Class>Test.php` tests, and for a test the class it tests
- `<leader>ps` runs PHPStan through Sail and puts the errors in the quickfix list (`lua/phpstan`)
- `<leader>sq` opens dadbod-ui on the project's database, read from its `.env` and connecting through the port Sail forwards, and named after the folder whose Sail is running when that is another worktree (`lua/dbkeys`)
- PHP debugging with Xdebug through Sail (`lua/debugger`). `F5` starts listening on port 9003 (or continues), `F9`/`<leader>db` toggles a breakpoint, `<leader>dB` adds one with a condition, `F10`/`F11`/`F12` step over/into/out, `<leader>dc` continues, `<leader>dq` stops, `<leader>du` shows or hides the debug panels, `<leader>de` evaluates the word under the cursor or the selection
  - `/var/www/html` maps to the folder the running Sail was started from (usually main), and starting a session from a worktree that isn't running Sail warns that its breakpoints won't match the code that runs. The panels open when a session starts and close when it ends
  - Xdebug only connects with `SAIL_XDEBUG_MODE=develop,debug` in the project's `.env`, followed by `sail down && sail up -d`. Starting a session warns with that line when it's missing
- Pest tests in a floating-terminal tab, through Sail when the project has it (`lua/testrun`): `<leader>tn` runs the `it()`/`test()` at or above the cursor, `<leader>tf` the file, `<leader>tl` the last run again

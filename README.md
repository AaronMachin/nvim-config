# nvim config

My Neovim config, built on the [NvChad starter](https://github.com/NvChad/starter) (NvChad v2.5). NvChad itself is loaded as a plugin, so this repo only holds what I've changed on top of it.

## Install

On a Mac with [Homebrew](https://brew.sh):

1. Install what it needs:
   ```sh
   brew install neovim git ripgrep node lazygit
   brew install --cask font-jetbrains-mono-nerd-font
   ```
   Set your terminal's font to JetBrainsMono Nerd Font (any Nerd Font works), or the icons show as boxes.
2. Move any config you already have out of the way, then clone this one in its place:
   ```sh
   mv ~/.config/nvim ~/.config/nvim.old 2>/dev/null
   git clone https://github.com/AaronMachin/nvim-config ~/.config/nvim
   ```
3. Copy the settings file and fill it in (it's only `JIRA_URL` for now, for `<leader>gj`):
   ```sh
   cp ~/.config/nvim/.env.example ~/.config/nvim/.env
   ```
4. Open `nvim` and wait for lazy.nvim to install the plugins (at the versions in `lazy-lock.json`), then quit and open it again.
5. In nvim, install the language servers and the PHP debugger:
   ```
   :MasonInstall intelephense typescript-language-server vue-language-server@2.2.8 html-lsp css-lsp json-lsp php-debug-adapter stylua
   ```
6. If you use [Claude Code](https://claude.com/claude-code), let it tell the floating terminal what it's doing:
   ```sh
   ~/.config/nvim/install-claude-hooks.sh
   ```
   Then in Claude, `/config` → Diff tool → `terminal`, so edits to approve show in Claude's tab rather than taking over nvim.
7. Turn on mouse reporting in your terminal app, so clicks and the mouse wheel reach nvim (Warp: Settings → Features → Enable Mouse Reporting).

To update, `git pull` in `~/.config/nvim` and run `:Lazy restore` so the plugins match `lazy-lock.json`.

`make test` runs the test suite (about 10 seconds, kept apart from your real nvim data; see `tests/README.md`). `make test FILE=tests/notes_spec.lua` runs one file.

## What's added

- A floating terminal with tabs and rounded corners, leaving 10% of the screen open at the top and a small gap at the sides and bottom (`lua/floatterm`)
  - Option+left/right move a word and Cmd+left/right (or Home/End) go to the start or end of the line, as in the terminal app
  - `<leader>tt` opens it, and `Ctrl+\` (or `Alt+i`) opens or hides it from anywhere, including inside it. Hiding keeps every tab running
  - Inside it, `Ctrl+t` opens a new tab, and `Ctrl+Shift+n` / `Ctrl+Shift+p` move to the next and previous one (`Ctrl+|` also moves to the next, in a terminal app that sends it as its own key), and `Ctrl+Opt+←/→` (or `↑/↓`) move the tab itself earlier or later where the terminal app sends Option as Alt
  - `exit` closes a tab, and closing the last one closes the float
  - With the tab bar on (left or top), each Claude tab shows its state first (`● needs you`, `◌ working · 4m`, `✓ done`), then what it's working on, then its folder. Shell tabs show their folder and what's running. Click a tab to open it
  - `Ctrl+Shift+b` moves into the bar, and a popup beside the selected tab lists what the keys do to it: `j/k` move, `Enter` opens, `x` closes (asks first for Claude or a running command), `1`-`9` open that tab, `K`/`J` (or `H`/`L`) move the selected tab earlier or later, `r` renames, `g` puts the tab under a parent (the bar numbers the tabs it can go under, type one, `0` for none), `za` folds a parent's children, `Esc` goes back
  - Related Claude tabs can sit under a parent (a planning session and the workstreams it split out). When a new Claude tab's first prompt points into a `.superpowers/<slug>/` folder another tab's session wrote, it asks once whether to make it a child; if no tab wrote there but another tab's first prompt used the same folder, it offers a group heading for both. The parent's notes get a Workstreams section with each child's state, what it's doing and its progress (Enter jumps to it), each child's notes show "part of" its parent, and `<leader>aa` groups them. `<leader>tp` puts the tab showing under another the same way. The links are saved with the tabs
  - Opening the float goes to a tab whose Claude needs you, and you get a one-off notification when one starts waiting
  - `Ctrl+Shift+f` goes full-screen and back. An arrow key from full-screen docks to that edge, and `Ctrl+Shift+g` goes to the box
  - `:FloatTermSettings`, or `Ctrl+Shift+,` inside the terminal, opens a page with every setting. `j/k` move, `←/→` change, `Enter` cycles a choice or lets you type a number, `Tab` picks large or small on the docked sizes row, `q` closes. Changes apply straight away and are kept in `~/.local/share/nvim/floatterm-settings.json`. Starting position is only for a project that hasn't used the terminal yet
  - With "reopen tabs" on, each nvim started in a folder keeps its own saved tabs, saved a second or two after they change, every 30 seconds, when nvim loses focus and on quit, so a crash or power cut loses a couple of seconds at most. Starting nvim there again reopens them in the background: Claude tabs resume their conversation and shell tabs come back as fresh shells (nothing is re-run). A Claude tab with no conversation yet starts fresh, and one that can't be resumed is kept and tried once more
  - If another nvim is open in the folder, you're asked whether to open the same tabs (its Claude tabs resume the same conversations, so the two can clash) or start fresh. With several saved sets and no other nvim, a picker lists each with when it was saved and its tabs: `Enter` opens one, `Ctrl+d` deletes one. The 10 most recent sets per folder are kept. Opening nvim on a file, on stdin (`-`), with `-S`, `-q` or a `+command` (or headless) doesn't save or restore
  - Tabs show relative line numbers, as code windows do. `Ctrl+x` turns the terminal into a normal buffer for scrolling (`12k`), searching and copying (`y` goes to the system clipboard, with lines that were only wrapped to fit the tab joined back into one, so a long command pastes as one line). `i` goes back to typing. In a Claude tab, scroll the conversation with Claude's own `PgUp`/`PgDn` (`Fn+↑`/`Fn+↓` on a Mac) or the mouse wheel while you type, as Claude draws it on a screen nvim can't scroll. The wheel needs the terminal app to pass mouse events on (Warp: Settings → Features → Enable Mouse Reporting)
  - Docked (the default), `Ctrl+Shift+←/→/↑/↓` (or `Ctrl+Shift+h/l/k/j`, for terminal apps that keep the arrows) docks it to that edge at 90% of the screen. Pressing the same arrow again flips it between 90% and a 20% strip
  - `Ctrl+Shift+d` takes the terminal out of the float into a real split beside the code, with the same tabs and the tab bar inside it. The same keys move it to another edge or flip its size, and it always leaves the code at least 20 columns or 5 rows. `Ctrl+\` then moves between the code and the terminal, and `Ctrl+Shift+d` again goes back to floating
  - `Ctrl+Shift+g` switches to a floating box a ninth of the screen, and the arrows then move it a square at a time round a 3×3 grid, stopping at the edges. `Ctrl+Shift+g` again docks it back where it was (not `Ctrl+Shift+m`, which nvim reads as Shift+Enter)
  - A move that would leave the terminal under 5 rows or 20 columns does nothing. `:FloatTerm left|right|top|bottom|mode|full|split` does the same as the keys. Each project remembers where it was last (full-screen and split included) and opens there next time
  - `<leader>o` lists every terminal action in the which-key panel, like any other leader group, each with its direct shortcut beside it: `d` split, `f` full-screen, `g` dock/box, `h/j/k/l` move, `t`/`n`/`p` new, next and previous tab, `1`-`9` go to a tab, `<`/`>` move the tab earlier or later, `x` force-closes a hung tab (asking first for a Claude one), `b` tab bar, `s` settings, `q` hide or show. It works from code too; inside a terminal tab press `Ctrl+x` first. The `Ctrl+Shift` keys still work without it
  - A one-line hint, "Ctrl+x then <leader>o for options", sits in the gap above or below the float (or in its bottom border when there's no gap). The settings page hides or shows it
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
  - Notes per tab (`lua/floatterm/notes`): `<leader>o e` switches them on or off for the tab you're in, and a tab with notes gets `✎` in the bar. The pane sits beside the terminal: Claude's notes on top (read-only) and yours below, an ordinary markdown file saved as you go. `Ctrl+Shift+e` moves between the terminal and the notes (switching them on if they're off), landing on an empty line at the end, typing. Inside them `Ctrl+Shift+h/j/k/l` moves the pane to that side, or towards the side it's on steps its size 25% → 35% → 50%. Claude's part takes up to two-thirds of the pane (the "Claude's share" setting), less when it's short. Claude's title says when it was last refreshed, and when its notes don't fit, how many lines are hidden. `Ctrl+Shift+o` in yours shows them all in a float: `Tab`/`Shift+Tab` move between the links and the fold lines, `Enter` or a click opens a link in the browser or opens a fold, `d`/`t` open or fold Decisions and Details, `y` copies, `q` closes. Open folds are remembered per note (in `<id>.claude.folds.json` beside it) and show in the pane too. In the floating box there's no room beside it, so `Ctrl+Shift+e` shows the notes over the terminal and `Esc` goes back
  - `Y` on a selection in a terminal tab adds it to that tab's notes with wrapped lines joined, `<leader>o y` on a selection in code adds it with `path:12-30`, and `<leader>o a` adds a one-line note. `<leader>o o` lists earlier notes in the folder with Claude's summary and hashtags, and typing searches those too, along with Claude's title and what it was doing (`#deploy` finds notes tagged deploy, `SD-494` the note on that ticket). The preview shows Claude's notes above yours. `Enter` gives them to the current tab, `Ctrl+d` deletes. They're kept in `.nvim/fterm/notes/` in the folder nvim started in (`.nvim/` is in the global git ignore). Notes are never deleted for you (only `Ctrl+d` deletes), and the list leaves out notes with nothing in them yet
  - With notes on in a Claude tab, a small Claude (Haiku by default, or Sonnet in the settings) rewrites Claude's half of the notes after each turn as a dossier of the session, always in the same shape. At the top, the ticket and a short title, then the tab's state (`● ◌ ✓`) with what Claude is doing now and a progress bar at the right end, then hashtags. The bar's percentage is worked out from the tasks (in progress counts as half), and it's green, blue while a task is in progress, red if one is blocked. While the tab's Claude needs you, what it's asking replaces what it's doing straight away. Under LINKS, the tickets and PRs it created, worked on or reviewed, each shown by its title (the URL is hidden) with a note such as "Opened" or "In development" in a column beside it. Under PLAN, the tasks (`✓` done, `▸` in progress, `·` pending, `!` blocked) with what each is doing in a column beside it, cut with … to fit; with more than 6 tasks the done ones fold into one line, with at most 6 task rows showing. Decisions and Details are folded into one line at the bottom. Claude replies in a fixed schema (`claude -p --json-schema`) and nvim draws it, so the layout can't drift. The same content goes in `<id>.claude.md` as plain text with the URLs written out, for Claude in the tab to read. It always shows from the top. It runs in the background, one at a time per tab, costs about a twentieth of a penny a turn, and doesn't show up in `claude --resume`. `<leader>o r` refreshes it now. Secrets (tokens, keys, passwords) are replaced with `[redacted]` before anything is sent, but links are kept whole apart from values such as `?token=` in them. It can be switched off in the settings, and with two tabs on one note only the first keeps it up to date
- Run `~/.config/nvim/install-claude-hooks.sh` once so Claude tells the floating terminal what it's doing (`--uninstall` takes it out). It adds hooks to `~/.claude/settings.json` that do nothing outside nvim's terminal. A `claude` typed in any tab makes it a Claude tab until Claude exits. Run it again after an update; it adds only what's missing
- `<leader>aa` lists every Claude tab in this nvim, whatever worktree it's in: its state (`● ◌ ✓` with how long), name, folder and its Claude notes' title and what Claude is doing now. Needs you first, then working, then done. The preview shows its Claude notes as the pane does (with what it's asking, while it waits). `Enter` goes to the tab, `Ctrl+o` opens its PR (the first link whose title or URL looks like a pull request, else the first link)
- A bookmark in the top right shows one mark per Claude tab (`● ◌ ✓`), open float or not. `<leader>ab` hides or shows it
- Claude Code in floating-terminal tabs, one per git root, connected to nvim so it sees the file and selection and its edits open as diffs here (`lua/agent`)
  - `<leader>ac` opens or focuses Claude for this project. Terminal tabs aren't reported to Claude as the file you're in, only real files are. `:ClaudeCode` uses the same tabs
  - `<leader>as` pastes `@file#L12-30` for the selection (or the file) into Claude without sending it. `<leader>aq` pastes the quickfix list, `<leader>at` the last test run's output
  - `<leader>ae` explains the selection in a float, with no session needed. `q` closes it
  - `<leader>ar` opens diffview with everything changed since that Claude tab started. Press it again to close
  - `<leader>ay` / `<leader>an` accept or reject Claude's proposed edit
  - In a folder Claude doesn't trust yet, answer its trust prompt before sending anything, or the text is lost
- `<leader>gm` asks Claude for a commit message for what's staged, in the style of recent commits and starting with the branch's ticket. `:w` commits it
- `<leader>gj` opens the Jira ticket at the start of the branch name (SD-486-backend opens SD-486), on the Jira site in `$JIRA_URL` (`export JIRA_URL=https://yours.atlassian.net` in your shell profile)
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

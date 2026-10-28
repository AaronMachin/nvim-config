# Tests

Specs for the modules in `lua/`, run headless with plenary.nvim's busted.

```sh
make test                              # every tests/*_spec.lua, side by side (~10s)
make test FILE=tests/notes_spec.lua    # one file
```

`tests/run.sh` does the work. Plugins come from the real lazy folder (`~/.local/share/nvim/lazy`, or `NVIM_TEST_LAZY`); nothing is installed.

## What's isolated

Each run makes a throwaway folder and deletes it afterwards:

- `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` and `TMPDIR` point into it, and `tests/minimal_init.lua` refuses to start if they don't. It doesn't run `init.lua` (lazy.nvim and base46's cache would want the real data folder): it puts `lua/` and the plugins the modules use on the runtimepath.
- Each test (`H.isolate()` in `tests/helpers.lua`) points the floatterm settings file, `vim.g.floatterm_placement_dir`, `vim.g.floatterm_tabs_dir`, grepmask's `state_path`, the worktrees sessions folder and the notes folder at a fresh temp folder, and cds into a fresh start folder.
- `claude`, `gh`, `docker`, `lazygit`, `sail` and `phpstan` are guard scripts first on `PATH`: if anything runs one, the run fails and says what ran. Specs that need one put their own fake first on `PATH` (a fake `claude` for Claude's notes and restore, `php` for routes, `gh` for the GitHub link, `vendor/bin/sail` in a fixture for PHPStan).
- git uses a config of its own (`GIT_CONFIG_GLOBAL`, no system config), so your hooks and signing don't apply. Repos are built per test from a bare "origin" in the temp folder.
- Terminal tabs run `sleep` (the default shell is a script that runs `sleep`), and are stopped after each test.
- The run fails if `~/.config/nvim/.nvim` appears.

Restore and the remembered placement need a fresh nvim per case, so those specs start a child nvim (`H.child`) with the same isolation.

## Files

| File | Covers |
| --- | --- |
| `floatterm_spec.lua` | settings, tab records and events, placements (docked, box, full, split), moves, tab bar and notes room, previous/next/move tab, force-close, unwrapped copy |
| `tabbar_spec.lua` | the bar's lines down the left and along the top, fitting and truncating, the bookmark |
| `config_page_spec.lua` | a row per setting, changing values with the page's keys |
| `menu_spec.lua` | `<leader>o` keys and their descriptions with shortcuts, the panel |
| `claude_spec.lua` | hook events to record fields, which Claude a tab listens to |
| `claude_notes_spec.lua` | drawing the sheet, redaction, reading the turn, the run's guards |
| `notes_spec.lua` | paths, on/off, captures, empty-note cleanup, Claude's pop-up, sharing with another nvim, the picker's filtering |
| `overview_spec.lua` | the Claude overview's order and preview |
| `restore_spec.lua` | saved sets per nvim, saving, migration, the picker, another nvim's tabs, the 10-set cap |
| `grepmask_spec.lua`, `testrun_spec.lua`, `git_spec.lua` (gitkeys, pins), `phpstan_spec.lua`, `dbkeys_spec.lua`, `laravel_spec.lua`, `worktrees_spec.lua` | the smaller modules |

`fixtures/laravel` is a small Laravel-shaped project for the routes spec; it's copied to the temp folder before use.

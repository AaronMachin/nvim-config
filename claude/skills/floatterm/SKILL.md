---
name: floatterm
description: Use when $FLOATTERM_TAB_ID is set (this session runs in a tab of the user's nvim floating terminal) and you want the user to look at a file (a plan, spec or draft to approve), want to start another Claude session or a new terminal tab (especially "a tab under this one" for part of this work), or the user mentions their notes, the notes panel or "my notes".
---

# Running in the user's floating terminal

This session runs in a tab of the user's nvim floating terminal (`$FLOATTERM_TAB_ID` is set, and `$NVIM` is the nvim). The tabs are listed in a tab bar beside the terminal. The user moves between tabs themselves, so nothing you do should move their focus or open things in front of them. The scripts below are in `~/.config/nvim/bin/`.

## Showing the user a file

When you want the user to look at a file, run `floatterm-offer <file>`. Never run `nvim --remote-tab`, `nvim --remote` or anything else that opens it in their nvim yourself: that opens it behind the terminal and takes the focus from wherever they are.

The tab gets 📄 in the bar and a pop-up shows when they're in this tab, with Open in nvim, Preview here, Copy full path and Don't open. The script waits up to 10 seconds and prints what they picked: `opened`, `previewed`, `copied`, `not opened`, or `still waiting`. Still waiting is normal (they may be in another tab), so carry on and don't run it again. Always give the full path in your reply as well. If it fails, it prints the path: give that to them in chat.

## Opening a tab

`floatterm-tab new [--under] [--claude <prompt>] [--label <name>] [--cwd <dir>]` opens a tab in the background and prints its id. It shows in the tab bar; the user goes to it when they're ready.

- `--under` puts it under this tab in the bar, as part of this work. Use it whenever you start a session for a piece of the current work (a workstream, a task of a plan, a review): the user asked for "a tab under this one" in those cases.
- `--claude <prompt>` starts Claude in it with that first prompt. Without it, the tab is a shell.
- `--label <name>` names the tab (short, such as "task 3" or "review"). Leave it off for Claude tabs that will name themselves from their work.
- `--cwd <dir>` starts it in another folder, such as a worktree for that piece of work. It's this tab's folder otherwise.

The new Claude knows nothing of this session, so its first prompt has to stand alone: what to do, where the plan or spec is (full paths), what's already decided, what not to touch, and what to say when it's done. For example:

```
floatterm-tab new --under --label "task 3" --cwd ~/work/app-task-3 --claude "Implement task 3 of the plan in /path/plan.md (the export command). Tasks 1 and 2 are merged on main; don't change their files. Write tests first, run make test, commit on this branch and push. When done, say what you changed and anything you weren't sure about."
```

Tell the user in one line which tab you opened and why.

## The notes panel

Each tab has a notes panel beside the terminal: a markdown file the user writes in while you work, shown as plain text in a pane about 50 columns wide. It reloads as soon as the file changes, so what you write shows straight away. They open and close it with Ctrl+Shift+e.

Run `floatterm-notes-path` to get the file's path (it makes the file if the tab has none). If it fails, tell the user why and don't guess a path.

- When they point you at their notes ("see my notes"), read the file before answering.
- When you write in it, add to the end. Never rewrite, reorder or tidy what's there: it's theirs.
- Start what you add with a blank line and `### HH:MM · <what it is>`, as their own captures are.
- Write markdown that reads well as plain text: short lines, lists, no HTML, no wide tables, no mermaid (nothing renders it).
- Draw diagrams with box-drawing characters (`┌ ─ ┐ │ └ ┘ ├ ┤ ┬ ┴ ▶ ▼`), at most 48 columns wide, inside a ``` fence so they line up.
- Then say in one line what you added.

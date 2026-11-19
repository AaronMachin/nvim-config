---
name: notes-panel
description: Use when the user mentions their notes, the notes panel or "my notes" and $FLOATTERM_TAB_ID is set (this session runs in a tab of their nvim's floating terminal). For example "put a summary of the plan with a diagram in my notes", "add that to my notes", "see my notes".
---

# The notes panel

The user's nvim runs this session in a tab of its floating terminal. Each tab has a notes panel beside the terminal: a markdown file the user writes in while you work, shown as plain text in a pane about 50 columns wide. The pane reloads as soon as the file changes on disk, so what you write shows straight away. They open and close it with Ctrl+Shift+e.

## Finding the file

Run `~/.config/nvim/bin/floatterm-notes-path`. It prints the file's path, making the file if the tab has none yet. If it fails, tell the user why (its message says) and don't guess a path.

## Writing in it

- Add to the end. Never rewrite, reorder or tidy what's there: it's the user's.
- Start what you add with a blank line and a heading of the form `### HH:MM · <what it is>`, as their own captures are.
- Write markdown that reads well as plain text: short lines, lists, no HTML, no tables wider than the pane, no mermaid (nothing renders it).
- Draw diagrams with box-drawing characters (`┌ ─ ┐ │ └ ┘ ├ ┤ ┬ ┴ ▶ ▼`), at most 48 columns wide, inside a ``` fence so they line up.
- Then say in one line what you added and where.

## Reading it

When the user points you at their notes ("see my notes", "as in my notes"), read the file before answering.

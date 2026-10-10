+++
title = "Commands"
weight = 4
description = "The :Shortcut subcommands, and how the story they act on is chosen."
+++

## :Shortcut

`:Shortcut` is the plugin's only command. It takes a subcommand; with none, it lists them. Subcommand names
are completed with <kbd>Tab</kbd>, and so are the arguments of `:Shortcut state` (state names) and
`:Shortcut create` (keys and values).

| Command | Description |
|---|---|
| `:Shortcut story [id \| sc-<id> \| url]` | Open a [story](@/buffers.md#story-buffers); without an argument, the git branch's story |
| `:Shortcut epic {id \| sc-<id> \| url}` | Open an [epic](@/buffers.md#epic-buffers) |
| `:Shortcut search [query…]` | Search stories (live with snacks.nvim); see [Searching](@/searching.md) |
| `:Shortcut mine` | Your unfinished stories |
| `:Shortcut epics [query…]` | Search epics (live with snacks.nvim) |
| `:Shortcut create [key=value…]` | Open a draft of a new story; `:w` creates it (see [Creating stories](@/editing.md#creating-stories)) |
| `:Shortcut comment [target]` | Write a comment on the story in a floating window; `:w` posts it |
| `:Shortcut state [target] [state]` | Move the story to another workflow state |
| `:Shortcut browse [target]` | Open the story or epic in the browser |
| `:Shortcut yank [target]` | Copy the URL of the story or epic |
| `:Shortcut refresh` | Fetch the [lookup lists](@/configuration.md#the-lookup-list-cache) again and reload the current Shortcut buffer |
| `:Shortcut diff` | Compare a story buffer with the story on Shortcut (see [Conflicts](@/editing.md#conflicts)) |
| `:Shortcut login` | Save an API token to the shared `short` config (see [Authentication](@/authentication.md#shortcut-login)) |
| `:Shortcut help` | List available subcommands |

## The current story

`comment`, `state`, `browse` and `yank` work on "the current story", which is the first of:

1. **the argument** (`[target]`), if given: an ID, `sc-<id>`, or a Shortcut link;
2. **the current buffer**, if it is a story or epic buffer (or a comment being written);
3. **the git branch** of the current file's repository (or, for buffers that are not files, of the working
   directory): the first `sc-<id>` in the branch name, as in Shortcut's `<user>/sc-<id>/<slug>` format. A
   detached HEAD or a directory outside git does not count.

Otherwise the command explains how to name a story. `:Shortcut story` with no argument uses the git branch
only. `comment` and `state` work on stories; `browse` and `yank` on epics too (a bare ID is looked up to find
out which it is).

## Comments

`:Shortcut comment` opens a floating Markdown buffer titled `Comment on sc-<id>: <title>`. `:w` posts it and
closes the float (`:wq` works too); `:q!` discards it. Empty comments are not posted. If posting fails, the
text stays in the buffer. Afterwards the story's buffer, if open, is reloaded to show the comment, unless it
has unsaved changes.

- Only writing the float to its own name posts (`:w`, `:w!`, `:wq`, `:x`, `:update`). Writing it anywhere
  else (`:w file`, `:wq file`, `:saveas file`, `:1,2w file`, `:w >> file`) fails with an error, so
  `:wq file` doesn't close the float: nothing is posted and no file is written.
- `:wall`, `:wqa` and `:xa` run from another window don't post the draft either: it stays modified, so
  `:wqa` and `:xa` don't exit. Run in the float itself, they post it (like `:w`), and `:wqa`/`:xa` wait for
  the answer (up to 10 seconds): if posting fails or takes longer, Neovim doesn't exit and the text stays.
- If Neovim exits anyway with a comment still being posted (`:w` then `:qa`), it waits for the answer (up to
  15 seconds). A comment that could not be posted, or whose answer didn't come (it may still have been
  posted), is saved under `stdpath('state')/shortcut/unsent/` and the path is printed.

## Changing the state

`:Shortcut state` lists the states of the story's workflow in order, the current one marked, with
`vim.ui.select`. Give a state name to move the story directly:

```vim
:Shortcut state In Progress
:Shortcut state sc-<id> Done
```

- Names are completed with <kbd>Tab</kbd> (the current story buffer's workflow, or every workflow's), matched
  ignoring case, and may contain spaces.
- The target, if any, comes first, as `sc-<id>` or a link. A bare ID is the target only on its own
  (`:Shortcut state 123`): followed by more words it is read as the start of the state name, so a state
  named `2 Review` never moves story 2.
- The story's buffer, if open, is reloaded; if it has unsaved changes, you are warned that its header is
  stale.

## Links

- `:Shortcut browse` opens the story's or epic's link with `vim.ui.open()`.
- `:Shortcut yank` copies the link to the unnamed register and the clipboard (`+`, and `*` when it is a
  separate selection, as on X11).

## Refreshing

`:Shortcut refresh` clears the [lookup-list cache](@/configuration.md#the-lookup-list-cache) (in memory and on
disk) and fetches the lists again in the background. If the current buffer is a story or epic without
unsaved changes, it is reloaded too.

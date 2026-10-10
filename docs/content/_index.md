+++
title = "Overview"
sort_by = "weight"
template = "index.html"
page_template = "page.html"
+++

`shortcut.nvim` lets you browse, search, and edit [Shortcut](https://www.shortcut.com/) stories and epics
without leaving Neovim. Stories and epics open as Markdown buffers: `:e` a story link or `sc-<id>`, edit
it, and `:w` saves it back to Shortcut. Authentication is shared with the
[`short` CLI](https://github.com/shortcut-cli/shortcut-cli), so if you already use it there is nothing to set
up.

The same documentation is in Neovim, as `:help shortcut`.

## Features

- **Search** stories and epics with live results and previews in
  [snacks.nvim](https://github.com/folke/snacks.nvim), or with `vim.ui.select` without it. See
  [Searching](@/searching.md).
- **Open** stories and epics as Markdown buffers by ID, `sc-<id>`, a web app link, or `gf`. See
  [Story and epic buffers](@/buffers.md).
- **Edit** the title, description, state, owners, epic, iteration, estimate, labels and tasks, and save with
  `:w`. Only what you changed is sent, and someone else's changes are never overwritten silently. See
  [Editing and creating](@/editing.md).
- **Create** stories from a template, **comment**, move a story to another **state**, and open or copy its
  link, from the [commands](@/commands.md).

## Quick start

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'calebstewart/shortcut.nvim',
  dependencies = { { 'folke/snacks.nvim', optional = true } },
  opts = {},
}
```

Then give it an API token. If you already use the `short` CLI there is nothing to do; otherwise run

```vim
:Shortcut login
```

and paste a token from Shortcut's
[Settings → API Tokens](https://app.shortcut.com/settings/account/api-tokens). Other ways to provide one are
under [Authentication](@/authentication.md).

Now try it:

```vim
:Shortcut mine          " your unfinished stories
:Shortcut search type:bug !is:done
:e sc-<id>              " open a story or an epic by its ID
:Shortcut story         " the story of the current git branch
```

Edit the buffer and `:w`. `:checkhealth shortcut` tells you if anything is missing.

> [!NOTE]
> Don't lazy-load the plugin on the `:Shortcut` command alone: opening links and `sc-<id>` names with `:e`
> only works if it is loaded at startup. See [Installation](@/installation.md#lazy-nvim).

## Requirements

- Neovim 0.12 or newer
- `curl`
- Optional: `git`, to find the story of the current branch
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for the pickers (without it they fall back to
  `vim.ui.select`)

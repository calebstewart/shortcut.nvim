+++
title = "Searching"
weight = 7
description = "The search, mine and epics pickers, their keys, the query syntax, and the fallback without snacks.nvim."
+++

## The pickers

- **`:Shortcut search [query…]`** searches stories. The arguments are joined into the starting query; with
  [snacks.nvim](https://github.com/folke/snacks.nvim), every change to the query searches again (the request
  in flight is cancelled). With no query, nothing is shown until you type one (Shortcut rejects empty
  searches).
- **`:Shortcut mine`** lists your unfinished stories: `owner:<your mention name> !is:done !is:archived`.
  Typing filters this list locally instead of searching again.
- **`:Shortcut epics [query…]`** searches epics. With no query it starts with `!is:done !is:archived`
  (not-done epics), which you can edit.

Choosing a result opens its [buffer](@/buffers.md).

## Query syntax

Queries use Shortcut's
[search operators](https://www.shortcut.com/help/fields-and-features/search-operators), as in the web app:

```text
owner:someone state:"In Progress" epic:123 type:bug
```

Operators combine with AND, and `!` or `-` in front of one negates it (`!is:done`). Results arrive a page at
a time ([`picker.page_size`](@/configuration.md#options) per request), up to
[`picker.max_results`](@/configuration.md#options) (the API stops at 1000).

## With snacks.nvim

Each row shows `sc-<id>`, the workflow state (coloured by its type: backlog, unstarted, started, done; states
of other types are not coloured), the story type (`feat`, `bug`, `chore`), the title, and the owners
(dimmed). Epic rows show the ID, state and name.

### Previews

The preview shows the story or epic as its buffer would, with modelines off. It is fetched once the cursor
has rested on a row for 300 ms, so moving through the list doesn't fetch every row, and at most 40 previews
are fetched per minute (past that the preview says it is waiting), well within the API's
[limit](@/troubleshooting.md#rate-limits) of 200 requests per minute.

Previews are cached for 5 minutes; any change made from Neovim (saving a buffer, `:Shortcut state`, a
comment…), `:Shortcut refresh`, or loading the object's buffer drops them sooner.

### Keys

| Key | Action |
|---|---|
| <kbd>Enter</kbd> | Open the story or epic (`shortcut://<kind>/<id>`) in the current window; with several selected (<kbd>Tab</kbd>), open each |
| <kbd>Ctrl-S</kbd> / <kbd>Ctrl-V</kbd> / <kbd>Ctrl-T</kbd> | Open in a split / vertical split / new tab (snacks' defaults) |
| <kbd>Ctrl-Y</kbd> (input), <kbd>y</kbd> (list) | Copy the web link, like `:Shortcut yank` (unnamed register and clipboard) |
| <kbd>Alt-B</kbd> | Open the web link in the browser (`vim.ui.open()`) |

These follow snacks' own GitHub pickers, which use the same keys to copy and browse. Every other snacks key
works as usual (<kbd>Ctrl-G</kbd> toggles live search off to filter the results locally).

The web link used by the copy and browse keys is the result's own link only if it is a Shortcut web app link
to that same story or epic; otherwise it is built from your workspace, as `:Shortcut yank` does.

### Customizing the pickers

The pickers are snacks sources named `shortcut_search`, `shortcut_mine` and `shortcut_epics`. Settings under
`picker.sources.<name>` in your snacks configuration apply on top of the plugin's, e.g. to change keys or
the layout:

```lua
require('snacks').setup({
  picker = {
    sources = {
      shortcut_search = {
        layout = 'vertical',
        win = { list = { keys = { ['<c-o>'] = 'shortcut_browse' } } },
      },
    },
  },
})
```

The actions are `shortcut_copy_url` and `shortcut_browse`.

### Highlights

The picker rows use these groups. Each is a default link (`:highlight default link`), so your colour scheme or
config can change it; they are defined again after `:colorscheme`.

| Group | Default | Used for |
|---|---|---|
| `ShortcutId` | `Number` | `sc-<id>` |
| `ShortcutStateBacklog` | `DiagnosticHint` | backlog states |
| `ShortcutStateUnstarted` | `DiagnosticInfo` | unstarted states |
| `ShortcutStateStarted` | `DiagnosticWarn` | started states |
| `ShortcutStateDone` | `DiagnosticOk` | done states |
| `ShortcutStateOther` | (no attributes) | states of other types |
| `ShortcutTypeFeature` | `Function` | `feat` |
| `ShortcutTypeBug` | `DiagnosticError` | `bug` |
| `ShortcutTypeChore` | `Constant` | `chore` |
| `ShortcutOwners` | `Comment` | owners |

## Without snacks.nvim

The commands still work, without live search or previews (an info message says so once per session):

- `vim.ui.input` asks for the query if none was given (not for `mine`; for `epics` it suggests the default);
- the first results (up to `picker.max_results`) are fetched;
- `vim.ui.select` lists them as `sc-<id> [state] title`.

Choosing one opens its buffer.

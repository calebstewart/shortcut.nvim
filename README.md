# shortcut.nvim

Browse, search, and edit [Shortcut](https://www.shortcut.com/) stories and epics without leaving
Neovim. Stories and epics open as Markdown buffers — `:e` a story URL or `sc-12345`, edit it, and
`:w` saves it back to Shortcut. Authentication is shared with the
[`short` CLI](https://github.com/shortcut-cli/shortcut-cli), so if you already use it there is
nothing to set up.

> [!WARNING]
> Early development. Most of the functionality described here is not implemented yet.

## Requirements

- Neovim >= 0.12
- `curl`
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for the pickers (falls back to
  `vim.ui.select`)

## Installation

### lazy.nvim

```lua
{
  'calebstewart/shortcut.nvim',
  dependencies = { { 'folke/snacks.nvim', optional = true } },
  opts = {},
}
```

`setup()` is optional; without it the defaults apply.

### Nix

The flake provides the plugin as a package and through an overlay:

```nix
{
  inputs.shortcut-nvim.url = "github:calebstewart/shortcut.nvim";

  # nixpkgs.overlays = [ inputs.shortcut-nvim.overlays.default ];
  # programs.neovim.plugins = [ pkgs.vimPlugins.shortcut-nvim ];  # home-manager
}
```

Try it without installing anything (uses an isolated config, not yours):

```sh
nix run github:calebstewart/shortcut.nvim
```

## Configuration

Defaults:

```lua
require('shortcut').setup({
  token = nil,            -- string | fun(): string; see "Authentication"
  cli_config_path = nil,  -- override path to the `short` CLI's config.json
  cache = { ttl = 24 * 60 * 60 },  -- lookup-list cache lifetime (seconds)
  sc_ids = true,          -- allow `:e sc-<id>`
  picker = { page_size = 25, max_results = 200 },  -- page_size: 1 to 250
  http = { timeout = 30 },  -- seconds
  tasks = {
    show_owners = true,   -- show task owners as a trailing ` · @mention` on task lines
    confirm_delete = true, -- ask before a save deletes tasks
  },
})
```

## Authentication

shortcut.nvim needs a Shortcut API token (create one under
[Settings → API Tokens](https://app.shortcut.com/settings/account/api-tokens)). It looks in these
places, in order, and uses the first token it finds:

1. **`token` in `setup()`**: a string, or a function returning one. A function is called once
   per Neovim session, so it can fetch the token from a password manager:

   ```lua
   require('shortcut').setup({
     token = function()
       return vim.trim(vim.fn.system({ 'pass', 'show', 'shortcut/api-token' }))
     end,
   })
   ```

2. **The `SHORTCUT_API_TOKEN` environment variable** (or the older `CLUBHOUSE_API_TOKEN`).
3. **The [`short` CLI](https://github.com/shortcut-cli/shortcut-cli)'s config file.** If you
   have run `short install`, there is nothing else to do. The file is found exactly where
   `short` looks for it: `~/.config/shortcut-cli/config.json` by default, or
   `$XDG_CONFIG_HOME/shortcut-cli/config.json` when `XDG_CONFIG_HOME` is set. (Like `short`,
   when `XDG_CONFIG_HOME` is unset but `XDG_DATA_HOME` is set, it uses
   `$XDG_DATA_HOME/.config/shortcut-cli/config.json`.) Set `cli_config_path` to use a different
   file; `require('shortcut.auth').cli_config_path()` shows the path in use.

Your mention name and workspace URL slug are read from the `short` config file when its token
is the one in use; otherwise they are fetched once per session from the API.

### `:Shortcut login`

`:Shortcut login` asks for a token (the input is hidden), checks it against the API, and saves
it with your mention name and workspace slug to the `short` config file, keeping every other
setting in it. `short` picks up the same token. If the saved token is for a different
workspace, you are asked before it is replaced; an invalid token saves nothing. A token from
`setup()` or `$SHORTCUT_API_TOKEN` still takes precedence over the saved one.

shortcut.nvim never shows the token in messages; at most it shows the last four characters.
The token is passed to `curl` on its standard input, never on its command line, where other
users could see it with `ps`.

### Health check

`:checkhealth shortcut` reports the Neovim and `curl` versions, where the token comes from (with
only its last four characters shown), whether it works (by asking the API who you are), what the
lookup-list cache holds (see below), and whether snacks.nvim is installed.

### Lookup-list cache

Stories and epics refer to workflow states, members, labels, teams and iterations by ID. To show
names (and turn names back into IDs when you edit), shortcut.nvim fetches these lists once and
caches them, in memory and in `stdpath('cache')/shortcut/<workspace>/refs.json` (e.g.
`~/.cache/nvim/shortcut/<workspace>/refs.json`). Each workspace has its own file, so switching
tokens never mixes them up. After `cache.ttl` seconds (a day by default) a list is refetched in
the background while the old copy keeps being used, so working offline never makes you wait; a
failed refetch is retried after a minute. The file is readable only by you (it contains member names, but
not the token or email addresses). `:checkhealth shortcut` shows how old each list is.

To fetch everything again now (e.g. after adding a label), clear the cache:

```lua
require('shortcut.cache').clear()
```

## Commands

| Command | Description |
|---|---|
| `:Shortcut story {id \| sc-<id> \| url}` | Open a story |
| `:Shortcut epic {id \| sc-<id> \| url}` | Open an epic |
| `:Shortcut diff` | Compare a story buffer with the story on Shortcut |
| `:Shortcut login` | Save an API token to the shared `short` config |
| `:Shortcut help` | List available subcommands |

## Opening stories and epics

Each story or epic is a single buffer named `shortcut://story/<id>` or `shortcut://epic/<id>`.
Other ways of naming it switch to that buffer:

- `:e https://app.shortcut.com/<workspace>/story/<id>/...` (or `/epic/<id>`): a link copied from
  the web app. Neovim's built-in download of `https://` files is skipped for these. A link to a
  workspace other than your token's opens with a warning.
- `:e sc-<id>`: looked up as a story, then as an epic (stories and epics share one ID space, so
  an ID is never both). Turn this off with `sc_ids = false`. Names that merely start with
  `sc-<digits>` (e.g. `sc-1notes.txt`), paths with a directory (e.g. `notes/sc-42`), and files
  that exist on disk open as normal files.
- `gf` on a Shortcut link or on `sc-<id>`. For `sc-<id>` this works through `'includeexpr'`,
  which the plugin sets globally when it is empty, and chains onto the `gitcommit` ftplugin's
  own. Other filetypes that set their own (e.g. `lua`, `python`) can opt in from
  `after/ftplugin/<filetype>.lua`; the original expression still handles every other name:

  ```lua
  require('shortcut').chain_includeexpr()
  ```

After the switch, `<C-^>` returns to the buffer you came from.

> [!NOTE]
> Epic buffers are not rendered yet: they only show the epic's ID.

## Story buffers

A story opens as a Markdown buffer (filetype `markdown`; both Neovim's Markdown syntax and its
treesitter highlighting show the header as YAML):

```markdown
---
id: 12345
type: feature
state: In Progress
owners: [someone, someone-else]
epic: 678 Some epic
iteration: Sprint 42
estimate: 3
labels: [backend, security]
url: https://app.shortcut.com/<workspace>/story/12345
---
# Story title

Description…

<!-- shortcut:tasks -->
## Tasks
- [x] Done task · @someone
- [ ] Open task
- [ ] Shared task · @someone @someone-else

<!-- shortcut:comments (read-only) -->
## Comments
**@someone** · 2026-10-01 14:03
> Comment body…
>
> **@someone-else** · 2026-10-01 15:20
> > A reply…
```

- **Header**, in this order: `id`; `type` (`feature`, `bug` or `chore`); `state` (the workflow
  state's name); `owners` (mention names); `epic` (`<id> <name>`); `iteration` (its name);
  `estimate`; `labels` (names); `url` (the story's link in the web app). `epic`, `iteration`
  and `estimate` are empty when the story has none. Mentions are written **without** `@`
  (a plain YAML value cannot start with one), but a leading `@` is accepted when reading.
  Values YAML would misread (e.g. a label named `true`, or containing `: `) are double-quoted.
- Names come from the [lookup-list cache](#lookup-list-cache). An ID that can't be resolved
  (e.g. a member who left the workspace, or a list that couldn't be fetched) is shown as
  `unknown-<id>`. The epic's name is fetched with the story; if that fails the line reads
  `<id> (name unavailable)`.
- **Title and description:** `# <title>`, then the description as written in Shortcut.
- **Tasks**, in Shortcut's order. The section is always there, even when empty. A task's owners
  follow its description: the **last** ` · ` followed only by `@mention`s holds the owners, and
  everything before it is the description. (So a task description that itself ends in
  ` · @name` is misread as having an owner.) Set `tasks.show_owners = false` to hide owners.
- **Comments** are read-only: oldest first, each with its author and local time, the body
  quoted; replies are nested one quote level deeper under the comment they answer. Deleted
  comments are left out (a deleted comment with replies shows as `*(deleted comment)*`).
- The `<!-- shortcut:… -->` lines mark where the sections start, so a description containing
  its own `## Tasks` heading is not confused with the tasks. Leave them in place. If a
  description itself contains such a line, the **last** comments marker and the last tasks
  marker before it are the real ones.
- Modelines are disabled in these buffers, so text from the server can never set options.
- A link to a comment (`…/story/<id>/<slug>#activity-<comment id>`) puts the cursor on it.
- `:e!` fetches the story again, discarding your edits.

### Editing stories

Edit the buffer and `:w` to save the changes to Shortcut. Only what you changed is sent: one
`PUT /stories/<id>` with the changed fields, then one call per added, changed or deleted task.
The story is then reloaded (the cursor stays on the same line) and the buffer is unmodified.

| In the buffer | Saved as |
|---|---|
| `# <title>` | the story's name (required) |
| the description (between the title and the tasks marker) | the description, as written, without trailing blank lines |
| `type` | `feature`, `bug` or `chore` |
| `state` | a state of the story's **own** workflow, by name (case is ignored) |
| `owners` | mention names (case is ignored, the `@` is optional); disabled members can't be added |
| `epic` | the epic ID at the start of the value (the name after it is ignored); empty removes the epic |
| `iteration` | an iteration name or ID; empty removes the iteration |
| `estimate` | a non-negative integer; empty removes the estimate |
| `labels` | names of **existing** labels (case is ignored); an unknown name is an error, never a new label |
| task lines | see below |

- `id` and `url` are read-only: changing them is an error. Comments are read-only; edits below
  the comments marker are ignored (and undone by the reload).
- Every value is checked before anything is sent. Problems (an unknown state, member, label or
  iteration, an epic that doesn't exist, a malformed line…) are shown as diagnostics on their
  lines, with one summary message, and **nothing** is sent until they are fixed. Names are
  checked against the [lookup-list cache](#lookup-list-cache); if something was added recently,
  clear the cache. An `unknown-<id>` left as it is never counts as a change.
- An unchanged buffer sends nothing (`:w` says "no changes"). So does a value written
  differently but meaning the same (other case, extra spaces, owners in another order).
- **Tasks:** `- [ ] description` lines in the tasks section. Toggle `[ ]`/`[x]`, edit the text,
  add lines (new tasks are added at the end of the list), or delete lines. Owners are the
  trailing ` · @mention @mention` part: add, change or remove it (removing it removes the
  owners). Unknown or disabled members are errors on that line. With
  `tasks.show_owners = false`, owners are not shown and never changed: a ` · @name` you type is
  part of the description. Reordering tasks is not saved. Blank lines are fine there; any other
  line is an error.
- Tasks are matched to lines by invisible marks, so editing a line in place (`cc`, `:s`,
  `:move`, inserting text) keeps it the same task. A line that is deleted and put back
  (`dd` then `p`) counts as a deleted task plus a new one, and so does a copy (`yyp`) as a new
  one.
- **Deleting tasks** asks first (unless `tasks.confirm_delete = false`), listing them:
  **Delete** saves everything; **Keep tasks** saves everything else and the tasks come back
  with the reload; **Cancel save** (also `<Esc>`) sends nothing and keeps your edits.
- **Conflicts:** if someone else changed the story since it was loaded, the save is refused and
  nothing is sent. `:Shortcut diff` opens the version on Shortcut side by side with your buffer
  (close it to leave diff mode); then `:w!` saves your changes over theirs (only the fields you
  changed are sent), or `:e!` reloads theirs, discarding yours. `:w!` does not skip the delete
  question.
- If the story is saved but some task calls fail, the failures are listed and the buffer keeps
  your edits; `:w` again sends only what failed. While a save runs the buffer is read-only.

## Development

With Nix:

```sh
nix run .#dev        # Neovim with the plugin loaded from this checkout (isolated config)
nix develop          # neovim, stylua, lua-language-server, make, ...
make test
```

`nix run .#dev` reads the plugin straight from the working tree, so changes take effect on
restart without rebuilding. (Plain `nix run .` uses the packaged plugin and, like every flake
build, only sees files tracked by git.)

Without Nix:

```sh
make test            # clones mini.nvim into deps/ on first run
make test-file FILE=tests/test_config.lua
make fmt             # requires stylua
```

## License

[MIT](LICENSE)

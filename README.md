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
- `:e!` fetches the story again. Editing (`:w`) is not available yet: it reports so and keeps
  your changes in the buffer.

## Epic buffers

An epic opens as a read-only Markdown buffer listing its stories, grouped by workflow state:

```markdown
---
id: 678
state: In Progress
owners: [someone]
teams: [Platform]
labels: [q4]
planned_start: 2026-10-01
deadline: 2026-12-15
stories: 14 (6 done, 5 started, 3 unstarted)
url: https://app.shortcut.com/<workspace>/epic/678
---
# Epic name

Description…

<!-- shortcut:stories -->
## Stories

### In Progress
- sc-12345 Story title · someone · 3pt
- sc-12346 Another story · unowned

### Done
- sc-12347 Finished story · someone, someone-else · 1pt
```

- **Header**, in this order: `id`; `state` (the epic state's name, from the epic workflow);
  `owners` (mention names); `teams` (team names); `labels`; `planned_start` and `deadline`
  (dates, empty when not set); `stories`, a summary of the story list: how many stories,
  and how many are done, started and unstarted. When there are any, it also counts stories in
  backlog states (`N backlog`), in states of any other type (`N <type>`), and in states that
  can't be looked up (`N unknown`). An empty epic shows just `0`. `url` is the epic's link
  in the web app. Names and `unknown-<id>` work as in story buffers.
- **Stories** are grouped under `### <state name>`. An epic's stories may come from several
  workflows: groups are ordered by state type (backlog, unstarted, started, then done), then
  by the state's position in its workflow, and states with the same name share one group.
  States of other types come after those, and stories in a state that can't be looked up
  come last, under `### unknown-<id>`. Within a
  group, stories are in Shortcut's order. Each line reads
  `- sc-<id> <title> · <owners, or "unowned"> · <estimate>pt` (no estimate part when the
  story has none). Archived stories are left out. An epic without stories shows
  `*No stories.*`.
- **`<CR>`** on a line containing `sc-<id>` opens it in the current window (the `sc-<id>`
  under the cursor, else the first on the line): on a story line, that story. On any other
  line `<CR>` does what it did before: the `<CR>` mapping it replaced (buffer-local, e.g.
  from a Markdown plugin, or global), else Neovim's own `<CR>`. **`gf`** on `sc-<id>` works
  too, as everywhere.
- Modelines are disabled, as in story buffers.
- `:e!` fetches the epic and its stories again. Editing (`:w`) is not available: it reports
  so and keeps your changes in the buffer.

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

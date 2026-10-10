+++
title = "Configuration"
weight = 3
description = "Every option, its default, and what it changes."
+++

Options are passed to `setup()`, or to `opts` with lazy.nvim, which calls it for you. Calling `setup()` is
optional: without it the defaults apply.

`setup()` may be called again; each call starts from the defaults. Invalid options are reported and leave
the previous configuration in place; unknown options only produce a warning (they are most likely typos).

## Defaults

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
  create = {              -- defaults of `:Shortcut create`, see "Creating stories"
    workflow = nil,       -- workflow name or ID; default: the team's, else the workspace's default
    team = nil,           -- team (name, mention name or ID) assigned to new stories
    template = nil,       -- fun(fields): fields? to customize the template
  },
})
```

## Options

| Option | Default | Description |
|---|---|---|
| `token` | `nil` | API token (`string`), or a function returning one. Takes precedence over the environment and the `short` config. See [Authentication](@/authentication.md) |
| `cli_config_path` | `nil` | The `short` config file to read the token (and mention name and workspace) from, and that `:Shortcut login` writes. By default, the one `short` itself uses |
| `cache.ttl` | `86400` | Seconds (a day) before a [lookup list](#the-lookup-list-cache) is fetched again, in the background |
| `sc_ids` | `true` | Whether `:e sc-<id>` and `gf` on `sc-<id>` open the story or epic. [Links](@/buffers.md#opening-stories-and-epics) and `:Shortcut story` work either way |
| `picker.page_size` | `25` | Results per search request, 1 to 250 |
| `picker.max_results` | `200` | Most results a picker loads (the API stops at 1000) |
| `http.timeout` | `30` | Seconds a request may take |
| `tasks.show_owners` | `true` | Show task owners as a trailing ` · @mention`. When `false`, owners are neither shown nor changed, and ` · @name` typed on a task line is part of its description |
| `tasks.confirm_delete` | `true` | Ask before a save [deletes tasks](@/editing.md#deleting-tasks) |
| `create.workflow` | `nil` | Workflow (name or ID) of new stories. By default, `create.team`'s default workflow, else the workspace's |
| `create.team` | `nil` | Team (name, mention name or ID) new stories are assigned to |
| `create.template` | `nil` | `fun(fields): fields?` customizing the [`:Shortcut create` template](@/editing.md#the-template) |

### Customizing new stories

`create.template` is called with the fields of a new draft (`title`, `description`, `type`, `state`,
`owners`, `epic`, `iteration`, `estimate`, `labels`, `tasks`) and may change them, or return a new table.
`tasks` is a list of descriptions or of `{ description, complete?, owners? }` tables:

```lua
require('shortcut').setup({
  create = {
    team = 'platform',
    template = function(fields)
      fields.description = '## Why\n\n## Acceptance criteria\n'
      fields.tasks = { 'Write tests' }
    end,
  },
})
```

## The lookup-list cache

Stories and epics refer to workflow states, members, labels, teams and iterations by ID. To show names (and
turn names back into IDs when you edit), shortcut.nvim fetches these lists once and caches them, in memory
and in `stdpath('cache')/shortcut/<workspace>/refs.json` (e.g.
`~/.cache/nvim/shortcut/<workspace>/refs.json`). Each workspace has its own file, so switching tokens never
mixes them up. The file is readable only by you (it contains member names, but not the token or email
addresses).

After `cache.ttl` seconds a list is fetched again in the background while the old copy keeps being used, so
working offline never makes you wait; a failed fetch is retried after a minute. `:checkhealth shortcut`
shows how old each list is.

To fetch everything again now (e.g. after adding a label in Shortcut), run `:Shortcut refresh`.

## Lua API

Besides `setup()`, two functions make `gf` work on `sc-<id>`:

| Function | |
|---|---|
| `require('shortcut').chain_includeexpr(buf)` | Make `gf` on `sc-<id>` work in buffer `buf` (default: the current one) whose filetype sets its own `'includeexpr'`. The original expression still handles every other name. Done automatically for `gitcommit` buffers |
| `require('shortcut').includeexpr(fname, fallback)` | An `'includeexpr'` function: maps `sc-<id>` to a name `gf` can open, and passes other names to `fallback` (a Vimscript expression or a Lua function), or returns them unchanged |

See [`gf` on `sc-<id>`](@/buffers.md#opening-stories-and-epics) for when you need them.

# shortcut.nvim

Browse, search, and edit [Shortcut](https://www.shortcut.com/) stories and epics without leaving
Neovim. Stories and epics open as Markdown buffers — `:e` a story URL or `sc-12345`, edit it, and
`:w` saves it back to Shortcut. Authentication is shared with the
[`short` CLI](https://github.com/shortcut-cli/shortcut-cli), so if you already use it there is
nothing to set up.

<!-- TODO: a short GIF of the search picker -> story buffer -> :w flow. -->

- Search stories and epics with live results and previews ([snacks.nvim](https://github.com/folke/snacks.nvim)),
  or with `vim.ui.select` without it.
- Open stories and epics as Markdown buffers by ID, `sc-<id>`, a web app link or `gf`.
- Edit the title, description, state, owners, epic, iteration, estimate, labels and tasks, and
  save with `:w`; conflicting changes are never overwritten silently.
- Create stories from a template, comment, move a story to another state, open or copy its link.

**[Documentation](https://calebstew.art/shortcut.nvim/)**: installation, every option and command, and
how story buffers are saved. The same documentation is in Neovim, as `:help shortcut`.

## Requirements

- Neovim >= 0.12
- `curl`
- Optional: `git`, to find the story of the current branch
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

Don't lazy-load it on the `:Shortcut` command alone: the plugin also opens Shortcut links,
`sc-<id>` names and `shortcut://` buffers given to `:edit` or on the command line, which only
works if it is loaded at startup. Loading it costs well under a millisecond (the plugin file
only registers the command and a few autocommands; everything else is loaded on first use).

### Neovim packages

Without a plugin manager, clone it into a `pack/*/start` directory (or `pack/*/opt`, then
`:packadd shortcut.nvim`):

```sh
git clone https://github.com/calebstewart/shortcut.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/shortcut.nvim
```

### Nix

The flake provides the plugin as a package (`packages.<system>.default`) and, through
`overlays.default`, as `pkgs.vimPlugins.shortcut-nvim`:

```nix
# flake.nix
{
  inputs.shortcut-nvim.url = "github:calebstewart/shortcut.nvim";
  # ...
}

# In your NixOS or home-manager configuration:
{ inputs, pkgs, ... }:
{
  nixpkgs.overlays = [ inputs.shortcut-nvim.overlays.default ];

  # home-manager
  programs.neovim.plugins = [ pkgs.vimPlugins.shortcut-nvim ];
}
```

The package declares `curl` and `git` as runtime dependencies, which Neovim wrappers put on
`PATH`. Try it without installing anything (in an isolated configuration with snacks.nvim, not
yours):

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
  create = {              -- defaults of `:Shortcut create`, see "Creating stories"
    workflow = nil,       -- workflow name or ID; default: the team's, else the workspace's default
    team = nil,           -- team (name, mention name or ID) assigned to new stories
    template = nil,       -- fun(fields): fields? to customize the template
  },
})
```

| Option | Default | Description |
|---|---|---|
| `token` | `nil` | API token, or a function returning one (see [Authentication](#authentication)). Takes precedence over the environment and the `short` config |
| `cli_config_path` | `nil` | The `short` config file to read the token from and that `:Shortcut login` writes; by default the one `short` uses |
| `cache.ttl` | `86400` | Seconds before a [lookup list](#lookup-list-cache) is fetched again (in the background) |
| `sc_ids` | `true` | Whether `:e sc-<id>` and `gf` on `sc-<id>` open the story or epic (links work either way) |
| `picker.page_size` | `25` | Results per search request (1 to 250) |
| `picker.max_results` | `200` | Most results a picker loads (the API stops at 1000) |
| `http.timeout` | `30` | Seconds a request may take |
| `tasks.show_owners` | `true` | Show task owners as a trailing ` · @mention`; when `false`, owners are neither shown nor changed |
| `tasks.confirm_delete` | `true` | Ask before a save deletes tasks |
| `create.workflow` | `nil` | Workflow (name or ID) of new stories; default: `create.team`'s default workflow, else the workspace's |
| `create.team` | `nil` | Team (name, mention name or ID) new stories are assigned to |
| `create.template` | `nil` | `fun(fields): fields?` customizing the `:Shortcut create` template |

`setup()` may be called again; each call starts from the defaults. Invalid options are reported
and leave the previous configuration in place; unknown options only produce a warning.

## Authentication

shortcut.nvim needs a Shortcut API token (create one under
[Settings → API Tokens](https://app.shortcut.com/settings/account/api-tokens)). It looks in these
places, in order, and uses the first token it finds:

1. **`token` in `setup()`**: a string, or a function returning one. A function is called once
   per Neovim session, so it can fetch the token from a password manager:

   ```lua
   --- The first line a command prints, or an error if it fails (rather than its error message
   --- being used as the token).
   local function command_token(cmd)
     local res = vim.system(cmd, { text = true }):wait()
     if res.code ~= 0 then
       error(('%s failed: %s'):format(cmd[1], vim.trim(res.stderr or '')))
     end
     return vim.trim(vim.split(res.stdout or '', '\n')[1])
   end

   require('shortcut').setup({
     token = function()
       return command_token({ 'pass', 'show', 'shortcut/api-token' })
     end,
   })
   ```

   For other password managers, change the command:

   ```lua
   -- macOS Keychain
   { 'security', 'find-generic-password', '-s', 'shortcut-api-token', '-w' }
   -- 1Password CLI
   { 'op', 'read', 'op://Private/Shortcut/token' }
   ```

   If the function raises an error or returns anything but a non-empty string, commands say so
   (without a stack trace) and send nothing.

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
lookup-list cache holds (see below), whether `:e sc-<id>` is handled, whether Neovim's built-in
`https://` handler skips Shortcut links, whether `gf` works on `sc-<id>`, and whether
snacks.nvim and `git` are installed.

### Lookup-list cache

Stories and epics refer to workflow states, members, labels, teams and iterations by ID. To show
names (and turn names back into IDs when you edit), shortcut.nvim fetches these lists once and
caches them, in memory and in `stdpath('cache')/shortcut/<workspace>/refs.json` (e.g.
`~/.cache/nvim/shortcut/<workspace>/refs.json`). Each workspace has its own file, so switching
tokens never mixes them up. After `cache.ttl` seconds (a day by default) a list is refetched in
the background while the old copy keeps being used, so working offline never makes you wait; a
failed refetch is retried after a minute. The file is readable only by you (it contains member names, but
not the token or email addresses). `:checkhealth shortcut` shows how old each list is.

To fetch everything again now (e.g. after adding a label), run `:Shortcut refresh`.

## Commands

| Command | Description |
|---|---|
| `:Shortcut story [id \| sc-<id> \| url]` | Open a story; without an argument, the git branch's story |
| `:Shortcut epic {id \| sc-<id> \| url}` | Open an epic |
| `:Shortcut search [query…]` | Search stories (live with snacks.nvim); see [Searching](#searching) |
| `:Shortcut mine` | Your unfinished stories |
| `:Shortcut epics [query…]` | Search epics (live with snacks.nvim) |
| `:Shortcut create [key=value...]` | Open a draft of a new story; `:w` creates it (see [Creating stories](#creating-stories)) |
| `:Shortcut comment [target]` | Write a comment on the story in a floating window; `:w` posts it |
| `:Shortcut state [target] [state]` | Move the story to another workflow state |
| `:Shortcut browse [target]` | Open the story or epic in the browser |
| `:Shortcut yank [target]` | Copy the URL of the story or epic |
| `:Shortcut refresh` | Fetch the lookup lists again and reload the current Shortcut buffer |
| `:Shortcut diff` | Compare a story buffer with the story on Shortcut |
| `:Shortcut login` | Save an API token to the shared `short` config |
| `:Shortcut help` | List available subcommands |

### The current story

`comment`, `state`, `browse` and `yank` work on "the current story", which is the first of:

1. **the argument** (`[target]`), if given: an ID, `sc-<id>`, or a Shortcut link;
2. **the current buffer**, if it is a story or epic buffer (or a comment being written);
3. **the git branch** of the current file's repository (or, for buffers that are not files, of
   the working directory): the first `sc-<id>` in the branch name, as in Shortcut's
   `<user>/sc-<id>/<slug>` format. A detached HEAD or a directory outside git does not count.

Otherwise the command explains how to name a story. `:Shortcut story` with no argument uses the
git branch only. `comment` and `state` work on stories; `browse` and `yank` on epics too (a
bare ID is looked up to find out which it is).

- **`:Shortcut comment`** opens a floating Markdown buffer titled `Comment on sc-<id>: <title>`.
  `:w` posts it and closes the float (`:wq` works too); `:q!` discards it. Empty comments are not
  posted. If posting fails, the text stays in the buffer. Afterwards the story's buffer, if
  open, is reloaded to show the comment, unless it has unsaved changes.

  Only writing the float to its own name posts (`:w`, `:w!`, `:wq`, `:x`, `:update`). Writing
  it anywhere else (`:w file`, `:wq file`, `:saveas file`, `:1,2w file`, `:w >> file`) fails
  with an error, so `:wq file` doesn't close the float: nothing is posted and no file is
  written. `:wall`, `:wqa` and `:xa` run from another window don't post
  the draft either: it stays modified, so `:wqa` and `:xa` don't exit. Run in the float itself,
  they post it (like `:w`), and `:wqa`/`:xa` wait for the answer (up to 10 seconds): if posting
  fails or takes longer, Neovim doesn't exit and the text stays. If Neovim exits anyway with a
  comment still being posted (`:w` then `:qa`), it waits for the answer (up to 15 seconds); a
  comment that could not be posted, or whose answer didn't come (it may still have been posted),
  is saved under `stdpath('state')/shortcut/unsent/` and the path is printed.
- **`:Shortcut state`** lists the states of the story's workflow in order, the current one
  marked, with `vim.ui.select`. Give a state name to move the story directly; names are
  completed with `<Tab>` (the current story buffer's workflow, or every workflow's) and matched
  ignoring case, and may contain spaces (`:Shortcut state In Progress`). The target, if any,
  comes first, as `sc-<id>` or a link (`:Shortcut state sc-123 Done`). A bare ID is the target
  only on its own (`:Shortcut state 123`): followed by more words it is read as the start of the
  state name, so a state named `2 Review` never moves story 2. The story's buffer, if open, is
  reloaded; if it has unsaved changes, you are warned that its header is stale.
- **`:Shortcut browse`** opens the story's link with `vim.ui.open()`.
- **`:Shortcut yank`** copies the link to the unnamed register and the clipboard (`+`, and `*`
  when it is a separate selection, as on X11).
- **`:Shortcut refresh`** clears the [lookup-list cache](#lookup-list-cache) (in memory and on
  disk) and fetches the lists again in the background. If the current buffer is a story or epic
  without unsaved changes, it is reloaded too.

## Searching

- **`:Shortcut search [query…]`** searches stories. The arguments are joined into the starting
  query; with [snacks.nvim](https://github.com/folke/snacks.nvim), every change to the query
  searches again (the request in flight is cancelled). With no query, nothing is shown until
  you type one (Shortcut rejects empty searches).
- **`:Shortcut mine`** lists your unfinished stories: `owner:<your mention name> !is:done
  !is:archived`. Typing filters this list locally instead of searching again.
- **`:Shortcut epics [query…]`** searches epics. With no query it starts with
  `!is:done !is:archived` (not-done epics), which you can edit.

Queries use Shortcut's
[search operators](https://www.shortcut.com/help/fields-and-features/search-operators), as in
the web app, e.g. `owner:someone state:"In Progress" epic:123 type:bug`. Operators combine with
AND, and `!` or `-` in front of one negates it (`!is:done`). Results arrive a page at a time
(`picker.page_size` per request), up to `picker.max_results` (the API stops at 1000).

### With snacks.nvim

Each row shows `sc-<id>`, the workflow state (coloured by its type: backlog, unstarted, started,
done; states of other types are not coloured), the story type (`feat`, `bug`, `chore`), the
title, and the owners (dimmed). Epic rows show the ID, state and name.

The preview shows the story or epic as its buffer would, with modelines off. It is fetched once
the cursor has rested on a row for 300 ms, so moving through the list doesn't fetch every row,
and at most 40 previews are fetched per minute (past that the preview says it is waiting), well
within the API's limit of 200 requests per minute. Previews are cached for 5 minutes; any change
made from Neovim (saving a buffer, `:Shortcut state`, a comment…), `:Shortcut refresh`, or
loading the object's buffer drops them sooner.

The web link used by the copy and browse keys is the result's own link only if it is a Shortcut
web app link to that same story or epic; otherwise it is built from your workspace, as
`:Shortcut yank` does.

| Key | Action |
|---|---|
| `<CR>` | Open the story/epic (`shortcut://<kind>/<id>`) in the current window; with several selected (`<Tab>`), open each |
| `<C-s>` / `<C-v>` / `<C-t>` | Open in a split / vertical split / new tab (snacks' defaults) |
| `<C-y>` (input), `y` (list) | Copy the web link, like `:Shortcut yank` (unnamed register and clipboard) |
| `<A-b>` | Open the web link in the browser (`vim.ui.open()`) |

These follow snacks' own GitHub pickers, which use the same keys to copy and browse. Every other
snacks key works as usual (`<C-g>` toggles live search off to filter the results locally).

The pickers are snacks sources named `shortcut_search`, `shortcut_mine` and `shortcut_epics`;
settings under `picker.sources.<name>` in your snacks configuration apply on top of the
plugin's, e.g. to change keys or the layout:

```lua
require('snacks').setup({
  picker = {
    sources = {
      shortcut_search = { layout = 'vertical', win = { list = { keys = { ['<c-o>'] = 'shortcut_browse' } } } },
    },
  },
})
```

The actions are `shortcut_copy_url` and `shortcut_browse`.

#### Highlights

The picker rows use these groups. Each is a default link (`:highlight default link`), so your
colour scheme or config can change it:

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

### Without snacks.nvim

The commands still work, without live search or previews (an info message says so once per
session): `vim.ui.input` asks for the query if none was given (not for `mine`; for `epics` it
suggests the default), the first results (up to `picker.max_results`) are fetched, and
`vim.ui.select` lists them as `sc-<id> [state] title`. Choosing one opens its buffer.

## Opening stories and epics

Each story or epic is a single buffer named `shortcut://story/<id>` or `shortcut://epic/<id>`.
Other ways of naming it switch to that buffer:

- `:e https://app.shortcut.com/<workspace>/story/<id>/...` (or `/epic/<id>`): a link copied from
  the web app. Neovim's built-in download of `https://` files is skipped for these. A link to a
  workspace other than your token's opens with a warning.
- `:e sc-<id>`: looked up as a story, then as an epic (stories and epics share one ID space, so
  an ID is never both). Turn this off (and `gf` on `sc-<id>`) with `sc_ids = false`. Names that merely start with
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

**@someone-else** · 2026-10-02 09:12
> Attachment: [screenshot.png](https://…) · image/png · 1.2 MB
>
> File description…
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
  everything before it is the description. A description that itself ends in ` · @name` is
  shown with a backslash before that dot (`Email team \· @name`), so it is never read as
  owners; a backslash right before a `·` in a description is shown doubled. Set
  `tasks.show_owners = false` to hide owners.
- **Comments** are read-only: oldest first, each with its author and local time, the body
  quoted; replies are nested one quote level deeper under the comment they answer. Deleted
  comments are left out (a deleted comment with replies shows as `*(deleted comment)*`).
- **Files** uploaded to the story are shown among the comments, by upload time (as in the web
  app, where a file uploaded on its own looks like a comment; the API only lists it in the
  story's `files`). Each shows who uploaded it and when, then `Attachment:` with the file's
  name, its content type and size, and its description (if any) quoted below. The name links
  to the file only if its URL is `https://` with a host and no `user@` part, without spaces,
  control characters or characters that would break the link; otherwise it is plain text.
  Names, types and the author and date of comment and file headers are escaped, so they can't
  add links or images of their own. In those, and in file descriptions, control characters
  (except tabs), line separators and bidirectional-formatting characters are shown as `�`
  (comment text is shown as written). Files and thumbnails are never downloaded, in buffers or
  in picker previews: only the link is shown. Like comments, file entries are read-only.
- The `<!-- shortcut:… -->` lines mark where the sections start, so a description containing
  its own `## Tasks` heading is not confused with the tasks. Leave them in place. If a
  description itself contains such a line, the **last** comments marker and the last tasks
  marker before it are the real ones.
- Modelines are disabled in these buffers, so text from the server can never set options.
- A link ending in `#activity-<comment id>` puts the cursor on that comment. (This is assumed to be
  the web app's format for comment links; it has not been confirmed. Any other fragment is
  ignored.)
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

- `id` and `url` are read-only: changing them is an error. Comments are read-only: edits below
  the comments marker are never sent, and `:w` puts them back as they were (with the reload
  after a save, or, when nothing else changed, by restoring that section; `u` brings your
  text back).
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
  owners). Unknown or disabled members are errors on that line. To end a description with a
  literal ` · @name`, write the dot as `\·` (`\\·` for a backslash followed by a dot). With
  `tasks.show_owners = false`, owners are not shown and never changed: a ` · @name` you type is
  part of the description. Reordering tasks is not saved. Blank lines are fine there; any other
  line is an error.
- Tasks are matched to lines by invisible marks, so editing a line in place (`cc`, `:s`,
  `:move`, inserting text) keeps it the same task. A line that loses its mark because it was
  deleted and put back (`dd` then `p`) or replaced (as plugins that toggle checkboxes may do)
  is matched by its text: a replaced line to the task whose line it replaced, if the
  description is the same (the checkbox and owners may differ), and a moved line to the only
  task left that reads exactly the same (checkbox and owners included). Anything else, such as
  deleting a task and typing a similar line elsewhere, is a deleted task plus a new one, and the
  delete prompt asks. A copy (`yyp`) is a new task.
- **Deleting tasks** asks first (unless `tasks.confirm_delete = false`), listing them:
  **Delete** saves everything; **Keep tasks** saves everything else and the tasks come back
  with the reload; **Cancel save** (also `<Esc>`) sends nothing and keeps your edits.
- **Conflicts:** if someone else changed the story since it was loaded, the save is refused and
  nothing is sent. `:Shortcut diff` opens the version on Shortcut side by side with your buffer
  (close it to leave diff mode); then `:w!` saves your changes over theirs (only the fields you
  changed are sent), or `:e!` reloads theirs, discarding yours. `:w!` does not skip the delete
  question.
- If the story is saved but some task calls fail, the message lists what was saved and what
  failed, and the buffer keeps your edits; `:w` again sends only what failed. If someone else
  changed the story while it was being saved, that `:w` reports a conflict instead (so their
  change is never reverted silently); `:w!` then sends what failed, plus your values for
  anything they changed that you had edited too.
- If the changes are saved but reloading the story afterwards fails, the buffer stays modified
  and saving is refused until `:e!` reloads it (saving again could send the same changes twice).
- While a save runs the buffer is read-only.

### Creating stories

`:Shortcut create` opens a draft of a new story, `shortcut://story/new-<n>` (several drafts can
be open at once), in insert mode on the title line:

```markdown
---
type: feature
state: Backlog
owners: [you]
epic:
iteration:
estimate:
labels: []
---
# 

<!-- shortcut:tasks -->
## Tasks
```

Fill it in like a story buffer (without `id`, `url` or comments) and `:w`: the story is created
with every field and task, the window switches to its buffer (`shortcut://story/<id>`), and the
draft is closed. Everything is checked exactly as when [editing](#editing-stories): problems are
diagnostics, and nothing is sent until they are fixed. Labels must already exist, and task
owners are the trailing ` · @mention` part.

The template's defaults:

- `owners`: you (the API token's member).
- `state`: the first `unstarted` state of the workflow. The workflow is `create.workflow` (name
  or ID); otherwise the default workflow of `create.team`, if that team has one; otherwise the
  workspace's default workflow (from `GET /member`). `state` must be a state of that workflow;
  use `workflow=<name>` to start a draft in another one.
- `create.team` (name, mention name or ID) is assigned to the story (its team, `group_id`).
- `create.template`, if set, is called with the fields (`title`, `description`, `type`,
  `state`, `owners`, `epic`, `iteration`, `estimate`, `labels`, `tasks`) and may change them
  or return new ones. `tasks` is a list of descriptions or of
  `{ description, complete?, owners? }`:

  ```lua
  create = {
    team = 'platform',
    template = function(fields)
      fields.description = '## Why\n\n## Acceptance criteria\n'
      fields.tasks = { 'Write tests' }
    end,
  }
  ```

- Arguments come last: `:Shortcut create type=bug epic=678 state=In\ Progress
  owners=jdoe,alex labels=backend iteration=Sprint\ 7 estimate=2 workflow=Engineering
  team=platform`. Lists are comma-separated, an empty value (`epic=`) clears the field, and
  spaces are escaped with `\`. `<Tab>` completes the keys and, once the lookup lists are
  loaded, their values (types, states, owners, labels, iterations, workflows, teams).

Writing a draft:

- Only writing the draft to its own name, in its own window, creates the story (`:w`, `:w!`,
  `:wq`, `:x`, `:update`). Writing it anywhere else (`:w file`, `:saveas file`,
  `:w shortcut://story/<id>`, `:1,2w file`) fails with an error and sends nothing. So do
  `:wall`, `:wqa` and `:xa` run from another window: the draft stays modified, so `:wqa` and
  `:xa` don't exit.
- The write waits for Shortcut's answer. `<C-c>` stops waiting: before the story is sent (while
  the lookup lists load or the epic is checked) nothing is sent; once it is sent, it is still
  created and its buffer opens when it is. If it fails, the draft stays open and modified with
  the error, so `:wq` and `:x` don't close it. While the story is being created the draft is
  read-only, writing it again sends nothing, and `:e!` keeps what is being sent.
- Only a request refused before it was sent, or answered with a 4xx error, certainly created
  nothing. Any other failure (no answer, a timeout, a server error, a success answer without the
  story) may have created it: you are told to check Shortcut, and from then on `:w` refuses to
  send the draft again. Each resend needs its own `:w!`, until a story is created from it.
- Otherwise a draft is an ordinary modified buffer: Neovim's usual rules keep you from losing
  it by accident (`E37`/`E162`), `:q!` and `:bwipeout!` discard it, and `:e!` puts the
  template back.
- After creating a story, `:Shortcut yank` copies its link.

## Epic buffers

An epic opens as a Markdown buffer listing its stories, grouped by workflow state. Epics can't
be saved from Neovim (see the end of this section):

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
- Epics have no file attachments to show: the API's `Epic` has no `files` (only stories do).
- `:e!` fetches the epic and its stories again. Saving is not available: the buffer can be
  edited (e.g. to jot notes or copy lines), but `:w` says it can't be saved, sends nothing, and
  keeps your changes in the buffer; `:e!` discards them.

## Troubleshooting

- **Start with `:checkhealth shortcut`** (see [Health check](#health-check)). Every error is a
  notification prefixed with `shortcut.nvim:`; none should come with a Lua stack trace. If one
  does, please report it.
- **Rate limits.** Shortcut allows about 200 API requests per minute. A request answered with
  HTTP 429 is retried up to three times, waiting as long as the answer asks (at most a minute)
  or 1, 2 and 4 seconds; after that the command fails with "rate limited": wait a minute and
  try again. Picker previews are limited to 40 a minute and the lookup lists are cached, so
  normal use stays well below the limit.
- **Links to another workspace.** Your token belongs to one workspace. A link to another
  workspace opens with a warning, and the story is usually "not found", since your token can't
  read it. Use a token for that workspace.
- **`sc-<id>` gets in the way** (e.g. files named `sc-123` that you open without a path; those
  that exist on disk open as files anyway): set `sc_ids = false`. That also turns off `gf` on
  `sc-<id>`; `:Shortcut story sc-123` and links still work.
- **Neovim's built-in `https://` handler.** Neovim 0.12 downloads `http(s)://` names given to
  `:edit` in the background (the `nvim.net.remotefile` autocommands), which would replace a
  story with the web app's login page. shortcut.nvim wraps those handlers at startup so they skip
  Shortcut story and epic links, and leaves every other link to them; if you turned that plugin
  off (`g:loaded_nvim_net_plugin`), there is nothing to wrap. `:checkhealth shortcut` shows the
  state.
- **A name, label or member is missing** after it was added in Shortcut: run
  `:Shortcut refresh` to fetch the lookup lists again.

## Development

With Nix:

```sh
nix run .#dev        # Neovim with the plugin loaded from this checkout (isolated config)
nix develop          # neovim, stylua, lua-language-server, make, zola, ...
make test
nix flake check      # the plugin package, the tests, the formatting and the docs site, in the sandbox
```

`nix run .#dev` reads the plugin straight from the working tree (isolated with
`NVIM_APPNAME=shortcut-nvim-dev`), so changes take effect on restart without rebuilding. Plain
`nix run .` uses the packaged plugin and, like every flake build (and `nix flake check`), only
sees files tracked by git: `git add` new files first.

Without Nix:

```sh
make deps            # fetch mini.nvim and snacks.nvim (pinned) into deps/; `make test` does it too
make test            # every test file, in parallel
make test-file FILE=tests/test_config.lua
make fmt             # requires stylua (fmt-check to check only)
make typecheck       # requires lua-language-server
```

`make test` runs each test file in its own headless Neovim, one per CPU at a time (`JOBS=1` runs
them one after another), prints a line per file, then the full report of any file that failed
or skipped tests (`VERBOSE=1`: of every file). If snacks.nvim can't be fetched (e.g. offline),
the picker tests are skipped, unless `REQUIRE_SNACKS=1` (as in CI). Tests never touch the
network or your real `short` config and cache: they run against recorded API responses with a
temporary `$HOME`.

The help file, `doc/shortcut.txt`, is written by hand; `tests/test_doc.lua` checks that
`:helptags` accepts it, that its links resolve, and that every command, option and highlight
group has a tag.

The [documentation site](https://calebstew.art/shortcut.nvim/) is a [Zola](https://www.getzola.org/)
site in `docs/`, written by hand from this README and the help file, which stay the source of
truth: a change in behaviour updates all three. `tests/test_doc.lua` also checks that the site
lists every subcommand, option and highlight group. To preview it with live reload, in
`nix develop`:

```sh
zola --root docs serve       # http://127.0.0.1:1111
nix build .#docs             # the site exactly as it is deployed, in ./result
```

Internal links must be `@/page.md` links (the site is served from a sub-path); a dead one fails
the build, and so `nix flake check`. Pushes to `main` deploy it to GitHub Pages
(`.github/workflows/pages.yml`).

See [CHANGELOG.md](CHANGELOG.md) for the release history.

## License

[MIT](LICENSE)

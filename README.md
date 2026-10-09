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

To fetch everything again now (e.g. after adding a label), run `:Shortcut refresh`.

## Commands

| Command | Description |
|---|---|
| `:Shortcut story [id \| sc-<id> \| url]` | Open a story; without an argument, the git branch's story |
| `:Shortcut epic {id \| sc-<id> \| url}` | Open an epic |
| `:Shortcut search [query…]` | Search stories (live with snacks.nvim); see [Searching](#searching) |
| `:Shortcut mine` | Your unfinished stories |
| `:Shortcut epics [query…]` | Search epics (live with snacks.nvim) |
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

The highlight groups are `ShortcutId`, `ShortcutStateBacklog`, `ShortcutStateUnstarted`,
`ShortcutStateStarted`, `ShortcutStateDone`, `ShortcutStateOther`, `ShortcutTypeFeature`,
`ShortcutTypeBug`, `ShortcutTypeChore` and `ShortcutOwners`; each links to a standard group
unless you define it.

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
  to the file only if its URL is `https://` without spaces, control characters or characters
  that would break the link; otherwise it is plain text. Control and bidirectional-formatting
  characters in names, types and descriptions are shown as `�`. Files and thumbnails are never
  downloaded, in buffers or in picker previews: only the link is shown. Like comments, file
  entries are read-only.
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
- Epics have no file attachments to show: the API's `Epic` has no `files` (only stories do).
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
make test            # fetches mini.nvim and snacks.nvim (pinned; picker tests skip offline) into deps/
make test-file FILE=tests/test_config.lua
make fmt             # requires stylua
```

## License

[MIT](LICENSE)

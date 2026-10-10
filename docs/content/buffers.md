+++
title = "Story and epic buffers"
weight = 5
description = "What a story or epic looks like as a buffer, and every way to open one."
+++

## Opening stories and epics

Each story or epic is a single buffer named `shortcut://story/<id>` or `shortcut://epic/<id>`. Other ways of
naming it switch to that buffer:

- **A link** copied from the web app:
  `:e https://app.shortcut.com/<workspace>/story/<id>/...` (or `/epic/<id>`). Neovim's
  [built-in download](@/troubleshooting.md#neovim-s-built-in-https-handler) of `https://` files is skipped for
  these. A link to a workspace other than your token's opens with a warning.
- **`:e sc-<id>`**: looked up as a story, then as an epic (stories and epics share one ID space, so an ID is
  never both). Names that merely start with `sc-<digits>` (e.g. `sc-1notes.txt`), paths with a directory
  (e.g. `notes/sc-42`), and files that exist on disk open as normal files. Turn this off (and `gf` on
  `sc-<id>`) with [`sc_ids = false`](@/configuration.md#options).
- **`gf`** on a Shortcut link or on `sc-<id>`, e.g. in a commit message.
- **`:Shortcut story`** and **`:Shortcut epic`** with an ID, `sc-<id>` or a link; `:Shortcut story` alone
  opens the [git branch's story](@/commands.md#the-current-story).
- A result in a [picker](@/searching.md).

After the switch, <kbd>Ctrl-^</kbd> returns to the buffer you came from.

A link ending in `#activity-<comment id>` puts the cursor on that comment. (This is assumed to be the web
app's format for comment links; it has not been confirmed. Any other fragment is ignored.)

### `gf` on `sc-<id>`

For `sc-<id>`, `gf` works through `'includeexpr'`, which the plugin sets globally when it is empty, and
chains onto the `gitcommit` ftplugin's own. Other filetypes that set their own (e.g. `lua`, `python`) can opt
in from `after/ftplugin/<filetype>.lua`; the original expression still handles every other name:

```lua
require('shortcut').chain_includeexpr()
```

## Story buffers

A story opens as a Markdown buffer (filetype `markdown`; both Neovim's Markdown syntax and its treesitter
highlighting show the header as YAML):

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

To change it, edit it and `:w`; see [Editing and creating](@/editing.md).

### The header

The header has, in this order:

| Field | |
|---|---|
| `id` | The story's ID (read-only) |
| `type` | `feature`, `bug` or `chore` |
| `state` | The workflow state's name |
| `owners` | Mention names |
| `epic` | `<id> <name>`; empty when the story has none |
| `iteration` | Its name; empty when the story has none |
| `estimate` | Empty when the story has none |
| `labels` | Label names |
| `url` | The story's link in the web app (read-only) |

- Mentions are written **without** `@` (a plain YAML value cannot start with one), but a leading `@` is
  accepted when reading. Values YAML would misread (e.g. a label named `true`, or containing `: `) are
  double-quoted.
- Names come from the [lookup-list cache](@/configuration.md#the-lookup-list-cache). An ID that can't be
  resolved (e.g. a member who left the workspace, or a list that couldn't be fetched) is shown as
  `unknown-<id>`. The epic's name is fetched with the story; if that fails the line reads
  `<id> (name unavailable)`.

### Title and description

`# <title>`, then the description as written in Shortcut.

### Tasks and their owners

Tasks are listed in Shortcut's order. The section is always there, even when empty.

A task's owners follow its description: the **last** ` · ` followed only by `@mention`s holds the owners, and
everything before it is the description. A description that itself ends in ` · @name` is shown with a
backslash before that dot (`Email team \· @name`), so it is never read as owners; a backslash right before a
`·` in a description is shown doubled. Set [`tasks.show_owners = false`](@/configuration.md#options) to hide
owners.

### Comments and attachments

**Comments** are read-only: oldest first, each with its author and local time, the body quoted; replies are
nested one quote level deeper under the comment they answer. Deleted comments are left out (a deleted
comment with replies shows as `*(deleted comment)*`).

**Files** uploaded to the story are shown among the comments, by upload time (as in the web app, where a file
uploaded on its own looks like a comment; the API only lists it in the story's `files`). Each shows who
uploaded it and when, then `Attachment:` with the file's name, its content type and size, and its
description (if any) quoted below. Like comments, file entries are read-only.

- The name links to the file only if its URL is `https://` with a host and no `user@` part, without spaces,
  control characters or characters that would break the link; otherwise it is plain text.
- Names, types and the author and date of comment and file headers are escaped, so they can't add links or
  images of their own. In those, and in file descriptions, control characters (except tabs), line
  separators and bidirectional-formatting characters are shown as `�` (comment text is shown as written).
- Files and thumbnails are never downloaded, in buffers or in picker previews: only the link is shown.

### Section markers

The `<!-- shortcut:… -->` lines mark where the sections start, so a description containing its own
`## Tasks` heading is not confused with the tasks. Leave them in place. If a description itself contains
such a line, the **last** comments marker and the last tasks marker before it are the real ones.

### Modelines

Modelines are disabled in these buffers, so text from the server can never set options.

## Epic buffers

An epic opens as a Markdown buffer listing its stories, grouped by workflow state:

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

- **Header**, in this order: `id`; `state` (the epic state's name, from the epic workflow); `owners`
  (mention names); `teams` (team names); `labels`; `planned_start` and `deadline` (dates, empty when not
  set); `stories`, a summary of the story list: how many stories, and how many are done, started and
  unstarted. When there are any, it also counts stories in backlog states (`N backlog`), in states of any
  other type (`N <type>`), and in states that can't be looked up (`N unknown`). An empty epic shows just
  `0`. `url` is the epic's link in the web app. Names and `unknown-<id>` work as in story buffers.
- **Stories** are grouped under `### <state name>`. An epic's stories may come from several workflows: groups
  are ordered by state type (backlog, unstarted, started, then done), then by the state's position in its
  workflow, and states with the same name share one group. States of other types come after those, and
  stories in a state that can't be looked up come last, under `### unknown-<id>`. Within a group, stories
  are in Shortcut's order. Each line reads `- sc-<id> <title> · <owners, or "unowned"> · <estimate>pt` (no
  estimate part when the story has none). Archived stories are left out. An epic without stories shows
  `*No stories.*`.
- **<kbd>Enter</kbd>** on a line containing `sc-<id>` opens it in the current window (the `sc-<id>` under the
  cursor, else the first on the line). On any other line <kbd>Enter</kbd> does what it did before: the
  `<CR>` mapping it replaced (buffer-local, e.g. from a Markdown plugin, or global), else Neovim's own.
  **`gf`** on `sc-<id>` works too, as everywhere.
- Modelines are disabled, as in story buffers.
- Epics have no file attachments to show: the API's `Epic` has no `files` (only stories do).

> [!NOTE]
> Epics can't be saved from Neovim. The buffer can be edited (e.g. to jot notes or copy lines), but `:w`
> says it can't be saved, sends nothing, and keeps your changes in the buffer. `:e!` fetches the epic and
> its stories again, discarding them.

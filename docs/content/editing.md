+++
title = "Editing and creating"
weight = 6
description = "Saving stories with :w, conflicts and partial failures, and creating stories from drafts."
+++

## Saving with :w

Edit a [story buffer](@/buffers.md#story-buffers) and `:w` to save the changes to Shortcut. Only what you
changed is sent: one `PUT /stories/<id>` with the changed fields, then one call per added, changed or deleted
task. The story is then reloaded (the cursor stays on the same line) and the buffer is unmodified.

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
| task lines | see [Tasks](#tasks) |

- `id` and `url` are read-only: changing them is an error.
- Comments are read-only: edits below the comments marker are never sent, and `:w` puts them back as they
  were (with the reload after a save, or, when nothing else changed, by restoring that section; `u` brings
  your text back).
- An unchanged buffer sends nothing (`:w` says "no changes"). So does a value written differently but
  meaning the same (other case, extra spaces, owners in another order).
- While a save runs the buffer is read-only.
- `:e!` fetches the story again, discarding your edits.

### Validation

Every value is checked before anything is sent. Problems (an unknown state, member, label or iteration, an
epic that doesn't exist, a malformed line…) are shown as diagnostics on their lines, with one summary
message, and **nothing** is sent until they are fixed.

Names are checked against the [lookup-list cache](@/configuration.md#the-lookup-list-cache); if something
was added recently, run `:Shortcut refresh`. An `unknown-<id>` left as it is never counts as a change.

## Tasks

Tasks are the `- [ ] description` lines in the tasks section.

- Toggle `[ ]`/`[x]`, edit the text, add lines (new tasks are added at the end of the list), or delete lines.
  Reordering tasks is not saved. Blank lines are fine there; any other line is an error.
- Owners are the trailing ` · @mention @mention` part: add, change or remove it (removing it removes the
  owners). Unknown or disabled members are errors on that line.
- To end a description with a literal ` · @name`, write the dot as `\·` (`\\·` for a backslash followed by a
  dot).
- With [`tasks.show_owners = false`](@/configuration.md#options), owners are not shown and never changed: a
  ` · @name` you type is part of the description.

Tasks are matched to lines by invisible marks, so editing a line in place (`cc`, `:s`, `:move`, inserting
text) keeps it the same task. A line that loses its mark because it was deleted and put back (`dd` then `p`)
or replaced (as plugins that toggle checkboxes may do) is matched by its text: a replaced line to the task
whose line it replaced, if the description is the same (the checkbox and owners may differ), and a moved line
to the only task left that reads exactly the same (checkbox and owners included). Anything else, such as
deleting a task and typing a similar line elsewhere, is a deleted task plus a new one, and the delete prompt
asks. A copy (`yyp`) is a new task.

### Deleting tasks

A save that deletes tasks asks first (unless [`tasks.confirm_delete = false`](@/configuration.md#options)),
listing them:

- **Delete** saves everything;
- **Keep tasks** saves everything else, and the tasks come back with the reload;
- **Cancel save** (also <kbd>Esc</kbd>) sends nothing and keeps your edits.

## Conflicts

If someone else changed the story since it was loaded, the save is refused and nothing is sent.

- `:Shortcut diff` opens the version on Shortcut side by side with your buffer, in diff mode. Close it to
  leave diff mode.
- `:w!` then saves your changes over theirs (only the fields you changed are sent).
- Or `:e!` reloads theirs, discarding yours.

`:w!` does not skip the [delete question](#deleting-tasks).

## Partial failures

- If the story is saved but some task calls fail, the message lists what was saved and what failed, and the
  buffer keeps your edits; `:w` again sends only what failed. If someone else changed the story while it
  was being saved, that `:w` reports a conflict instead (so their change is never reverted silently); `:w!`
  then sends what failed, plus your values for anything they changed that you had edited too.
- If the changes are saved but reloading the story afterwards fails, the buffer stays modified and saving is
  refused until `:e!` reloads it (saving again could send the same changes twice).

## Creating stories

`:Shortcut create` opens a draft of a new story, `shortcut://story/new-<n>` (several drafts can be open at
once), in insert mode on the title line:

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

Fill it in like a story buffer (without `id`, `url` or comments) and `:w`: the story is created with every
field and task, the window switches to its buffer (`shortcut://story/<id>`), and the draft is closed.
Everything is [checked](#validation) exactly as when editing: problems are diagnostics, and nothing is sent
until they are fixed. Labels must already exist, and task owners are the trailing ` · @mention` part.

After creating a story, `:Shortcut yank` copies its link.

### The template

The draft's defaults:

- `owners`: you (the API token's member).
- `state`: the first `unstarted` state of the workflow. The workflow is
  [`create.workflow`](@/configuration.md#options) (name or ID); otherwise the default workflow of
  `create.team`, if that team has one; otherwise the workspace's default workflow (from `GET /member`).
  `state` must be a state of that workflow; use `workflow=<name>` to start a draft in another one.
- `create.team` (name, mention name or ID) is assigned to the story (its team, `group_id`).
- `create.template`, if set, may change any field; see
  [Customizing new stories](@/configuration.md#customizing-new-stories).

Arguments come last, and override all of these:

```vim
:Shortcut create type=bug epic=678 state=In\ Progress owners=jdoe,alex labels=backend iteration=Sprint\ 7 estimate=2 workflow=Engineering team=platform
```

Lists are comma-separated, an empty value (`epic=`) clears the field, and spaces are escaped with `\`.
<kbd>Tab</kbd> completes the keys and, once the lookup lists are loaded, their values (types, states,
owners, labels, iterations, workflows, teams).

### Writing a draft

- Only writing the draft to its own name, in its own window, creates the story (`:w`, `:w!`, `:wq`, `:x`,
  `:update`). Writing it anywhere else (`:w file`, `:saveas file`, `:w shortcut://story/<id>`,
  `:1,2w file`) fails with an error and sends nothing. So do `:wall`, `:wqa` and `:xa` run from another
  window: the draft stays modified, so `:wqa` and `:xa` don't exit.
- The write waits for Shortcut's answer. <kbd>Ctrl-C</kbd> stops waiting: before the story is sent (while the
  lookup lists load or the epic is checked) nothing is sent; once it is sent, it is still created and its
  buffer opens when it is.
- If it fails, the draft stays open and modified with the error, so `:wq` and `:x` don't close it.
- While the story is being created the draft is read-only, writing it again sends nothing, and `:e!` keeps
  what is being sent.
- Otherwise a draft is an ordinary modified buffer: Neovim's usual rules keep you from losing it by accident
  (`E37`/`E162`), `:q!` and `:bwipeout!` discard it, and `:e!` puts the template back.

### Uncertain creates

Only a request refused before it was sent, or answered with a 4xx error, certainly created nothing. Any
other failure (no answer, a timeout, a server error, a success answer without the story) may have created
it: you are told to check Shortcut, and from then on `:w` refuses to send the draft again.

> [!WARNING]
> Each resend needs its own `:w!`, until a story is created from it. Check Shortcut first, or you may create
> the story twice.

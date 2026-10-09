--- Saving story buffers (`:w`), and `:Shortcut diff`.
---
--- A save:
---   1. parses the buffer and works out the changes (`shortcut.buffer.story_parse`,
---      `shortcut.buffer.story_diff`). Every problem becomes a diagnostic (namespace
---      `shortcut.edit`) on its line, plus one summary message, and nothing is sent;
---   2. checks that a new epic exists;
---   3. with no changes, says so and marks the buffer unmodified;
---   4. checks for a conflict: if the story's `updated_at` on the server is not the one loaded,
---      refuses (unless `:w!`), pointing to `:Shortcut diff`, `:w!` and `:e!`;
---   5. asks before deleting tasks (`tasks.confirm_delete`): Delete / Keep tasks / Cancel save;
---   6. sends one `PUT /stories/{id}` with the changed fields, then the task updates, creations
---      and deletions, in that order;
---   7. reloads the story, keeping the cursor on the same line where possible. If some task
---      calls failed, the buffer keeps the edits instead, and the snapshot is moved to what the
---      server now has, so the next `:w` sends only what failed.
---
--- The buffer is not modifiable while a save runs: what is reloaded would replace any edit
--- made meanwhile.
local async = require('shortcut.async')
local diff = require('shortcut.buffer.story_diff')
local notify = require('shortcut.notify')
local parse = require('shortcut.buffer.story_parse')
local story = require('shortcut.buffer.story')

local M = {}

--- Buffers being saved.
---@type table<integer, true>
local saving = {}

--- Whether a save of `buf` is running.
---@param buf? integer Defaults to the current buffer.
---@return boolean
function M.is_saving(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf --[[@as integer]]
  return saving[buf] == true
end

--- Name lookups from the cache.
---@return shortcut.story_diff.Lookup
function M.cache_lookup()
  local cache = require('shortcut.cache')
  return {
    state_by_name = cache.state_by_name,
    member_by_mention = cache.member_by_mention,
    label_by_name = cache.label_by_name,
    iteration_by_name = cache.iteration_by_name,
    iteration = cache.iteration,
  }
end

--- The current line of each valid task extmark of `buf`: 1-based line -> task ID.
---@param buf integer
---@return table<integer, integer>
local function mark_lines(buf)
  local out = {}
  for _, m in ipairs(story.task_marks(buf)) do
    out[m.row + 1] = m.id
  end
  return out
end

--- Work out what saving `buf` would send. Synchronous: uses the lookup lists already loaded.
---@param buf integer
---@param lookup? shortcut.story_diff.Lookup Defaults to the cache's.
---@return shortcut.story_diff.Changes? changes `nil` if the buffer could not be parsed.
---@return shortcut.story_parse.Error[] errors
---@return shortcut.story_parse.Story? parsed The buffer, parsed.
function M.changes(buf, lookup)
  local snap = story.snapshot(buf)
  if not snap then
    return nil, { { line = 1, message = 'the story is not loaded; :e! to reload' } }
  end
  local opts = { show_owners = snap.show_owners }
  -- Problems in the original render (e.g. a task without a description) are reported for the
  -- buffer, which has them too until they are fixed.
  local orig = parse.parse(snap.lines, opts)
  if not orig then
    error('the story as loaded cannot be read back; :e! to reload', 0)
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cur, errors = parse.parse(lines, opts)
  if not cur then
    return nil, errors
  end
  local orig_tasks = {}
  for _, t in ipairs(snap.meta.tasks) do
    orig_tasks[t.line] = t.id
  end
  local changes, diff_errors = diff.diff(orig, cur, {
    story = snap.story,
    lookup = lookup or M.cache_lookup(),
    orig_tasks = orig_tasks,
    marks = mark_lines(buf),
  })
  vim.list_extend(errors, diff_errors)
  table.sort(errors, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.message < b.message
  end)
  return changes, errors, cur
end

--- Show problems as diagnostics on their lines.
---@param buf integer
---@param errors shortcut.story_parse.Error[]
local function show_errors(buf, errors)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local items = {}
  for _, e in ipairs(errors) do
    table.insert(items, {
      lnum = math.max(0, math.min(e.line, count) - 1),
      col = 0,
      severity = vim.diagnostic.severity.ERROR,
      source = 'shortcut',
      message = e.message,
    })
  end
  vim.diagnostic.set(story.edit_ns(), buf, items)
end

--- The one-line summary of a list of problems.
---@param errors shortcut.story_parse.Error[]
---@return string
local function error_summary(errors)
  local first = errors[1]
  local more = #errors > 1 and (' (and %d more)'):format(#errors - 1) or ''
  return ('line %d: %s%s; nothing was sent'):format(first.line, first.message, more)
end

---------------------------------------------------------------------------------------------------
-- Cursor
---------------------------------------------------------------------------------------------------

---@class shortcut.story_save.Anchor
---@field kind 'line'|'body'|'task'|'tasks'|'comments'
---@field offset integer
---@field id? integer
---@field col integer

--- Where a line is, in terms that survive a reload.
---@param cur shortcut.story_parse.Story
---@param marks table<integer, integer> Line -> task ID.
---@param line integer
---@param col integer
---@return shortcut.story_save.Anchor
local function anchor(cur, marks, line, col)
  if line <= cur.header_end then
    return { kind = 'line', offset = line, col = col }
  elseif line < cur.tasks_marker then
    return { kind = 'body', offset = line - cur.title_line, col = col }
  elseif line < cur.comments_marker then
    if marks[line] then
      return { kind = 'task', id = marks[line], offset = 0, col = col }
    end
    return { kind = 'tasks', offset = line - cur.tasks_marker, col = col }
  end
  return { kind = 'comments', offset = line - cur.comments_marker, col = col }
end

---@param a shortcut.story_save.Anchor
---@param meta shortcut.story.Meta
---@param count integer
---@return integer line
local function resolve(a, meta, count)
  local line
  if a.kind == 'line' then
    line = a.offset
  elseif a.kind == 'body' then
    line = math.min(meta.title + a.offset, meta.tasks_marker - 1)
  elseif a.kind == 'task' then
    line = meta.tasks_marker
    for _, t in ipairs(meta.tasks) do
      if t.id == a.id then
        line = t.line
      end
    end
  elseif a.kind == 'tasks' then
    line = math.min(meta.tasks_marker + a.offset, meta.comments_marker - 1)
  else
    line = meta.comments_marker + a.offset
  end
  return math.max(1, math.min(line, count))
end

---------------------------------------------------------------------------------------------------
-- Saving
---------------------------------------------------------------------------------------------------

---@param n integer
---@param word string
---@return string
local function plural(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

--- Ask what to do about task deletions.
---@param id integer
---@param deletes shortcut.story_diff.TaskDelete[]
---@return 'delete'|'keep'|'cancel'
local function confirm_delete(id, deletes)
  local lines = { ('Delete %d task(s) from sc-%d?'):format(#deletes, id) }
  for _, d in ipairs(deletes) do
    table.insert(lines, '  - ' .. d.description)
  end
  local choice =
    vim.fn.confirm(table.concat(lines, '\n'), '&Delete\n&Keep tasks\n&Cancel save', 3, 'Question')
  if choice == 1 then
    return 'delete'
  elseif choice == 2 then
    return 'keep'
  end
  return 'cancel'
end

---@class shortcut.story_save.State
---@field buf integer
---@field id integer
---@field force boolean
---@field snap shortcut.story.Snapshot The snapshot the save started from.
---@field own table<shortcut.story.Snapshot, true> Snapshots made by this save.

--- Whether the buffer still shows what the save started from (not reloaded meanwhile).
---@param st shortcut.story_save.State
---@return boolean
local function current(st)
  return vim.api.nvim_buf_is_loaded(st.buf) and story.snapshot(st.buf) == st.snap
end

--- The save itself, in a coroutine. Returns what `done` gets.
---@async
---@param st shortcut.story_save.State
---@return string? err
---@return { keep_modified?: boolean }? opts
local function run(st)
  local http = require('shortcut.http')
  local stories = require('shortcut.api.stories')
  local buf, id = st.buf, st.id

  -- The lists were loaded with the story; make sure they still are (e.g. after a token switch).
  async.await(require('shortcut.cache').load, story.REF_KINDS)
  if not current(st) then
    return 'the story was reloaded meanwhile; nothing was sent'
  end

  local changes, errors, cur = M.changes(buf)
  if #errors > 0 or not changes or not cur then
    show_errors(buf, errors)
    return error_summary(errors)
  end

  if changes.epic then
    local eerr = async.await(require('shortcut.api.epics').get, changes.epic.id)
    if eerr then
      if eerr.status == 404 then
        local e =
          { line = changes.epic.line, message = ('epic: no epic %d'):format(changes.epic.id) }
        show_errors(buf, { e })
        return error_summary({ e })
      end
      return ('could not check the epic: %s; nothing was sent'):format(http.format_error(eerr))
    end
    if not current(st) then
      return 'the story was reloaded meanwhile; nothing was sent'
    end
  end
  vim.diagnostic.reset(story.edit_ns(), buf)

  if diff.is_empty(changes) then
    notify.info(('sc-%d: no changes'):format(id))
    return nil
  end

  --- The conflict check: `nil` if the save may go ahead.
  ---@async
  ---@return string? err
  local function conflict()
    local gerr, server = async.await(stories.get, id)
    if gerr then
      return ('could not check sc-%d for changes on Shortcut: %s; nothing was sent'):format(
        id,
        http.format_error(gerr)
      )
    end
    if (type(server) ~= 'table' or server.updated_at ~= st.snap.updated_at) and not st.force then
      return (
        'sc-%d was changed on Shortcut since it was loaded; nothing was sent. '
        .. ':Shortcut diff shows the differences, :w! overwrites them, :e! reloads (discarding your edits)'
      ):format(id)
    end
    if not current(st) then
      return 'the story was reloaded meanwhile; nothing was sent'
    end
    return nil
  end

  local conflict_err = conflict()
  if conflict_err then
    return conflict_err
  end

  local kept = 0
  local deletes = changes.tasks.delete
  if #deletes > 0 and require('shortcut.config').get().tasks.confirm_delete then
    local answer = confirm_delete(id, deletes)
    if answer == 'cancel' then
      notify.info(('sc-%d: save cancelled; nothing was sent'):format(id))
      return nil, { keep_modified = true }
    elseif answer == 'keep' then
      kept = #deletes
      changes.tasks.delete = {}
    end
    -- The answer may have taken a while: check again.
    conflict_err = conflict()
    if conflict_err then
      return conflict_err
    end
  end

  -- Send.
  local summary = diff.summary(changes)
  if next(changes.story) then
    local perr = async.await(stories.update, id, changes.story)
    if perr then
      return ('%s; nothing was saved'):format(http.format_error(perr))
    end
  end
  local failures = {} ---@type string[]
  local created = {} ---@type table<integer, integer> Line -> new task ID.
  for _, u in ipairs(changes.tasks.update) do
    local err = async.await(stories.tasks.update, id, u.id, u.fields)
    if err then
      table.insert(
        failures,
        ("update task '%s' (line %d): %s"):format(u.description, u.line, http.format_error(err))
      )
    end
  end
  for _, c in ipairs(changes.tasks.create) do
    local err, task = async.await(stories.tasks.create, id, c.fields)
    if err then
      table.insert(
        failures,
        ("add task '%s' (line %d): %s"):format(c.fields.description, c.line, http.format_error(err))
      )
    elseif type(task) == 'table' and type(task.id) == 'number' then
      created[c.line] = task.id
    end
  end
  for _, d in ipairs(changes.tasks.delete) do
    local err = async.await(stories.tasks.delete, id, d.id)
    if err then
      table.insert(failures, ("delete task '%s': %s"):format(d.description, http.format_error(err)))
    end
  end

  -- Reload.
  local ferr, fresh, epic = async.await(story.fetch, id)
  if not vim.api.nvim_buf_is_loaded(buf) then
    if #failures > 0 then
      return ('some changes failed:\n- %s'):format(table.concat(failures, '\n- '))
    end
    return nil
  end
  if #failures > 0 then
    local msg = ('sc-%d: %s of %s failed:\n- %s'):format(
      id,
      plural(#failures, 'change'),
      summary,
      table.concat(failures, '\n- ')
    )
    if ferr or not fresh then
      return msg .. '\nThe buffer keeps your edits; :e! reloads the story (discarding them).'
    end
    if current(st) then
      local rebased = story.rebase(buf, fresh, story.cache_refs(epic), created)
      if rebased then
        st.own[rebased] = true
      end
    end
    return msg .. '\nThe buffer keeps your edits; :w sends what failed again, :e! reloads.'
  end

  if ferr or not fresh then
    notify.warn(
      ('sc-%d saved (%s), but reloading it failed: %s; :e! to reload'):format(id, summary, ferr)
    )
    return nil
  end
  if not current(st) then
    notify.info(('sc-%d saved (%s)'):format(id, summary))
    return nil
  end

  -- Where each window's cursor is, to put it back on the same line.
  local marks = mark_lines(buf)
  for line, task in pairs(created) do
    marks[line] = task
  end
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local pos = vim.api.nvim_win_get_cursor(win)
    cursors[win] = anchor(cur, marks, pos[1], pos[2])
  end
  local snap = story.apply(buf, fresh, story.cache_refs(epic), st.snap.show_owners)
  st.own[snap] = true
  vim.bo[buf].modified = false
  local count = vim.api.nvim_buf_line_count(buf)
  for win, a in pairs(cursors) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { resolve(a, snap.meta, count), a.col })
    end
  end
  local kept_msg = kept > 0 and ('; kept %s'):format(plural(kept, 'task')) or ''
  if summary == '' then
    notify.info(('sc-%d: nothing else to save%s'):format(id, kept_msg))
  else
    notify.info(('sc-%d saved (%s)%s'):format(id, summary, kept_msg))
  end
  return nil
end

--- Save a story buffer (the story handler's `save`).
---@param buf integer
---@param id integer
---@param opts shortcut.buffer.SaveOpts
---@param done shortcut.buffer.SaveDone
function M.save(buf, id, opts, done)
  if saving[buf] then
    return done('a save is already in progress')
  end
  local snap = story.snapshot(buf)
  if not snap then
    return done('the story is not loaded; :e! to reload')
  end
  saving[buf] = true
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = false
  ---@type shortcut.story_save.State
  local st =
    { buf = buf, id = id, force = opts.force == true, snap = snap, own = { [snap] = true } }

  local function finish(err, done_opts)
    saving[buf] = nil
    -- Unless the buffer was reloaded meanwhile (`:e!`), which manages 'modifiable' itself.
    local s = vim.api.nvim_buf_is_loaded(buf) and story.snapshot(buf)
    if s and st.own[s] then
      vim.bo[buf].modifiable = modifiable
    end
    done(err, done_opts)
  end

  async.run(function()
    return run(st)
  end, function(thrown, err, done_opts)
    if thrown then
      return finish((tostring(thrown):gsub('^[^\n]-:%d+: ', '', 1)))
    end
    finish(err, done_opts)
  end)
end

---------------------------------------------------------------------------------------------------
-- :Shortcut diff
---------------------------------------------------------------------------------------------------

M.DIFF_SCHEME = 'shortcut-server://story/'

--- Open a vertical diff of a story buffer against a fresh render of the server's version.
---@param buf? integer Defaults to the current buffer.
function M.diff(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf --[[@as integer]]
  local info = vim.b[buf].shortcut
  local snap = story.snapshot(buf)
  if type(info) ~= 'table' or info.kind ~= 'story' or not snap then
    error('not a loaded story buffer', 0)
  end
  local id = info.id
  story.fetch(id, function(err, fresh, epic)
    if err or not fresh then
      return notify.error(('could not fetch sc-%d: %s'):format(id, err))
    end
    if not vim.api.nvim_buf_is_loaded(buf) then
      return
    end
    local lines = story.render(fresh, story.cache_refs(epic), { show_owners = snap.show_owners })
    local name = M.DIFF_SCHEME .. id
    local old = vim.fn.bufnr('^' .. vim.fn.escape(name, '\\/.*$^~[]') .. '$')
    if old > 0 then
      pcall(vim.api.nvim_buf_delete, old, { force = true })
    end
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
    vim.api.nvim_buf_set_name(scratch, name)
    vim.bo[scratch].bufhidden = 'wipe'
    vim.bo[scratch].modifiable = false
    vim.bo[scratch].modeline = false
    vim.bo[scratch].filetype = 'markdown'

    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= buf then
      win = vim.fn.win_findbuf(buf)[1]
    end
    if not win then
      vim.api.nvim_buf_delete(scratch, { force = true })
      return
    end
    vim.api.nvim_win_call(win, function()
      vim.cmd('diffthis')
    end)
    local split = vim.api.nvim_open_win(scratch, true, { split = 'right', win = win })
    vim.api.nvim_win_call(split, function()
      vim.cmd('diffthis')
    end)
    -- Leave diff mode in the story's window when the server version is closed.
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = scratch,
      once = true,
      callback = function()
        vim.schedule(function()
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_call(win, function()
              vim.cmd('diffoff')
            end)
          end
        end)
      end,
    })
  end)
end

require('shortcut.commands').register('diff', {
  desc = "Diff the story buffer against the server's version",
  run = function()
    M.diff(0)
  end,
})

return M

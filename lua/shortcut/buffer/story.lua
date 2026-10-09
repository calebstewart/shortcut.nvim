--- Story buffers: rendering a story as Markdown, and loading `shortcut://story/<id>`.
---
--- ```markdown
--- ---
--- id: 123
--- type: feature
--- state: In Progress
--- owners: [someone, someone-else]
--- epic: 45 Some epic
--- iteration: Sprint 42
--- estimate: 3
--- labels: [backend]
--- url: https://app.shortcut.com/<workspace>/story/123
--- ---
--- # Story title
---
--- Description…
---
--- <!-- shortcut:tasks -->
--- ## Tasks
--- - [x] Done task · @someone
--- - [ ] Open task
---
--- <!-- shortcut:comments (read-only) -->
--- ## Comments
--- **@someone** · 2026-10-01 14:03
--- > Comment body…
--- ```
---
--- `render()` is pure (no buffer or editor state), so pickers can use it for previews. The
--- loader renders into the buffer, marks each task line with an extmark (namespace
--- `shortcut.tasks`, `invalidate = true`) and keeps a snapshot of what was rendered for editing
--- to compare against (`snapshot()`).
---
--- API facts (OpenAPI spec, see `shortcut.api`):
---   - `Story` (`GET /stories/{id}`): `app_url`, `story_type` (`feature`/`bug`/`chore`),
---     `workflow_id`, `workflow_state_id`, `owner_ids` (member UUIDs), `epic_id`, `iteration_id`
---     and `estimate` (all three nullable), `label_ids` and `labels` (`LabelSlim`, with `name`),
---     `tasks`, `comments`, `updated_at`. There is no epic name: it comes from `GET /epics/{id}`.
---   - `Task`: `id`, `description`, `complete`, `position`, `owner_ids`.
---   - `StoryComment`: `id`, `author_id` (nullable), `created_at`, `deleted`, `parent_id`
---     (nullable; the comment it is threaded under), `text` (nullable once deleted).
local frontmatter = require('shortcut.buffer.frontmatter')

local M = {}

--- Header fields, in order.
M.FIELDS = { 'id', 'type', 'state', 'owners', 'epic', 'iteration', 'estimate', 'labels', 'url' }

M.TASKS_MARKER = '<!-- shortcut:tasks -->'
M.COMMENTS_MARKER = '<!-- shortcut:comments (read-only) -->'

--- Separates a task's description from its owners, and a comment's author from its date.
M.SEPARATOR = ' · '

--- Namespace of the task extmarks.
M.TASKS_NS = 'shortcut.tasks'

--- Lookup lists the loader makes sure are cached.
---@type shortcut.refs.Kind[]
M.REF_KINDS = { 'workflows', 'members', 'labels', 'iterations' }

--- What `render()` needs to turn IDs into names. Each function returns `nil` for an unknown ID;
--- the ID is then shown as `unknown-<id>` (see `unknown()`).
---@class shortcut.story.Refs
---@field state? fun(id: integer): { name: string }?
---@field member? fun(id: string): { mention_name: string }?
---@field label? fun(id: integer): { name: string }?
---@field iteration? fun(id: integer): { name: string }?
---@field epic? shortcut.story.Epic The story's epic.

---@class shortcut.story.Epic
---@field id integer
---@field name? string `nil` if it could not be fetched.

---@class shortcut.story.RenderOpts
---@field show_owners? boolean Show task owners (default `true`).

--- A range of lines, 1-based and inclusive. Empty when `last < first`.
---@class shortcut.story.Range
---@field first integer
---@field last integer

---@class shortcut.story.TaskLine
---@field id integer Task ID.
---@field line integer 1-based line number.

--- Where things are in a render. To find the sections again in edited lines, use `sections()`:
--- the markers are the last ones (a description may contain marker-like lines).
---@class shortcut.story.Meta
---@field header shortcut.story.Range The front matter, both `---` lines included.
---@field title integer The `# <name>` line.
---@field description shortcut.story.Range Between the title and the tasks marker, without the blank lines around it.
---@field tasks_marker integer
---@field tasks_section shortcut.story.Range From the tasks marker to the line before the comments marker.
---@field tasks shortcut.story.TaskLine[] In buffer order.
---@field comments_marker integer
---@field comments_section shortcut.story.Range From the comments marker to the last line.
---@field comments table<integer, integer> Comment ID -> line of its `**@author** · date` header.

---------------------------------------------------------------------------------------------------
-- Time
---------------------------------------------------------------------------------------------------

--- Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
---@param y integer
---@param m integer
---@param d integer
---@return integer
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- One line: newlines in a single-line field become spaces. Every server string rendered on a
--- single line goes through this: `nvim_buf_set_lines()` rejects lines containing newlines.
---@param s any
---@return string
local function one_line(s)
  if type(s) ~= 'string' then
    return ''
  end
  return (s:gsub('\r\n?', '\n'):gsub('\n', ' '))
end

--- A string of digits as an integer.
---@param s string
---@return integer
local function int(s)
  return tonumber(s) --[[@as integer]]
end

--- Seconds since the epoch of an ISO-8601 / RFC 3339 timestamp such as `2026-10-01T14:03:00Z`,
--- `2026-10-01T14:03:00.123Z` or `2026-10-01T14:03:00+02:00`. `nil` if it isn't one. Pure
--- arithmetic: does not depend on the local time zone or on `os.time()`'s interpretation.
---@param s any
---@return integer?
function M.parse_time(s)
  if type(s) ~= 'string' then
    return nil
  end
  local y, mo, d, h, mi, sec, rest =
    s:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):?(%d?%d?)(.*)$')
  if not y then
    return nil
  end
  rest = rest:gsub('^[.,]%d+', '')
  local offset
  if rest == 'Z' or rest == 'z' then
    offset = 0
  else
    local sign, oh, om = rest:match('^([+-])(%d%d):?(%d%d)$')
    if not sign then
      return nil
    end
    offset = (int(oh) * 3600 + int(om) * 60) * (sign == '-' and -1 or 1)
  end
  local days = days_from_civil(int(y), int(mo), int(d))
  return days * 86400 + int(h) * 3600 + int(mi) * 60 + (sec ~= '' and int(sec) or 0) - offset
end

--- `YYYY-MM-DD HH:MM` in local time, or the input unchanged if it can't be parsed.
---@param s any
---@return string
function M.format_time(s)
  local t = M.parse_time(s)
  if not t then
    return type(s) == 'string' and one_line(s) or '?'
  end
  return os.date('%Y-%m-%d %H:%M', t) --[[@as string]]
end

---------------------------------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------------------------------

--- How an ID with no known name is shown. Stable, so re-rendering the same story gives the same
--- text and editing (which compares parses of renders) sees no change.
---@param id any
---@return string
function M.unknown(id)
  return 'unknown-' .. one_line(tostring(id))
end

---@param v any
---@return boolean
local function present(v)
  return v ~= nil and v ~= vim.NIL
end

---@param list any
---@return any[]
local function list_of(list)
  return type(list) == 'table' and list or {}
end

---@param refs shortcut.story.Refs
---@param id any
---@return string
local function mention(refs, id)
  local m = refs.member and present(id) and refs.member(id)
  return one_line(m and m.mention_name or M.unknown(id))
end

--- Lines of a text, with CRLF/CR as LF.
---@param s any
---@return string[]
local function text_lines(s)
  if type(s) ~= 'string' then
    return {}
  end
  s = s:gsub('\r\n?', '\n')
  return vim.split(s, '\n', { plain = true })
end

--- The header fields of a story.
---@param story table
---@param refs shortcut.story.Refs
---@return table<string, shortcut.frontmatter.Value?>
function M.header(story, refs)
  local state ---@type string?
  if present(story.workflow_state_id) then
    local s = refs.state and refs.state(story.workflow_state_id)
    state = s and s.name or M.unknown(story.workflow_state_id)
  end

  local owners = {}
  for _, id in ipairs(list_of(story.owner_ids)) do
    table.insert(owners, mention(refs, id))
  end

  local epic ---@type string?
  if present(story.epic_id) then
    local e = refs.epic
    local name = e and e.id == story.epic_id and e.name or nil
    epic = name and ('%d %s'):format(story.epic_id, one_line(name))
      or ('%d (name unavailable)'):format(story.epic_id)
  end

  local iteration ---@type string?
  if present(story.iteration_id) then
    local i = refs.iteration and refs.iteration(story.iteration_id)
    iteration = i and i.name or M.unknown(story.iteration_id)
  end

  -- The story carries its labels' names; the cache is only a fallback.
  local label_names = {}
  for _, l in ipairs(list_of(story.labels)) do
    if type(l) == 'table' and present(l.id) and type(l.name) == 'string' then
      label_names[l.id] = l.name
    end
  end
  local labels = {}
  local label_ids = story.label_ids
  if type(label_ids) ~= 'table' then
    label_ids = vim.tbl_map(function(l)
      return l.id
    end, list_of(story.labels))
  end
  for _, id in ipairs(label_ids) do
    local name = label_names[id]
    if not name then
      local l = refs.label and refs.label(id)
      name = l and l.name or M.unknown(id)
    end
    table.insert(labels, name)
  end

  return {
    id = story.id,
    type = type(story.story_type) == 'string' and story.story_type or nil,
    state = state,
    owners = owners,
    epic = epic,
    iteration = iteration,
    estimate = present(story.estimate) and story.estimate or nil,
    labels = labels,
    url = type(story.app_url) == 'string' and story.app_url or nil,
  }
end

---@param a table
---@param b table
---@return boolean
local function by_position(a, b)
  local pa, pb = tonumber(a.position) or 0, tonumber(b.position) or 0
  if pa ~= pb then
    return pa < pb
  end
  return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
end

--- A task line, without its extmark.
---@param task table
---@param refs shortcut.story.Refs
---@param show_owners boolean
---@return string
function M.task_line(task, refs, show_owners)
  local line = ('- [%s] %s'):format(
    task.complete == true and 'x' or ' ',
    one_line(task.description)
  )
  local owners = list_of(task.owner_ids)
  if show_owners and #owners > 0 then
    local mentions = {}
    for i, id in ipairs(owners) do
      mentions[i] = '@' .. mention(refs, id)
    end
    line = line .. M.SEPARATOR .. table.concat(mentions, ' ')
  end
  return line
end

---@param comment table
---@return integer
local function comment_time(comment)
  return M.parse_time(comment.created_at) or 0
end

---@param a table
---@param b table
---@return boolean
local function chronological(a, b)
  local ta, tb = comment_time(a), comment_time(b)
  if ta ~= tb then
    return ta < tb
  end
  return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
end

--- Comments as a forest: top-level comments with their (non-deleted) replies, chronological.
--- A deleted comment is kept only if it has replies to show, so they stay under it.
---@param comments any
---@return { comment: table, replies: table[] }[]
local function comment_tree(comments)
  local nodes, ids = {}, {}
  for _, c in ipairs(list_of(comments)) do
    if type(c) == 'table' and present(c.id) then
      local node = { comment = c, replies = {} }
      nodes[c.id] = node
      table.insert(ids, c)
    end
  end
  table.sort(ids, chronological)
  local roots = {}
  for _, c in ipairs(ids) do
    local node = nodes[c.id]
    local parent = present(c.parent_id) and nodes[c.parent_id] or nil
    -- Guard against cycles: a comment can't be its own ancestor.
    local p, seen = parent, { [c.id] = true }
    while p do
      if seen[p.comment.id] then
        parent = nil
        break
      end
      seen[p.comment.id] = true
      local pp = p.comment.parent_id
      p = present(pp) and nodes[pp] or nil
    end
    if parent then
      table.insert(parent.replies, node)
    else
      table.insert(roots, node)
    end
  end
  ---@param list table[]
  ---@return table[]
  local function prune(list)
    local out = {}
    for _, node in ipairs(list) do
      node.replies = prune(node.replies)
      if node.comment.deleted ~= true or #node.replies > 0 then
        table.insert(out, node)
      end
    end
    return out
  end
  return prune(roots)
end

--- Render a story.
---
--- `lines` is the buffer content; `meta` says where things are (see `shortcut.story.Meta`).
--- Pure: uses only its arguments (and the local time zone for comment dates).
---@param story table A `Story` from `GET /stories/{id}`.
---@param refs? shortcut.story.Refs
---@param opts? shortcut.story.RenderOpts
---@return string[] lines
---@return shortcut.story.Meta meta
function M.render(story, refs, opts)
  vim.validate('story', story, 'table')
  refs = refs or {}
  opts = opts or {}
  local show_owners = opts.show_owners ~= false

  local lines = frontmatter.serialize(M.header(story, refs), M.FIELDS)
  -- The other fields are set as the lines are added.
  local meta = { header = { first = 1, last = #lines }, tasks = {}, comments = {} } ---@type table

  local function add(line)
    table.insert(lines, line)
    return #lines
  end

  meta.title = add('# ' .. one_line(story.name))
  add('')

  local description = text_lines(story.description)
  while #description > 0 and description[#description]:match('^%s*$') do
    table.remove(description)
  end
  while #description > 0 and description[1]:match('^%s*$') do
    table.remove(description, 1)
  end
  meta.description = { first = #lines + 1, last = #lines + #description }
  if #description > 0 then
    vim.list_extend(lines, description)
    add('')
  end

  meta.tasks_marker = add(M.TASKS_MARKER)
  add('## Tasks')
  local tasks = {}
  for _, t in ipairs(list_of(story.tasks)) do
    if type(t) == 'table' and present(t.id) then
      table.insert(tasks, t)
    end
  end
  table.sort(tasks, by_position)
  for _, task in ipairs(tasks) do
    table.insert(meta.tasks, { id = task.id, line = add(M.task_line(task, refs, show_owners)) })
  end
  add('')
  meta.tasks_section = { first = meta.tasks_marker, last = #lines }

  meta.comments_marker = add(M.COMMENTS_MARKER)
  add('## Comments')

  ---@param node { comment: table, replies: table[] }
  ---@param prefix string Blockquote prefix of the comment's header line.
  local function render_comment(node, prefix)
    local c = node.comment
    local header
    if c.deleted == true then
      header = '*(deleted comment)*'
    else
      header = ('**@%s**%s%s'):format(
        present(c.author_id) and mention(refs, c.author_id) or 'unknown',
        M.SEPARATOR,
        M.format_time(c.created_at)
      )
    end
    meta.comments[c.id] = add((prefix .. header):gsub('%s+$', ''))
    local body = prefix .. '> '
    if c.deleted ~= true then
      local text = text_lines(c.text)
      while #text > 0 and text[#text]:match('^%s*$') do
        table.remove(text)
      end
      for _, l in ipairs(text) do
        add((body .. l):gsub('%s+$', ''))
      end
    end
    for _, reply in ipairs(node.replies) do
      add((body):gsub('%s+$', ''))
      render_comment(reply, body)
    end
  end

  for i, node in ipairs(comment_tree(story.comments)) do
    if i > 1 then
      add('')
    end
    render_comment(node, '')
  end
  meta.comments_section = { first = meta.comments_marker, last = #lines }
  return lines, meta --[[@as shortcut.story.Meta]]
end

--- Find the section markers in a story buffer's lines. A description may contain a line equal
--- to a marker, but task and comment lines never do (they start with `- [`, `>`, `**@` or
--- `*(`), so the **last** comments marker, and the last tasks marker before it, are the real
--- ones. Lines are compared without surrounding whitespace.
---@param lines string[]
---@return { tasks_marker: integer, comments_marker: integer }? markers 1-based line numbers.
---@return string? err If a marker is missing.
function M.sections(lines)
  local tasks, comments ---@type integer?, integer?
  for i = #lines, 1, -1 do
    local line = vim.trim(lines[i])
    if not comments and line == M.COMMENTS_MARKER then
      comments = i
    elseif comments and line == M.TASKS_MARKER then
      tasks = i
      break
    end
  end
  if not comments then
    return nil, ("the line '%s' is missing"):format(M.COMMENTS_MARKER)
  end
  if not tasks then
    return nil,
      ("the line '%s' is missing (it must come before '%s')"):format(
        M.TASKS_MARKER,
        M.COMMENTS_MARKER
      )
  end
  return { tasks_marker = tasks, comments_marker = comments }
end

---------------------------------------------------------------------------------------------------
-- Buffers
---------------------------------------------------------------------------------------------------

--- What was rendered into a buffer, for editing to compare against.
---@class shortcut.story.Snapshot
---@field story table The story as fetched.
---@field updated_at? string `story.updated_at`, for the conflict check.
---@field lines string[] The rendered lines.
---@field meta shortcut.story.Meta
---@field refs shortcut.story.Refs What it was rendered with (`epic` included).
---@field show_owners boolean
---@field task_marks table<integer, integer> Extmark ID (namespace `shortcut.tasks`) -> task ID.

---@type table<integer, shortcut.story.Snapshot>
local snapshots = {}

--- Loads in progress, by buffer: cancelled by a new load or when the buffer is unloaded.
--- `comment` is where to put the cursor once loaded.
---@type table<integer, { cancel: fun(), comment?: integer }>
local loading = {}

--- Epic names fetched this session, by epic ID: used when fetching the epic fails.
---@type table<integer, string>
local epic_names = {}

local cleanup_group ---@type integer?

---@param buf integer
local function forget(buf)
  snapshots[buf] = nil
  local l = loading[buf]
  loading[buf] = nil
  if l then
    l.cancel()
  end
end

local function ensure_cleanup()
  if cleanup_group then
    return
  end
  cleanup_group = vim.api.nvim_create_augroup('shortcut.buffer.story', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = cleanup_group,
    pattern = 'shortcut://story/*',
    desc = 'shortcut.nvim: cancel story loads, drop snapshots',
    callback = function(ev)
      forget(ev.buf)
    end,
  })
end

--- The snapshot of a loaded story buffer, or `nil`.
---@param buf? integer Defaults to the current buffer.
---@return shortcut.story.Snapshot?
function M.snapshot(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return snapshots[buf]
end

---@return integer
function M.tasks_ns()
  return vim.api.nvim_create_namespace(M.TASKS_NS)
end

--- The task extmarks of a buffer that are still valid: `{ task_id, row }` (0-based rows), in
--- buffer order. Editing uses these to match lines to tasks:
---   - a task line without one is a new task; a task missing from the result was deleted,
---   - at most one task per row: if lines were joined (`J`), several valid marks share a row,
---     and only the task rendered first keeps it; the others count as deleted,
---   - a mark follows its line when it is moved without being deleted (`:move`, `cc`, editing
---     the text, `yyp` (the copy is new), `<CR>` at column 0). A line that is deleted and put
---     back elsewhere (`ddp`) loses its mark: it reads as a deleted task plus a new one.
---@param buf? integer Defaults to the current buffer.
---@return { id: integer, row: integer }[]
function M.task_marks(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf --[[@as integer]]
  local snap = snapshots[buf]
  if not snap then
    return {}
  end
  local order = {} ---@type table<integer, integer> Task ID -> position in the render.
  for i, t in ipairs(snap.meta.tasks) do
    order[t.id] = i
  end
  local out = {} ---@type { id: integer, row: integer }[]
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, M.tasks_ns(), 0, -1, { details = true })) do
    local id, row, details = mark[1], mark[2], mark[4]
    local task = snap.task_marks[id]
    if task and not (details and details.invalid) then
      local last = out[#out]
      if last and last.row == row then
        if order[task] < order[last.id] then
          last.id = task
        end
      else
        table.insert(out, { id = task, row = row })
      end
    end
  end
  return out
end

--- Put the cursor of every window showing `buf` on `line` (1-based).
---@param buf integer
---@param line integer
local function set_cursor(buf, line)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  end
end

--- Jump to a comment in a loaded story buffer (the current window, if it shows it). While the
--- buffer is loading, jump once it is loaded.
---@param buf integer
---@param comment integer
---@return boolean found
function M.jump(buf, comment)
  if loading[buf] then
    loading[buf].comment = comment
    return true
  end
  local snap = snapshots[buf]
  local line = snap and snap.meta.comments[comment]
  if not line then
    if snap then
      require('shortcut.notify').warn(
        ('comment %d not found on sc-%s'):format(comment, tostring(snap.story.id))
      )
    end
    return false
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == buf then
    pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  else
    set_cursor(buf, line)
  end
  return true
end

--- Namespace of the diagnostics a failed save leaves (see `shortcut.buffer.story_save`).
M.EDIT_NS = 'shortcut.edit'

---@return integer
function M.edit_ns()
  return vim.api.nvim_create_namespace(M.EDIT_NS)
end

--- Write a rendered story into `buf`: lines, task extmarks, snapshot. Clears the diagnostics of
--- a previous save.
---@param buf integer
---@param story table
---@param refs shortcut.story.Refs
---@param show_owners boolean
---@return shortcut.story.Snapshot
function M.apply(buf, story, refs, show_owners)
  local lines, meta = M.render(story, refs, { show_owners = show_owners })
  vim.diagnostic.reset(M.edit_ns(), buf)
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  local ns = M.tasks_ns()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels

  local task_marks = {}
  for _, t in ipairs(meta.tasks) do
    local mark = vim.api.nvim_buf_set_extmark(buf, ns, t.line - 1, 0, { invalidate = true })
    task_marks[mark] = t.id
  end
  ---@type shortcut.story.Snapshot
  local snap = {
    story = story,
    updated_at = type(story.updated_at) == 'string' and story.updated_at or nil,
    lines = lines,
    meta = meta,
    refs = refs,
    show_owners = show_owners,
    task_marks = task_marks,
  }
  snapshots[buf] = snap
  return snap
end

--- Make `story` (fetched again) the snapshot of `buf` without changing its lines: after a save
--- that partly failed, the buffer keeps the edits, and the next save compares them with what
--- the server has now, so only what failed is sent again. Task extmarks of tasks the server no
--- longer has are removed; `created` adds marks for tasks created by that save.
---@param buf integer
---@param story table
---@param refs shortcut.story.Refs
---@param created table<integer, integer> 1-based line -> ID of the task created from it.
---@return shortcut.story.Snapshot?
function M.rebase(buf, story, refs, created)
  local old = snapshots[buf]
  if not old then
    return nil
  end
  local lines, meta = M.render(story, refs, { show_owners = old.show_owners })
  local exists = {}
  for _, t in ipairs(meta.tasks) do
    exists[t.id] = true
  end
  local ns = M.tasks_ns()
  local task_marks = {}
  for mark, id in pairs(old.task_marks) do
    if exists[id] then
      task_marks[mark] = id
    else
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
    end
  end
  local count = vim.api.nvim_buf_line_count(buf)
  for line, id in pairs(created) do
    if exists[id] and line <= count then
      local mark = vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { invalidate = true })
      task_marks[mark] = id
    end
  end
  ---@type shortcut.story.Snapshot
  local snap = {
    story = story,
    updated_at = type(story.updated_at) == 'string' and story.updated_at or nil,
    lines = lines,
    meta = meta,
    refs = refs,
    show_owners = old.show_owners,
    task_marks = task_marks,
  }
  snapshots[buf] = snap
  return snap
end

--- A message for a failed story fetch.
---@param id integer
---@param err shortcut.http.Error
---@return string
local function load_error(id, err)
  if err.status == 404 then
    return ('story sc-%d not found (it may have been deleted, or be in another workspace)'):format(
      id
    )
  end
  if err.kind == 'auth' then
    return err.message
  end
  return require('shortcut.http').format_error(err)
end

--- Fetch a story, its epic's name and the lookup lists. `callback(err, story, epic, refs_err)`
--- runs on the main loop: `err` is a message if the story could not be fetched; `epic` is
--- `{ id, name? }` if the story has one; `refs_err` is set if the lookup lists are unavailable.
---@param id integer
---@param callback fun(err?: string, story?: table, epic?: shortcut.story.Epic, refs_err?: shortcut.http.Error)
---@return { cancel: fun(), comment?: integer }
function M.fetch(id, callback)
  local stories = require('shortcut.api.stories')
  local cache = require('shortcut.cache')
  local handles = {} ---@type { cancel: fun(self: any) }[]
  local cancelled, finished = false, false
  local pending = 2
  local story_err, story, epic, refs_err ---@type string?, table?, shortcut.story.Epic?, shortcut.http.Error?

  local function step()
    pending = pending - 1
    if pending > 0 or cancelled or finished then
      return
    end
    finished = true
    if story_err then
      return callback(story_err)
    end
    callback(nil, story, epic, refs_err)
  end

  table.insert(
    handles,
    stories.get(id, function(err, data)
      if err then
        story_err = load_error(id, err)
        -- Nothing to render: don't wait for the lists.
        pending = 1
        return step()
      end
      if type(data) ~= 'table' or data.id == nil then
        story_err = ('unexpected response from GET /stories/%d'):format(id)
        pending = 1
        return step()
      end
      story = data
      local epic_id = data.epic_id
      if type(epic_id) == 'number' and epic_id > 0 and epic_id == math.floor(epic_id) then
        epic = { id = epic_id }
        pending = pending + 1
        table.insert(
          handles,
          require('shortcut.api.epics').get(epic_id, function(eerr, edata)
            if not eerr and type(edata) == 'table' and type(edata.name) == 'string' then
              epic.name = edata.name
              epic_names[epic_id] = edata.name
            else
              epic.name = epic_names[epic_id]
            end
            step()
          end)
        )
      end
      step()
    end)
  )
  table.insert(
    handles,
    cache.load(M.REF_KINDS, function(err)
      refs_err = err
      step()
    end)
  )

  return {
    cancel = function()
      if cancelled or finished then
        return
      end
      cancelled = true
      for _, h in ipairs(handles) do
        pcall(h.cancel, h)
      end
    end,
  }
end

--- Lookups from the cache, plus the story's epic.
---@param epic? shortcut.story.Epic
---@return shortcut.story.Refs
function M.cache_refs(epic)
  local cache = require('shortcut.cache')
  return {
    state = cache.state,
    member = cache.member,
    label = cache.label,
    iteration = cache.iteration,
    epic = epic,
  }
end

---@type shortcut.buffer.Handler
M.handler = {
  load = function(buf, id, opts, done)
    ensure_cleanup()
    forget(buf)
    local handle
    handle = M.fetch(id, function(err, story, epic, refs_err)
      if loading[buf] ~= handle then
        return
      end
      loading[buf] = nil
      if err then
        return done(err)
      end
      ---@cast story table
      if not vim.api.nvim_buf_is_loaded(buf) then
        return
      end
      if refs_err then
        require('shortcut.notify').warn(
          ('lookup lists unavailable, showing IDs instead of names: %s'):format(
            require('shortcut.http').format_error(refs_err)
          )
        )
      end
      local show_owners = require('shortcut.config').get().tasks.show_owners
      local ok, apply_err = pcall(M.apply, buf, story, M.cache_refs(epic), show_owners)
      if not ok then
        snapshots[buf] = nil
        -- Without the `file:line: ` prefix of the error.
        return done((tostring(apply_err):gsub('^[^\n]-:%d+: ', '', 1)))
      end
      done()
      set_cursor(buf, 1)
      if handle.comment then
        M.jump(buf, handle.comment)
      end
    end)
    handle.comment = opts.comment
    loading[buf] = handle
  end,

  save = function(buf, id, opts, done)
    require('shortcut.buffer.story_save').save(buf, id, opts, done)
  end,

  jump = function(buf, comment)
    M.jump(buf, comment)
  end,
}

return M

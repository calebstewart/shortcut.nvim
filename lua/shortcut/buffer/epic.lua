--- Epic buffers: rendering an epic and its stories as Markdown, and loading
--- `shortcut://epic/<id>`. Read-only for now.
---
--- ```markdown
--- ---
--- id: 678
--- state: In Progress
--- owners: [someone]
--- teams: [Platform]
--- labels: [q4]
--- planned_start: 2026-10-01
--- deadline: 2026-12-15
--- stories: 14 (6 done, 5 started, 3 unstarted)
--- url: https://app.shortcut.com/<workspace>/epic/678
--- ---
--- # Epic name
---
--- Description…
---
--- <!-- shortcut:stories -->
--- ## Stories
---
--- ### In Progress
--- - sc-12345 Story title · someone · 3pt
--- - sc-12346 Another story · unowned
---
--- ### Done
--- - sc-12347 Finished story · someone, someone-else
--- ```
---
--- `render()` is pure (no buffer or editor state), so pickers can use it for previews. The
--- loader renders into the buffer and keeps a snapshot of what was rendered (`snapshot()`), the
--- same way story buffers do.
---
--- API facts (OpenAPI spec, see `shortcut.api`):
---   - `Epic` (`GET /epics/{id}`): `name`, `description`, `app_url`, `epic_state_id` (an
---     `EpicState` of the workspace's single epic workflow, `GET /epic-workflow`), `owner_ids`
---     (member UUIDs), `group_ids` (team UUIDs), `label_ids` and `labels` (`LabelSlim`, with
---     `name`), `planned_start_date` and `deadline` (nullable `date-time` strings), `stats`
---     (`EpicStats`), `updated_at`.
---   - `GET /epics/{id}/stories` returns every story of the epic at once (no paging), as
---     `StorySlim[]`: `id`, `name`, `story_type`, `workflow_id`, `workflow_state_id`, `position`,
---     `owner_ids`, `estimate` (nullable), `archived`. Stories may come from several workflows.
local frontmatter = require('shortcut.buffer.frontmatter')
local story = require('shortcut.buffer.story')

local one_line, unknown = story.one_line, story.unknown

local M = {}

--- Header fields, in order.
M.FIELDS = {
  'id',
  'state',
  'owners',
  'teams',
  'labels',
  'planned_start',
  'deadline',
  'stories',
  'url',
}

M.STORIES_MARKER = '<!-- shortcut:stories -->'

--- Separates a story line's title, owners and estimate.
M.SEPARATOR = story.SEPARATOR

--- Shown under `## Stories` when no (unarchived) story is in the epic.
M.NO_STORIES = '*No stories.*'

--- Lookup lists the loader makes sure are cached.
---@type shortcut.refs.Kind[]
M.REF_KINDS = { 'workflows', 'epic_workflow', 'members', 'labels', 'groups' }

--- Order of the state groups by state type. The spec doesn't list the types; besides
--- `unstarted`, `started` and `done`, real workspaces have `backlog` states (`EpicStats` counts
--- them apart too: `num_stories_backlog`).
local TYPE_RANK = { backlog = 1, unstarted = 2, started = 3, done = 4 }
--- Rank of stories whose state is unknown (or of an unexpected type): last.
local UNKNOWN_RANK = 5

--- What `render()` needs to turn IDs into names. Each function returns `nil` for an unknown ID;
--- the ID is then shown as `unknown-<id>`.
---@class shortcut.epic.Refs
---@field epic_state? fun(id: integer): { name: string }?
---@field state? fun(id: integer): { name: string, type?: string, position?: integer }? A story's workflow state.
---@field member? fun(id: string): { mention_name: string }?
---@field label? fun(id: integer): { name: string }?
---@field group? fun(id: string): { name: string }?

---@class shortcut.epic.Counts
---@field total integer Stories shown (archived ones are not).
---@field backlog integer
---@field unstarted integer
---@field started integer
---@field done integer
---@field unknown integer Stories whose state (type) is unknown.

---@class shortcut.epic.Group
---@field name string The state name (states with the same name are merged).
---@field line integer The `### <name>` line.
---@field stories integer[] Story IDs, in buffer order.

---@class shortcut.epic.StoryLine
---@field id integer Story ID.
---@field line integer 1-based line number.

--- Where things are in a render.
---@class shortcut.epic.Meta
---@field header shortcut.story.Range The front matter, both `---` lines included.
---@field title integer The `# <name>` line.
---@field description shortcut.story.Range Between the title and the stories marker, without the blank lines around it.
---@field stories_marker integer
---@field stories_section shortcut.story.Range From the stories marker to the last line.
---@field groups shortcut.epic.Group[] In buffer order.
---@field stories shortcut.epic.StoryLine[] In buffer order.
---@field counts shortcut.epic.Counts

---------------------------------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------------------------------

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

---@param refs shortcut.epic.Refs
---@param id any
---@return string
local function mention(refs, id)
  local m = refs.member and present(id) and refs.member(id)
  return one_line(m and m.mention_name or unknown(id))
end

--- The date of a `date-time` string (`2026-10-01T00:00:00Z` -> `2026-10-01`), as written: not
--- converted to local time, so the day is the one set in Shortcut whatever the time zone.
---@param s any
---@return string?
local function date(s)
  if type(s) ~= 'string' then
    return nil
  end
  return s:match('^(%d%d%d%d%-%d%d%-%d%d)') or one_line(s)
end

--- The stories shown: unarchived, with an ID.
---@param stories any
---@return table[]
local function visible(stories)
  local out = {}
  for _, s in ipairs(list_of(stories)) do
    if type(s) == 'table' and present(s.id) and s.archived ~= true then
      table.insert(out, s)
    end
  end
  return out
end

---@param refs shortcut.epic.Refs
---@param s table A story.
---@return { name: string, type?: string, position?: integer }?
local function story_state(refs, s)
  if not present(s.workflow_state_id) or not refs.state then
    return nil
  end
  return refs.state(s.workflow_state_id)
end

--- Counts of stories by state type.
---@param stories any `StorySlim[]`.
---@param refs? shortcut.epic.Refs
---@return shortcut.epic.Counts
function M.counts(stories, refs)
  refs = refs or {}
  local counts = { total = 0, backlog = 0, unstarted = 0, started = 0, done = 0, unknown = 0 }
  for _, s in ipairs(visible(stories)) do
    counts.total = counts.total + 1
    local st = story_state(refs, s)
    local t = st and st.type
    if t and TYPE_RANK[t] then
      counts[t] = counts[t] + 1
    else
      counts.unknown = counts.unknown + 1
    end
  end
  return counts
end

--- The `stories` header value: `14 (6 done, 5 started, 3 unstarted)`, plus `, N backlog` if
--- any are in a backlog state and `, N unknown` for stories in a state that could not be
--- looked up. Just `0` (an integer, so it is written
--- unquoted) for an empty epic.
---@param counts shortcut.epic.Counts
---@return string|integer
function M.summary(counts)
  if counts.total == 0 then
    return 0
  end
  local s = ('%d (%d done, %d started, %d unstarted'):format(
    counts.total,
    counts.done,
    counts.started,
    counts.unstarted
  )
  if counts.backlog > 0 then
    s = s .. (', %d backlog'):format(counts.backlog)
  end
  if counts.unknown > 0 then
    s = s .. (', %d unknown'):format(counts.unknown)
  end
  return s .. ')'
end

--- The header fields of an epic.
---@param epic table
---@param stories any The epic's stories, for the `stories` summary.
---@param refs shortcut.epic.Refs
---@return table<string, shortcut.frontmatter.Value?>
function M.header(epic, stories, refs)
  local state ---@type string?
  if present(epic.epic_state_id) then
    local s = refs.epic_state and refs.epic_state(epic.epic_state_id)
    state = s and s.name or unknown(epic.epic_state_id)
  end

  local owners = {}
  for _, id in ipairs(list_of(epic.owner_ids)) do
    table.insert(owners, mention(refs, id))
  end

  local teams = {}
  for _, id in ipairs(list_of(epic.group_ids)) do
    local g = refs.group and refs.group(id)
    table.insert(teams, g and g.name or unknown(id))
  end

  -- The epic carries its labels' names; the cache is only a fallback.
  local label_names = {}
  for _, l in ipairs(list_of(epic.labels)) do
    if type(l) == 'table' and present(l.id) and type(l.name) == 'string' then
      label_names[l.id] = l.name
    end
  end
  local labels = {}
  local label_ids = epic.label_ids
  if type(label_ids) ~= 'table' then
    label_ids = {}
    for _, l in ipairs(list_of(epic.labels)) do
      if type(l) == 'table' and present(l.id) then
        table.insert(label_ids, l.id)
      end
    end
  end
  for _, id in ipairs(label_ids) do
    local name = label_names[id]
    if not name then
      local l = refs.label and refs.label(id)
      name = l and l.name or unknown(id)
    end
    table.insert(labels, name)
  end

  return {
    id = epic.id,
    state = state,
    owners = owners,
    teams = teams,
    labels = labels,
    planned_start = date(epic.planned_start_date),
    deadline = date(epic.deadline),
    stories = M.summary(M.counts(stories, refs)),
    url = type(epic.app_url) == 'string' and epic.app_url or nil,
  }
end

--- A story line: `- sc-<id> <title> · <owners or "unowned"> · <estimate>pt`.
---@param s table A story.
---@param refs shortcut.epic.Refs
---@return string
function M.story_line(s, refs)
  local owners = {}
  for _, id in ipairs(list_of(s.owner_ids)) do
    table.insert(owners, mention(refs, id))
  end
  local line = ('- sc-%s %s%s%s'):format(
    one_line(tostring(s.id)),
    one_line(s.name),
    M.SEPARATOR,
    #owners > 0 and table.concat(owners, ', ') or 'unowned'
  )
  if type(s.estimate) == 'number' then
    line = line .. M.SEPARATOR .. ('%spt'):format(s.estimate)
  end
  return line
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

--- Stories grouped by state name, groups in order: by state type (backlog, unstarted, started,
--- done, then unknown states), then by the state's position in its workflow, then by name. States of
--- different workflows with the same name are one group, placed by the first of them.
---@param stories any
---@param refs shortcut.epic.Refs
---@return { name: string, stories: table[] }[]
function M.groups(stories, refs)
  local by_name = {} ---@type table<string, { name: string, rank: integer, position: number, stories: table[] }>
  local groups = {}
  for _, s in ipairs(visible(stories)) do
    local st = story_state(refs, s)
    local name, rank, position
    if st then
      name = one_line(st.name)
      rank = TYPE_RANK[st.type] or UNKNOWN_RANK
      position = tonumber(st.position) or 0
    else
      name = present(s.workflow_state_id) and unknown(s.workflow_state_id) or 'unknown'
      rank = UNKNOWN_RANK
      position = tonumber(s.workflow_state_id) or 0
    end
    local g = by_name[name]
    if not g then
      g = { name = name, rank = rank, position = position, stories = {} }
      by_name[name] = g
      table.insert(groups, g)
    elseif rank < g.rank or (rank == g.rank and position < g.position) then
      g.rank, g.position = rank, position
    end
    table.insert(g.stories, s)
  end
  table.sort(groups, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    if a.position ~= b.position then
      return a.position < b.position
    end
    return a.name < b.name
  end)
  local out = {}
  for i, g in ipairs(groups) do
    table.sort(g.stories, by_position)
    out[i] = { name = g.name, stories = g.stories }
  end
  return out
end

--- Render an epic and its stories.
---
--- `lines` is the buffer content; `meta` says where things are (see `shortcut.epic.Meta`).
--- Pure: uses only its arguments.
---@param epic table An `Epic` from `GET /epics/{id}`.
---@param stories? table[] Its stories (`StorySlim[]` from `GET /epics/{id}/stories`).
---@param refs? shortcut.epic.Refs
---@return string[] lines
---@return shortcut.epic.Meta meta
function M.render(epic, stories, refs)
  vim.validate('epic', epic, 'table')
  vim.validate('stories', stories, 'table', true)
  refs = refs or {}
  stories = stories or {}

  local lines = frontmatter.serialize(M.header(epic, stories, refs), M.FIELDS)
  -- The other fields are set as the lines are added.
  local meta = { header = { first = 1, last = #lines }, groups = {}, stories = {} } ---@type table

  local function add(line)
    table.insert(lines, line)
    return #lines
  end

  meta.title = add('# ' .. one_line(epic.name))
  add('')

  local description = story.text_lines(epic.description)
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

  meta.stories_marker = add(M.STORIES_MARKER)
  add('## Stories')
  local groups = M.groups(stories, refs)
  if #groups == 0 then
    add('')
    add(M.NO_STORIES)
  end
  for _, g in ipairs(groups) do
    add('')
    local group = { name = g.name, line = add('### ' .. g.name), stories = {} }
    for _, s in ipairs(g.stories) do
      table.insert(meta.stories, { id = s.id, line = add(M.story_line(s, refs)) })
      table.insert(group.stories, s.id)
    end
    table.insert(meta.groups, group)
  end
  meta.stories_section = { first = meta.stories_marker, last = #lines }
  meta.counts = M.counts(stories, refs)
  return lines, meta --[[@as shortcut.epic.Meta]]
end

--- The `sc-<id>` on a line: the one under column `col` (0-based byte index) if there is one,
--- else the first. `nil` if the line has none.
---@param line string
---@param col? integer
---@return integer?
function M.id_at(line, col)
  local uri = require('shortcut.uri')
  local first ---@type integer?
  for start, digits, finish in line:gmatch('()%f[%w]sc%-(%d+)%f[%W]()') do
    local target = uri.parse('sc-' .. digits)
    local id = target and target.id
    if id then
      if col and col + 1 >= start and col + 1 < finish then
        return id
      end
      first = first or id
    end
  end
  return first
end

---------------------------------------------------------------------------------------------------
-- Buffers
---------------------------------------------------------------------------------------------------

--- What was rendered into a buffer (the same shape as story snapshots, for editing later).
---@class shortcut.epic.Snapshot
---@field epic table The epic as fetched.
---@field stories table[] Its stories as fetched.
---@field updated_at? string `epic.updated_at`.
---@field lines string[] The rendered lines.
---@field meta shortcut.epic.Meta
---@field refs shortcut.epic.Refs What it was rendered with.

---@type table<integer, shortcut.epic.Snapshot>
local snapshots = {}

--- Loads in progress, by buffer: cancelled by a new load or when the buffer is unloaded.
---@type table<integer, { cancel: fun() }>
local loading = {}

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
  cleanup_group = vim.api.nvim_create_augroup('shortcut.buffer.epic', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = cleanup_group,
    pattern = 'shortcut://epic/*',
    desc = 'shortcut.nvim: cancel epic loads, drop snapshots',
    callback = function(ev)
      forget(ev.buf)
    end,
  })
end

--- The snapshot of a loaded epic buffer, or `nil`.
---@param buf? integer Defaults to the current buffer.
---@return shortcut.epic.Snapshot?
function M.snapshot(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return snapshots[buf]
end

--- `<CR>` in an epic buffer: open the `sc-<id>` on the cursor line in the current window. A
--- story of the epic opens directly; any other ID is looked up like `:e sc-<id>`. On a line
--- without one, `<CR>` does what it normally does.
function M.open_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local id = M.id_at(line, cursor[2])
  if not id then
    vim.cmd.normal({ vim.v.count1 .. vim.keycode('<CR>'), bang = true })
    return
  end
  local snap = snapshots[vim.api.nvim_get_current_buf()]
  local is_story = false
  for _, s in ipairs(snap and snap.meta.stories or {}) do
    if s.id == id then
      is_story = true
      break
    end
  end
  local ok, err = pcall(function()
    if is_story then
      require('shortcut.buffer.handlers').open('story', id)
    else
      local uri = require('shortcut.uri')
      vim.cmd.edit(vim.fn.fnameescape(uri.canonical('id', id)))
    end
  end)
  if not ok then
    require('shortcut.notify').error((tostring(err):gsub('^[^\n]-:%d+: ', '', 1)))
  end
end

--- Write a rendered epic into `buf`: lines, snapshot.
---@param buf integer
---@param epic table
---@param stories table[]
---@param refs shortcut.epic.Refs
---@return shortcut.epic.Snapshot
local function apply(buf, epic, stories, refs)
  local lines, meta = M.render(epic, stories, refs)
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
  ---@type shortcut.epic.Snapshot
  local snap = {
    epic = epic,
    stories = stories,
    updated_at = type(epic.updated_at) == 'string' and epic.updated_at or nil,
    lines = lines,
    meta = meta,
    refs = refs,
  }
  snapshots[buf] = snap
  return snap
end

--- A message for a failed fetch.
---@param id integer
---@param err shortcut.http.Error
---@return string
local function load_error(id, err)
  if err.status == 404 then
    return ('epic sc-%d not found (it may have been deleted, or be in another workspace)'):format(
      id
    )
  end
  if err.kind == 'auth' then
    return err.message
  end
  return require('shortcut.http').format_error(err)
end

--- Fetch an epic, its stories and the lookup lists, in parallel. `callback(err, epic, stories,
--- refs_err)` runs on the main loop: `err` is a message if the epic or its stories could not be
--- fetched; `refs_err` is set if the lookup lists are unavailable.
---@param id integer
---@param callback fun(err?: string, epic?: table, stories?: table[], refs_err?: shortcut.http.Error)
---@return { cancel: fun() }
function M.fetch(id, callback)
  local epics = require('shortcut.api.epics')
  local cache = require('shortcut.cache')
  local handles = {} ---@type { cancel: fun(self: any) }[]
  local cancelled, finished = false, false
  local pending = 3
  local epic, stories, refs_err ---@type table?, table[]?, shortcut.http.Error?

  local function cancel_all()
    for _, h in ipairs(handles) do
      pcall(h.cancel, h)
    end
  end

  ---@param err? string
  local function step(err)
    if cancelled or finished then
      return
    end
    if err then
      -- Nothing to render: don't wait for the rest.
      finished = true
      cancel_all()
      return callback(err)
    end
    pending = pending - 1
    if pending > 0 then
      return
    end
    finished = true
    callback(nil, epic, stories, refs_err)
  end

  table.insert(
    handles,
    epics.get(id, function(err, data)
      if err then
        return step(load_error(id, err))
      end
      if type(data) ~= 'table' or data.id == nil then
        return step(('unexpected response from GET /epics/%d'):format(id))
      end
      epic = data
      step()
    end)
  )
  table.insert(
    handles,
    epics.stories(id, function(err, data)
      if err then
        return step(load_error(id, err))
      end
      if type(data) ~= 'table' or not vim.islist(data) then
        return step(('unexpected response from GET /epics/%d/stories'):format(id))
      end
      stories = data
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
      cancel_all()
    end,
  }
end

--- Lookups from the cache.
---@return shortcut.epic.Refs
function M.cache_refs()
  local cache = require('shortcut.cache')
  return {
    epic_state = cache.epic_state,
    state = cache.state,
    member = cache.member,
    label = cache.label,
    group = cache.group,
  }
end

---@type shortcut.buffer.Handler
M.handler = {
  load = function(buf, id, _, done)
    ensure_cleanup()
    forget(buf)
    local handle
    handle = M.fetch(id, function(err, epic, stories, refs_err)
      if loading[buf] ~= handle then
        return
      end
      loading[buf] = nil
      if err then
        return done(err)
      end
      ---@cast epic table
      ---@cast stories table[]
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
      local ok, apply_err = pcall(apply, buf, epic, stories, M.cache_refs())
      if not ok then
        snapshots[buf] = nil
        -- Without the `file:line: ` prefix of the error.
        return done((tostring(apply_err):gsub('^[^\n]-:%d+: ', '', 1)))
      end
      vim.keymap.set('n', '<CR>', M.open_at_cursor, {
        buffer = buf,
        desc = 'shortcut.nvim: open the sc-<id> on this line',
      })
      done()
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
      end
    end)
    loading[buf] = handle
  end,

  save = function(_, _, _, done)
    done('editing epics is not available yet; the changes were not saved')
  end,
}

return M

--- What a save of a story buffer must send: the changes between the parse of the original render
--- and the parse of the edited buffer, with names turned back into IDs.
---
--- Comparing two parses (rather than the buffer with the API object) means rendering quirks
--- cancel out: only real edits are changes. A field whose parsed value is unchanged is never
--- looked up, so a value shown as `unknown-<id>` (an ID with no known name) can never turn into
--- a change by itself. A changed field is looked up, and if its IDs come out the same as the
--- story's (e.g. a name typed in another case, owners reordered) it is not a change either.
---
--- Every problem is collected, with its line; nothing may be sent if there is any.
---
--- Pure: names are resolved through the `lookup` functions given (`shortcut.cache`'s in the
--- editor), and no buffer or editor state is used.
local M = {}

---@class shortcut.story_diff.Lookup
---@field state_by_name fun(workflow_id: integer, name: string): shortcut.refs.State?, string?
---@field member_by_mention fun(mention: string): shortcut.refs.Member?, string?
---@field label_by_name fun(name: string): shortcut.refs.Label?, string?
---@field iteration_by_name fun(name: string): shortcut.refs.Iteration?, string?
---@field iteration fun(id: integer): shortcut.refs.Iteration?

---@class shortcut.story_diff.Context
---@field story table The story the original render was made from.
---@field lookup shortcut.story_diff.Lookup
---@field orig_tasks table<integer, integer> Line of the original render -> task ID.
---@field marks table<integer, integer> Line of the edited buffer -> task ID (its valid extmarks).
---@field invalid? table<integer, integer[]> Line of the edited buffer -> IDs of tasks whose extmark was invalidated (its line deleted) and now sits there.

---@class shortcut.story_diff.TaskUpdate
---@field id integer
---@field line integer
---@field description string The task's description in the buffer, for messages.
---@field fields table `UpdateTask` body.

---@class shortcut.story_diff.TaskCreate
---@field line integer
---@field fields table `CreateTask` body.

---@class shortcut.story_diff.TaskDelete
---@field id integer
---@field description string As rendered.

---@class shortcut.story_diff.Changes
---@field story table `UpdateStory` body: only the changed fields.
---@field fields string[] Names of the changed buffer fields (`title`, `description`, `state`, ...).
---@field epic? { id: integer, line: integer } A new epic, to check exists before saving.
---@field tasks { update: shortcut.story_diff.TaskUpdate[], create: shortcut.story_diff.TaskCreate[], delete: shortcut.story_diff.TaskDelete[] }

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

--- Whether two lists hold the same items, ignoring order and duplicates.
---@param a any[]
---@param b any[]
---@return boolean
local function same_set(a, b)
  local sa, sb = {}, {}
  for _, x in ipairs(a) do
    sa[x] = true
  end
  for _, x in ipairs(b) do
    sb[x] = true
  end
  for k in pairs(sa) do
    if not sb[k] then
      return false
    end
  end
  for k in pairs(sb) do
    if not sa[k] then
      return false
    end
  end
  return true
end

--- The ID in an `unknown-<id>` placeholder, or `nil`.
---@param name string
---@return string?
local function unknown_id(name)
  return name:match('^unknown%-(.+)$')
end

--- Whether a set of changes sends nothing.
---@param changes shortcut.story_diff.Changes
---@return boolean
function M.is_empty(changes)
  local t = changes.tasks
  return next(changes.story) == nil
    and changes.epic == nil
    and #t.update == 0
    and #t.create == 0
    and #t.delete == 0
end

--- Member IDs of mention names. `unknown-<id>` stands for an ID in `known` (members the story
--- already refers to). Members who are disabled are an error unless they are in `current`.
---@param mentions string[]
---@param lookup shortcut.story_diff.Lookup
---@param known table<string, true>
---@param current string[] IDs the field had.
---@param err fun(msg: string)
---@return string[]? ids `nil` if any could not be resolved.
local function member_ids(mentions, lookup, known, current, err)
  local ids, seen, ok = {}, {}, true
  local had = {}
  for _, id in ipairs(current) do
    had[id] = true
  end
  for _, mention in ipairs(mentions) do
    local id = unknown_id(mention)
    if not (id and known[id]) then
      local member, lookup_err = lookup.member_by_mention(mention)
      if not member then
        err(lookup_err or ("unknown member '@%s'"):format(mention))
        ok = false
      elseif member.disabled and not had[member.id] then
        err(("member '@%s' is disabled in the workspace"):format(member.mention_name))
        ok = false
      else
        id = member.id
      end
    end
    if ok and id and not seen[id] then
      seen[id] = true
      table.insert(ids, id)
    end
  end
  return ok and ids or nil
end

--- Compute the changes, and the problems that keep them from being sent.
---@param orig shortcut.story_parse.Story The parse of the original render.
---@param cur shortcut.story_parse.Story The parse of the edited buffer.
---@param ctx shortcut.story_diff.Context
---@return shortcut.story_diff.Changes changes
---@return shortcut.story_parse.Error[] errors Sorted by line.
function M.diff(orig, cur, ctx)
  local s = ctx.story
  local lookup = ctx.lookup
  local errors = {} ---@type shortcut.story_parse.Error[]
  ---@type shortcut.story_diff.Changes
  local changes = { story = {}, fields = {}, tasks = { update = {}, create = {}, delete = {} } }
  local body = changes.story
  local oh, ch = orig.header, cur.header

  ---@param line integer
  ---@param msg string
  local function err(line, msg)
    table.insert(errors, { line = line, message = msg })
  end
  ---@param key string
  ---@return fun(msg: string)
  local function field_err(key)
    return function(msg)
      err(cur.key_lines[key] or cur.header_end, ('%s: %s'):format(key, msg))
    end
  end
  ---@param key string
  ---@return boolean
  local function changed(key)
    return not vim.deep_equal(oh[key], ch[key])
  end
  ---@param name string
  local function mark(name)
    table.insert(changes.fields, name)
  end

  -- Every member the story refers to: `unknown-<id>` may stand for these.
  local known_members = {} ---@type table<string, true>
  for _, id in ipairs(list_of(s.owner_ids)) do
    known_members[tostring(id)] = true
  end
  for _, t in ipairs(list_of(s.tasks)) do
    for _, id in ipairs(type(t) == 'table' and list_of(t.owner_ids) or {}) do
      known_members[tostring(id)] = true
    end
  end

  for _, key in ipairs({ 'id', 'url' }) do
    if changed(key) then
      field_err(key)('read-only: it cannot be changed (undo the edit, or :e! to reload)')
    end
  end

  if cur.title ~= orig.title then
    body.name = cur.title
    mark('title')
  end
  if cur.description ~= orig.description then
    body.description = cur.description
    mark('description')
  end

  if changed('type') and ch.type then
    body.story_type = ch.type
    mark('type')
  end

  if changed('state') and ch.state then
    local state, lookup_err = lookup.state_by_name(s.workflow_id, ch.state)
    if not state then
      field_err('state')(lookup_err or ("unknown state '%s'"):format(ch.state))
    elseif state.id ~= s.workflow_state_id then
      body.workflow_state_id = state.id
      mark('state')
    end
  end

  if changed('owners') then
    local current = vim.tbl_map(tostring, list_of(s.owner_ids))
    local ids = member_ids(ch.owners, lookup, known_members, current, field_err('owners'))
    if ids and not same_set(ids, current) then
      body.owner_ids = ids
      mark('owners')
    end
  end

  if changed('epic') then
    local id = ch.epic and ch.epic.id
    local old = present(s.epic_id) and s.epic_id or nil
    if id ~= old then
      body.epic_id = id or vim.NIL
      mark('epic')
      if id then
        changes.epic = { id = id, line = cur.key_lines.epic or cur.header_end }
      end
    end
  end

  if changed('iteration') then
    local v = ch.iteration
    local old = present(s.iteration_id) and s.iteration_id or nil
    local id ---@type integer?
    local ok = true
    if v == nil or v == '' then
      id = nil
    elseif type(v) == 'number' and lookup.iteration(v) then
      id = v
    else
      local it, lookup_err = lookup.iteration_by_name(tostring(v))
      if it then
        id = it.id
      else
        ok = false
        field_err('iteration')(lookup_err or ("unknown iteration '%s'"):format(tostring(v)))
      end
    end
    if ok and id ~= old then
      body.iteration_id = id or vim.NIL
      mark('iteration')
    end
  end

  if changed('estimate') then
    local old = present(s.estimate) and s.estimate or nil
    if ch.estimate ~= old then
      body.estimate = ch.estimate or vim.NIL
      mark('estimate')
    end
  end

  if changed('labels') then
    local e = field_err('labels')
    -- The story's own labels first: they are known even if the cache is out of date.
    local own = {} ---@type table<string, { id: integer, name: string }>
    for _, l in ipairs(list_of(s.labels)) do
      if type(l) == 'table' and present(l.id) and type(l.name) == 'string' then
        own[l.name:lower()] = own[l.name:lower()] or l
      end
    end
    local names, ids, seen, ok = {}, {}, {}, true
    for _, name in ipairs(ch.labels) do
      local label, lookup_err = own[name:lower()], nil ---@type { id: integer, name: string }?, string?
      if not label then
        label, lookup_err = lookup.label_by_name(name)
      end
      if not label then
        ok = false
        if unknown_id(name) then
          e(
            ("label '%s' has no known name, so the labels cannot be saved; remove it or :e! to reload"):format(
              name
            )
          )
        else
          -- Saving labels by name creates missing ones: refuse instead.
          e(lookup_err or ("unknown label '%s'"):format(name))
        end
      elseif not seen[label.id] then
        seen[label.id] = true
        table.insert(ids, label.id)
        table.insert(names, { name = label.name })
      end
    end
    local current = list_of(s.label_ids)
    if type(s.label_ids) ~= 'table' then
      current = vim.tbl_map(function(l)
        return l.id
      end, list_of(s.labels))
    end
    if ok and not same_set(ids, current) then
      body.labels = names
      mark('labels')
    end
  end

  -- Tasks: matched by their extmarks.
  local orig_by_id = {} ---@type table<integer, shortcut.story_parse.Task>
  for _, t in ipairs(orig.tasks) do
    local id = ctx.orig_tasks[t.line]
    if id then
      orig_by_id[id] = t
    end
  end
  local task_owner_ids = {} ---@type table<integer, string[]>
  for _, t in ipairs(list_of(s.tasks)) do
    if type(t) == 'table' and present(t.id) then
      task_owner_ids[t.id] = vim.tbl_map(tostring, list_of(t.owner_ids))
    end
  end

  -- Which task each line is: its valid mark, if any. A line without one is matched to a task
  -- that lost its mark (its line was deleted) if the text is that task's description and the
  -- match is unambiguous: replacing a line with `nvim_buf_set_lines()` (as checkbox-toggling
  -- plugins do), `:sort` or `ddp` then don't read as a deleted task plus a new one.
  local kept = {} ---@type table<integer, true>
  local match = {} ---@type table<shortcut.story_parse.Task, integer>
  for _, t in ipairs(cur.tasks) do
    local id = ctx.marks[t.line]
    if id and not kept[id] and orig_by_id[id] then
      kept[id] = true
      match[t] = id
    end
  end
  ---@param t shortcut.story_parse.Task
  ---@param id integer
  ---@return boolean
  local function orphan_of(t, id)
    local o = orig_by_id[id]
    return not kept[id] and o ~= nil and o.description == t.description
  end
  -- The task whose invalidated mark sits on the line.
  for _, t in ipairs(cur.tasks) do
    if not match[t] then
      local found = vim.tbl_filter(function(id)
        return orphan_of(t, id)
      end, (ctx.invalid or {})[t.line] or {})
      if #found == 1 then
        kept[found[1]] = true
        match[t] = found[1]
      end
    end
  end
  -- The only task left with that description, for the only line left with it.
  local lines_by_text, tasks_by_text = {}, {} ---@type table<string, shortcut.story_parse.Task[]>, table<string, integer[]>
  for _, t in ipairs(cur.tasks) do
    if not match[t] then
      lines_by_text[t.description] = lines_by_text[t.description] or {}
      table.insert(lines_by_text[t.description], t)
    end
  end
  for _, t in ipairs(orig.tasks) do
    local id = ctx.orig_tasks[t.line]
    if id and not kept[id] then
      tasks_by_text[t.description] = tasks_by_text[t.description] or {}
      table.insert(tasks_by_text[t.description], id)
    end
  end
  for text, ts in pairs(lines_by_text) do
    local ids = tasks_by_text[text]
    if #ts == 1 and ids and #ids == 1 then
      kept[ids[1]] = true
      match[ts[1]] = ids[1]
    end
  end

  for _, t in ipairs(cur.tasks) do
    local e = function(msg)
      err(t.line, msg)
    end
    local id = match[t]
    local o = id and orig_by_id[id]
    if o then
      ---@cast id integer
      local fields = {}
      if t.complete ~= o.complete then
        fields.complete = t.complete
      end
      if t.description ~= o.description then
        fields.description = t.description
      end
      if not vim.deep_equal(t.owners, o.owners) then
        local current = task_owner_ids[id] or {}
        local ids = member_ids(t.owners, lookup, known_members, current, e)
        if ids and not same_set(ids, current) then
          fields.owner_ids = ids
        end
      end
      if next(fields) then
        table.insert(
          changes.tasks.update,
          { id = id, line = t.line, description = t.description, fields = fields }
        )
      end
    else
      local fields = { description = t.description, complete = t.complete }
      if #t.owners > 0 then
        fields.owner_ids = member_ids(t.owners, lookup, known_members, {}, e)
      end
      table.insert(changes.tasks.create, { line = t.line, fields = fields })
    end
  end
  for _, t in ipairs(orig.tasks) do
    local id = ctx.orig_tasks[t.line]
    if id and not kept[id] then
      table.insert(changes.tasks.delete, { id = id, description = t.description })
    end
  end

  table.sort(errors, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.message < b.message
  end)
  return changes, errors
end

--- A short description of the changes, e.g. `title, state, 1 task updated, 2 tasks deleted`.
---@param changes shortcut.story_diff.Changes
---@return string
function M.summary(changes)
  local parts = vim.deepcopy(changes.fields)
  for _, kind in ipairs({ 'update', 'create', 'delete' }) do
    local n = #changes.tasks[kind]
    if n > 0 then
      local verb = ({ update = 'updated', create = 'added', delete = 'deleted' })[kind]
      table.insert(parts, ('%d task%s %s'):format(n, n == 1 and '' or 's', verb))
    end
  end
  return table.concat(parts, ', ')
end

return M

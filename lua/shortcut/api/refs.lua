--- The workspace's lookup lists: what stories and epics refer to by ID.
---
--- `fetch()` returns the raw responses; `slim()` keeps the fields the plugin uses, which is what
--- `shortcut.cache` stores (notably not members' email addresses).
---
--- API facts (OpenAPI spec, see `shortcut.api`):
---   - `GET /workflows` (listWorkflows): `Workflow[]`, each with `states` (`WorkflowState`:
---     `id`, `name`, `type`, `position`, optional `color`). `type` is `unstarted`, `started` or
---     `done`. State names are unique only within a workflow; a workflow belongs to a team
---     (`team_id`), and groups list theirs in `workflow_ids`.
---   - `GET /epic-workflow` (getEpicWorkflow): one `EpicWorkflow` object (not a list) with
---     `epic_states` (`EpicState`: `id`, `name`, `type`, `position`) and
---     `default_epic_state_id`.
---   - `GET /members` (listMembers): `Member[]`. Unlike `GET /member` (`MemberInfo`, which has
---     `mention_name` at the top level), the mention name and display name are nested:
---     `profile.mention_name`, `profile.name`. `disabled` is on the member (disabled in the
---     workspace), `profile.deactivated` on the profile. All members are returned unless the
---     `disabled` query parameter filters them.
---   - `GET /labels` (listLabels): `Label[]`; `slim=true` leaves out `stats`. `archived` flags
---     archived labels.
---   - `GET /groups` (listGroups): `Group[]` (teams): `id` is a UUID, plus `name`,
---     `mention_name`, `archived`, `workflow_ids`, `member_ids`. All groups are returned unless
---     `archived` filters them.
---   - `GET /iterations` (listIterations): `IterationSlim[]`: `id`, `name`, `status`
---     (`unstarted`, `started` or `done`), `start_date`, `end_date`. Names need not be unique.
---   - Workflow states, epic states, labels and iterations have integer IDs; members and groups
---     have UUIDs.
local http = require('shortcut.http')

local M = {}

---@alias shortcut.refs.Kind 'workflows'|'epic_workflow'|'members'|'labels'|'groups'|'iterations'

---@type shortcut.refs.Kind[]
M.KINDS = { 'workflows', 'epic_workflow', 'members', 'labels', 'groups', 'iterations' }

---@type table<shortcut.refs.Kind, { path: string, query?: table<string, shortcut.http.QueryValue> }>
local ENDPOINTS = {
  workflows = { path = '/workflows' },
  epic_workflow = { path = '/epic-workflow' },
  members = { path = '/members' },
  labels = { path = '/labels', query = { slim = true } },
  groups = { path = '/groups' },
  iterations = { path = '/iterations' },
}

---@param kind any
---@return boolean
function M.is_kind(kind)
  return type(kind) == 'string' and ENDPOINTS[kind] ~= nil
end

---@param kind shortcut.refs.Kind
---@return string
function M.path(kind)
  return ENDPOINTS[kind].path
end

--- Fetch a list as the API returns it.
---@param kind shortcut.refs.Kind
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.fetch(kind, callback)
  vim.validate('kind', kind, M.is_kind, 'lookup list kind')
  local e = ENDPOINTS[kind]
  return http.request({ path = e.path, query = e.query }, callback)
end

--- `GET /workflows`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.workflows(callback)
  return M.fetch('workflows', callback)
end

--- `GET /epic-workflow`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.epic_workflow(callback)
  return M.fetch('epic_workflow', callback)
end

--- `GET /members`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.members(callback)
  return M.fetch('members', callback)
end

--- `GET /labels?slim=true`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.labels(callback)
  return M.fetch('labels', callback)
end

--- `GET /groups`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.groups(callback)
  return M.fetch('groups', callback)
end

--- `GET /iterations`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.iterations(callback)
  return M.fetch('iterations', callback)
end

---------------------------------------------------------------------------------------------------
-- Slim records
---------------------------------------------------------------------------------------------------

---@class shortcut.refs.State
---@field id integer
---@field name string
---@field type string `unstarted`, `started` or `done`.
---@field position integer
---@field color? string
---@field workflow_id integer

---@class shortcut.refs.Workflow
---@field id integer
---@field name string
---@field team_id? integer
---@field default_state_id? integer
---@field states shortcut.refs.State[] Sorted by position.

---@class shortcut.refs.EpicState
---@field id integer
---@field name string
---@field type string `unstarted`, `started` or `done`.
---@field position integer
---@field color? string

---@class shortcut.refs.EpicWorkflow
---@field id integer
---@field default_epic_state_id? integer
---@field epic_states shortcut.refs.EpicState[] Sorted by position.

---@class shortcut.refs.Member
---@field id string UUID.
---@field mention_name string
---@field name? string
---@field disabled boolean Disabled in the workspace, or deactivated.
---@field role? string

---@class shortcut.refs.Label
---@field id integer
---@field name string
---@field color? string
---@field archived boolean

---@class shortcut.refs.Group
---@field id string UUID.
---@field name string
---@field mention_name? string
---@field archived boolean
---@field workflow_ids integer[]
---@field default_workflow_id? integer
---@field member_ids string[]

---@class shortcut.refs.Iteration
---@field id integer
---@field name string
---@field status? string `unstarted`, `started` or `done`.
---@field start_date? string
---@field end_date? string

---@param v any
---@return string?
local function str(v)
  return type(v) == 'string' and v or nil
end

---@param v any
---@return integer?
local function int(v)
  return type(v) == 'number' and v == math.floor(v) and v or nil
end

---@param v any
---@param check fun(x: any): any
---@return any[]
local function list_of(v, check)
  local out = {}
  for _, x in ipairs(type(v) == 'table' and v or {}) do
    if check(x) ~= nil then
      table.insert(out, x)
    end
  end
  return out
end

---@param a { position: integer, id: integer }
---@param b { position: integer, id: integer }
local function by_position(a, b)
  if a.position ~= b.position then
    return a.position < b.position
  end
  return a.id < b.id
end

---@param s table
---@return shortcut.refs.EpicState?
local function state_fields(s)
  if type(s) ~= 'table' or not int(s.id) or not str(s.name) then
    return nil
  end
  return {
    id = s.id,
    name = s.name,
    type = str(s.type) or '',
    position = int(s.position) or 0,
    color = str(s.color),
  }
end

---@type table<shortcut.refs.Kind, fun(item: table): table?>
local SLIM_ITEM = {
  workflows = function(w)
    if not int(w.id) then
      return nil
    end
    local states = {}
    for _, s in ipairs(type(w.states) == 'table' and w.states or {}) do
      local state = state_fields(s) --[[@as shortcut.refs.State?]]
      if state then
        state.workflow_id = w.id
        table.insert(states, state)
      end
    end
    table.sort(states, by_position)
    ---@type shortcut.refs.Workflow
    return {
      id = w.id,
      name = str(w.name) or tostring(w.id),
      team_id = int(w.team_id),
      default_state_id = int(w.default_state_id),
      states = states,
    }
  end,
  members = function(m)
    local profile = type(m.profile) == 'table' and m.profile or {}
    if not str(m.id) or not str(profile.mention_name) then
      return nil
    end
    ---@type shortcut.refs.Member
    return {
      id = m.id,
      mention_name = profile.mention_name,
      name = str(profile.name),
      disabled = m.disabled == true or profile.deactivated == true,
      role = str(m.role),
    }
  end,
  labels = function(l)
    if not int(l.id) or not str(l.name) then
      return nil
    end
    ---@type shortcut.refs.Label
    return { id = l.id, name = l.name, color = str(l.color), archived = l.archived == true }
  end,
  groups = function(g)
    if not str(g.id) or not str(g.name) then
      return nil
    end
    ---@type shortcut.refs.Group
    return {
      id = g.id,
      name = g.name,
      mention_name = str(g.mention_name),
      archived = g.archived == true,
      workflow_ids = list_of(g.workflow_ids, int),
      default_workflow_id = int(g.default_workflow_id),
      member_ids = list_of(g.member_ids, str),
    }
  end,
  iterations = function(i)
    if not int(i.id) or not str(i.name) then
      return nil
    end
    ---@type shortcut.refs.Iteration
    return {
      id = i.id,
      name = i.name,
      status = str(i.status),
      start_date = str(i.start_date),
      end_date = str(i.end_date),
    }
  end,
}

--- Keep only the fields the plugin uses. Malformed entries are dropped.
---@param kind shortcut.refs.Kind
---@param data any The decoded response of `fetch(kind)`.
---@return any? slim A list, or for `epic_workflow` a `shortcut.refs.EpicWorkflow`.
---@return string? err If `data` does not have the expected shape.
function M.slim(kind, data)
  vim.validate('kind', kind, M.is_kind, 'lookup list kind')
  if type(data) ~= 'table' then
    return nil, ('unexpected response from GET %s'):format(M.path(kind))
  end
  if kind == 'epic_workflow' then
    if not int(data.id) then
      return nil, ('unexpected response from GET %s'):format(M.path(kind))
    end
    local states = {}
    for _, s in ipairs(type(data.epic_states) == 'table' and data.epic_states or {}) do
      local state = state_fields(s)
      if state then
        table.insert(states, state)
      end
    end
    table.sort(states, by_position)
    ---@type shortcut.refs.EpicWorkflow
    return {
      id = data.id,
      default_epic_state_id = int(data.default_epic_state_id),
      epic_states = states,
    }
  end
  if not vim.islist(data) then
    return nil, ('unexpected response from GET %s'):format(M.path(kind))
  end
  local out = {}
  for _, item in ipairs(data) do
    local slim = type(item) == 'table' and SLIM_ITEM[kind](item) or nil
    if slim then
      table.insert(out, slim)
    end
  end
  return out
end

return M

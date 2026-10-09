--- Epics.
---
--- API facts (OpenAPI spec, see `shortcut.api`):
---   - `GET /epics/{id}` (getEpic) returns an `Epic`: `epic_state_id` (an `EpicState` of the
---     single epic workflow, `GET /epic-workflow`), `owner_ids`, `group_ids` (`group_id` is
---     deprecated), `label_ids`/`labels`, `objective_ids`, threaded `comments`.
---   - `PUT /epics/{id}` (updateEpic) takes `UpdateEpic`; like stories, labels are set with
---     `labels` (`CreateLabelParams`), not `label_ids`. The state is `epic_state_id` (`state` is
---     deprecated).
---   - `GET /epics/{id}/stories` (listEpicStories) returns `StorySlim[]`, without descriptions
---     unless `includes_description=true`.
---   - Epics and stories share one public-ID space (see `shortcut.buffer.handlers`), so an ID
---     names at most one of them.
local api = require('shortcut.api')
local http = require('shortcut.http')

local M = {}

---@param id integer
---@return string
local function epic_path(id)
  api.check_id('id', id)
  return ('/epics/%d'):format(id)
end

--- `GET /epics/{id}`.
---@param id integer
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.get(id, callback)
  return http.request({ path = epic_path(id) }, callback)
end

--- `PUT /epics/{id}`. Use `vim.NIL` to clear a field.
---@param id integer
---@param fields table `UpdateEpic`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.update(id, fields, callback)
  return http.request({ method = 'PUT', path = epic_path(id), body = api.body(fields) }, callback)
end

--- `GET /epics/{id}/stories`: the epic's stories (`StorySlim`, no descriptions).
---@param id integer
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.stories(id, callback)
  return http.request({ path = epic_path(id) .. '/stories' }, callback)
end

return M

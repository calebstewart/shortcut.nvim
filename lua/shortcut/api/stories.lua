--- Stories, their comments and their tasks.
---
--- API facts (OpenAPI spec, see `shortcut.api`):
---   - `GET /stories/{id}` (getStory) returns a full `Story`, including `tasks`, `comments`,
---     `labels` (`LabelSlim`) and `label_ids`, `owner_ids`, `workflow_state_id`, `epic_id`,
---     `iteration_id` and `group_id`.
---   - `PUT /stories/{id}` (updateStory) takes `UpdateStory`; every field is optional and a
---     nullable field (`epic_id`, `iteration_id`, `group_id`, `estimate`, `deadline`, ...) is
---     cleared with `null` (`vim.NIL`). **Labels are set with `labels`, a list of
---     `CreateLabelParams` (`{ name = ... }`, created if missing): `UpdateStory` has no
---     `label_ids`.** The list replaces the story's labels. Owners are `owner_ids` (member UUIDs).
---   - `POST /stories` (createStory) takes `CreateStoryParams` (`name` required) and answers 201
---     with the `Story`.
---   - `POST /stories/{id}/comments` (createStoryComment): `CreateStoryComment`, `text`
---     required; 201 with the `StoryComment`.
---   - `POST /stories/{id}/tasks` (createTask): `CreateTask`, `description` required, `complete`
---     optional; 201 with the `Task`.
---   - `PUT /stories/{id}/tasks/{task-id}` (updateTask): `UpdateTask` (`description`,
---     `complete`, `owner_ids`, `before_id`, `after_id`); 200 with the `Task`.
---   - `DELETE /stories/{id}/tasks/{task-id}` (deleteTask): 204, no body.
local api = require('shortcut.api')
local http = require('shortcut.http')

local M = {}

---@alias shortcut.api.Callback fun(err?: shortcut.http.Error, data?: any, response?: shortcut.http.Response)

---@param id integer
---@return string
local function story_path(id)
  api.check_id('id', id)
  return ('/stories/%d'):format(id)
end

--- `GET /stories/{id}`.
---@param id integer
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.get(id, callback)
  return http.request({ path = story_path(id) }, callback)
end

--- `PUT /stories/{id}`. Use `vim.NIL` to clear a field; see the module comment for labels.
---@param id integer
---@param fields table `UpdateStory`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.update(id, fields, callback)
  return http.request({ method = 'PUT', path = story_path(id), body = api.body(fields) }, callback)
end

--- `POST /stories`.
---@param fields table `CreateStoryParams`; `name` is required.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.create(fields, callback)
  vim.validate('fields', fields, 'table')
  if type(fields.name) ~= 'string' or vim.trim(fields.name) == '' then
    return http.reject('POST', '/stories', 'a story needs a name', callback)
  end
  return http.request({ method = 'POST', path = '/stories', body = fields }, callback)
end

M.comments = {}

--- `POST /stories/{id}/comments`.
---@param story_id integer
---@param fields { text: string }|table `CreateStoryComment`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.comments.create(story_id, fields, callback)
  local path = story_path(story_id) .. '/comments'
  vim.validate('fields', fields, 'table')
  if type(fields.text) ~= 'string' or vim.trim(fields.text) == '' then
    return http.reject('POST', path, 'a comment cannot be empty', callback)
  end
  return http.request({ method = 'POST', path = path, body = fields }, callback)
end

M.tasks = {}

---@param story_id integer
---@param task_id integer
---@return string
local function task_path(story_id, task_id)
  api.check_id('task_id', task_id)
  return ('%s/tasks/%d'):format(story_path(story_id), task_id)
end

--- `POST /stories/{id}/tasks`.
---@param story_id integer
---@param fields { description: string, complete?: boolean }|table `CreateTask`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.tasks.create(story_id, fields, callback)
  local path = story_path(story_id) .. '/tasks'
  vim.validate('fields', fields, 'table')
  if type(fields.description) ~= 'string' or vim.trim(fields.description) == '' then
    return http.reject('POST', path, 'a task needs a description', callback)
  end
  return http.request({ method = 'POST', path = path, body = fields }, callback)
end

--- `PUT /stories/{id}/tasks/{task_id}`.
---@param story_id integer
---@param task_id integer
---@param fields table `UpdateTask`.
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.tasks.update(story_id, task_id, fields, callback)
  return http.request(
    { method = 'PUT', path = task_path(story_id, task_id), body = api.body(fields) },
    callback
  )
end

--- `DELETE /stories/{id}/tasks/{task_id}`. `data` is `nil` on success (204).
---@param story_id integer
---@param task_id integer
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.tasks.delete(story_id, task_id, callback)
  return http.request({ method = 'DELETE', path = task_path(story_id, task_id) }, callback)
end

return M

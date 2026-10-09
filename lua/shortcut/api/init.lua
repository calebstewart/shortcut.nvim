--- Thin wrappers for the Shortcut REST API v3 endpoints the plugin uses.
---
--- - `shortcut.api.stories`: stories, their comments and tasks,
--- - `shortcut.api.epics`: epics and their stories,
--- - `shortcut.api.search`: story/epic search, with a page streamer,
--- - `shortcut.api.refs`: the workspace's lookup lists (see `shortcut.cache`).
---
--- Every function takes a callback as its last argument, `callback(err, data, response)` as in
--- `shortcut.http.request()`, and returns a handle with a `cancel()` method, so it can be used
--- with `shortcut.async.await()`:
---
--- ```lua
--- local err, story = async.await(require('shortcut.api.stories').get, 123)
--- ```
---
--- Paths, methods and bodies follow the OpenAPI spec,
--- https://developer.shortcut.com/api/rest/v3/shortcut.openapi.json (operation IDs are given
--- with each function).
local M = {}

--- Check that `id` is a public ID: a positive integer, at most `shortcut.uri.MAX_ID` (the
--- bound IDs in buffer names and links are parsed with). Raises an error otherwise: passing
--- anything else is a bug in the caller.
---@param name string Argument name, for the error message.
---@param id any
function M.check_id(name, id)
  local max = require('shortcut.uri').MAX_ID
  vim.validate(name, id, function(v)
    return type(v) == 'number' and v > 0 and v == math.floor(v) and v <= max
  end, 'positive integer')
end

--- A JSON body for a create/update: `fields` as given (`vim.NIL` encodes as `null`, which clears
--- a field), and `{}` rather than `[]` when it is empty.
---@param fields table
---@return table|string
function M.body(fields)
  vim.validate('fields', fields, 'table')
  if next(fields) == nil then
    return '{}'
  end
  return fields
end

return M

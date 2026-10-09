--- Plugin configuration: defaults, validation and access.
---
--- Other modules must read configuration through `config.get()` only.
local notify = require('shortcut.notify')

local M = {}

---@class shortcut.Config
---@field token? string|fun(): string API token, or a function returning one.
---@field cli_config_path? string Override for the `short` CLI's config.json location.
---@field cache shortcut.Config.Cache
---@field sc_ids boolean Allow `:e sc-<id>` to open stories/epics.
---@field picker shortcut.Config.Picker
---@field http shortcut.Config.Http
---@field tasks shortcut.Config.Tasks
---@field create shortcut.Config.Create

---@class shortcut.Config.Cache
---@field ttl integer Lookup-list cache lifetime, in seconds.

---@class shortcut.Config.Picker
---@field page_size integer Results requested per search page (the API allows 1 to 250).
---@field max_results integer Maximum results streamed into a picker.

---@class shortcut.Config.Http
---@field timeout integer Request timeout, in seconds.

---@class shortcut.Config.Tasks
---@field show_owners boolean Show task owners as a trailing ` · @mention ...` on task lines.
---@field confirm_delete boolean Ask before a save deletes tasks.

--- Defaults of `:Shortcut create` (see `shortcut.buffer.story_create`).
---@class shortcut.Config.Create
---@field workflow? string|integer Workflow (name or ID) of new stories. Default: the team's default workflow if `team` is set, else the workspace's default workflow.
---@field team? string Team (group) to assign new stories to, by name, mention name or ID.
---@field template? fun(fields: shortcut.create.Fields): shortcut.create.Fields? Customizes the template's fields (it may change the table it is given, or return a new one).

---@type shortcut.Config
local defaults = {
  token = nil,
  cli_config_path = nil,
  cache = { ttl = 24 * 60 * 60 },
  sc_ids = true,
  picker = { page_size = 25, max_results = 200 },
  http = { timeout = 30 },
  tasks = { show_owners = true, confirm_delete = true },
  create = { workflow = nil, team = nil, template = nil },
}

---@param v any
---@return boolean
local function positive_integer(v)
  return type(v) == 'number' and v > 0 and v == math.floor(v)
end

--- Validation schema. A leaf is a list `{ validator, optional?, message? }` passed to
--- `vim.validate`; any other table is a nested section. Keys with a `nil` default must still
--- appear here, which is also how unknown keys are detected.
local schema = {
  token = { { 'string', 'function' }, true },
  cli_config_path = { 'string', true },
  cache = {
    ttl = { positive_integer, false, 'positive integer (seconds)' },
  },
  sc_ids = { 'boolean' },
  picker = {
    page_size = {
      function(v)
        return positive_integer(v) and v <= 250
      end,
      false,
      'integer from 1 to 250',
    },
    max_results = { positive_integer, false, 'positive integer' },
  },
  http = {
    timeout = { positive_integer, false, 'positive integer (seconds)' },
  },
  tasks = {
    show_owners = { 'boolean' },
    confirm_delete = { 'boolean' },
  },
  create = {
    workflow = {
      function(v)
        return v == nil or (type(v) == 'string' and v ~= '') or positive_integer(v)
      end,
      true,
      'workflow name or ID',
    },
    team = {
      function(v)
        return v == nil or (type(v) == 'string' and v ~= '')
      end,
      true,
      'team name, mention name or ID',
    },
    template = { 'function', true },
  },
}

---@param spec table
---@return boolean
local function is_leaf(spec)
  return spec[1] ~= nil
end

---@param opts table
---@param section table
---@param prefix string
---@param errors string[]
---@param warnings string[]
local function check(opts, section, prefix, errors, warnings)
  for key, value in pairs(opts) do
    local path = prefix .. tostring(key)
    local spec = section[key]
    if spec == nil then
      table.insert(warnings, ("unknown option '%s'"):format(path))
    elseif is_leaf(spec) then
      local ok, err = pcall(vim.validate, path, value, spec[1], spec[2], spec[3])
      if not ok then
        table.insert(errors, tostring(err))
      end
    elseif type(value) ~= 'table' then
      table.insert(errors, ('%s: expected table, got %s'):format(path, type(value)))
    else
      check(value, spec, path .. '.', errors, warnings)
    end
  end
end

---@type shortcut.Config?
local current = nil

--- Validate `opts` and merge them over the defaults. Each call starts again from the defaults,
--- so calling `setup()` twice does not accumulate options.
---
--- Invalid options are reported and leave the previous configuration in place. Unknown keys
--- only produce a warning, since they are most likely typos.
---@param opts? table
---@return boolean ok
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then
    notify.error(('setup() expects a table, got %s'):format(type(opts)))
    return false
  end

  local errors, warnings = {}, {}
  check(opts, schema, '', errors, warnings)
  table.sort(errors)
  table.sort(warnings)

  for _, w in ipairs(warnings) do
    notify.warn(w)
  end
  if #errors > 0 then
    notify.error('invalid configuration:\n- ' .. table.concat(errors, '\n- '))
    return false
  end

  current = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)

  -- The sc-<id> handler is registered at startup with the defaults; apply `sc_ids` now. (Not
  -- loaded yet only if the plugin file hasn't run, in which case it reads this config.)
  local handlers = package.loaded['shortcut.buffer.handlers']
  if handlers then
    handlers.sync_sc_ids(current.sc_ids)
  end
  return true
end

--- The active configuration. Defaults apply if `setup()` was never called.
---@return shortcut.Config
function M.get()
  if not current then
    current = vim.deepcopy(defaults)
  end
  return current
end

--- Every option, as a dotted path (`cache.ttl`), sorted. (The documentation is checked against
--- this.)
---@return string[]
function M.option_names()
  local names = {}
  local function walk(section, prefix)
    for key, spec in pairs(section) do
      if is_leaf(spec) then
        table.insert(names, prefix .. key)
      else
        walk(spec, prefix .. key .. '.')
      end
    end
  end
  walk(schema, '')
  table.sort(names)
  return names
end

--- Forget any configuration (for tests).
function M._reset()
  current = nil
end

return M

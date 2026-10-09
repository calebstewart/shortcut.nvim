--- The `:Shortcut {subcommand} [args...]` command: a subcommand registry plus dispatch and
--- completion.
---
--- Feature modules register their subcommands with `register()`. So that startup stays cheap,
--- they are not required up front: list them in `M.lazy` (name -> module + description), and
--- the module is required the first time the subcommand runs or completes. On load, the module
--- must call `register()` for the same name.
local notify = require('shortcut.notify')

local M = {}

---@class shortcut.Subcommand
---@field desc string One-line description shown in `:Shortcut help`.
---@field run fun(args: string[], cmd: vim.api.keyset.create_user_command.command_args)
---@field complete? fun(arglead: string, args: string[]): string[] `args` are the arguments
--- already typed after the subcommand, excluding the one being completed.

---@class shortcut.LazySubcommand
---@field module string Module that registers the subcommand when required.
---@field desc string

--- Subcommands provided by feature modules that are loaded on first use.
---@type table<string, shortcut.LazySubcommand>
M.lazy = {
  story = { module = 'shortcut.buffer.commands', desc = 'Open a story by ID, sc-<id> or URL' },
  epic = { module = 'shortcut.buffer.commands', desc = 'Open an epic by ID, sc-<id> or URL' },
  login = { module = 'shortcut.login', desc = 'Save an API token to the shared `short` CLI config' },
  search = { module = 'shortcut.picker', desc = 'Search stories (live with snacks.nvim)' },
  mine = { module = 'shortcut.picker', desc = 'Your unfinished stories' },
  epics = { module = 'shortcut.picker', desc = 'Search epics (live with snacks.nvim)' },
}

---@type table<string, shortcut.Subcommand>
local registry = {}

---@param name string
---@param spec shortcut.Subcommand
function M.register(name, spec)
  vim.validate('name', name, 'string')
  vim.validate('spec', spec, 'table')
  vim.validate('spec.desc', spec.desc, 'string')
  vim.validate('spec.run', spec.run, 'function')
  vim.validate('spec.complete', spec.complete, 'function', true)
  registry[name] = spec
end

--- Look up a subcommand, requiring its module if it is lazily provided.
---@param name string
---@return shortcut.Subcommand?
function M.get(name)
  if registry[name] then
    return registry[name]
  end
  local lazy = M.lazy[name]
  if not lazy then
    return nil
  end
  require(lazy.module)
  if not registry[name] then
    error(("module '%s' did not register subcommand '%s'"):format(lazy.module, name), 0)
  end
  return registry[name]
end

--- All known subcommand names, sorted.
---@return string[]
function M.names()
  local seen, names = {}, {}
  for _, tbl in ipairs({ registry, M.lazy }) do
    for name in pairs(tbl) do
      if not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
  end
  table.sort(names)
  return names
end

---@return string
function M.help_text()
  local names = M.names()
  local width = 0
  for _, name in ipairs(names) do
    width = math.max(width, #name)
  end
  local lines = { 'usage: :Shortcut <subcommand> [args...]', '', 'Subcommands:' }
  for _, name in ipairs(names) do
    local spec = registry[name] or M.lazy[name]
    table.insert(lines, ('  %-' .. width .. 's  %s'):format(name, spec.desc))
  end
  return table.concat(lines, '\n')
end

--- Entry point for the `:Shortcut` user command.
---@param cmd vim.api.keyset.create_user_command.command_args
function M.dispatch(cmd)
  local args = vim.deepcopy(cmd.fargs)
  local name = table.remove(args, 1)
  if not name then
    notify.info(M.help_text())
    return
  end

  local ok, spec = pcall(M.get, name)
  if not ok then
    notify.error(tostring(spec))
    return
  end
  if not spec then
    notify.error(("unknown subcommand '%s'\n\n%s"):format(name, M.help_text()))
    return
  end

  local run_ok, err = pcall(spec.run, args, cmd)
  if not run_ok then
    notify.error(('%s: %s'):format(name, tostring(err)))
  end
end

--- Completion function for the `:Shortcut` user command.
---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
function M.complete(arglead, cmdline, cursorpos)
  -- Drop the command name itself (which may be abbreviated or carry a bang).
  local typed = cmdline:sub(1, cursorpos):gsub('^%s*%S+', '', 1)
  local words = vim.split(typed, '%s+', { trimempty = true })
  if arglead ~= '' then
    table.remove(words) -- the word currently being completed
  end

  if #words == 0 then
    return vim.tbl_filter(function(name)
      return vim.startswith(name, arglead)
    end, M.names())
  end

  local ok, spec = pcall(M.get, table.remove(words, 1))
  if not ok or not spec or not spec.complete then
    return {}
  end
  local complete_ok, result = pcall(spec.complete, arglead, words)
  return complete_ok and result or {}
end

M.register('help', {
  desc = 'List available subcommands',
  run = function()
    notify.info(M.help_text())
  end,
})

return M

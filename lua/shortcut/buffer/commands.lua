--- `:Shortcut story` and `:Shortcut epic`: open an object by ID, `sc-<id>` or web URL.
local commands = require('shortcut.commands')
local handlers = require('shortcut.buffer.handlers')
local uri = require('shortcut.uri')
local notify = require('shortcut.notify')

local M = {}

local USAGE = {
  story = 'usage: :Shortcut story {id | sc-<id> | url}',
  epic = 'usage: :Shortcut epic {id | sc-<id> | url}',
}

--- Parse the argument of `:Shortcut <kind>`.
---@param kind shortcut.Kind
---@param arg string
---@return shortcut.uri.Target
function M.parse_arg(kind, arg)
  local target = arg:match('^%d+$') and uri.parse('sc-' .. arg) or uri.parse(arg)
  if not target then
    error(("invalid %s reference '%s'\n%s"):format(kind, arg, USAGE[kind]), 0)
  end
  if target.kind ~= 'id' and target.kind ~= kind then
    error(
      ("'%s' is a link to %s %s, not %s %s"):format(
        arg,
        target.kind == 'epic' and 'an' or 'a',
        target.kind,
        kind == 'epic' and 'an' or 'a',
        kind
      ),
      0
    )
  end
  return target
end

---@param kind shortcut.Kind
---@return fun(args: string[])
local function run(kind)
  return function(args)
    if #args == 0 then
      -- TODO(#12): `:Shortcut story` with no argument opens the story for the git branch.
      notify.info(USAGE[kind])
      return
    end
    if #args > 1 then
      error(('expected one argument\n%s'):format(USAGE[kind]), 0)
    end
    local target = M.parse_arg(kind, args[1])
    handlers.open(kind, target.id, { comment = target.comment, workspace = target.workspace })
  end
end

commands.register('story', { desc = 'Open a story by ID, sc-<id> or URL', run = run('story') })
commands.register('epic', { desc = 'Open an epic by ID, sc-<id> or URL', run = run('epic') })

return M

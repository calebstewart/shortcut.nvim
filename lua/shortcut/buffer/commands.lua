--- `:Shortcut story` and `:Shortcut epic`: open an object by ID, `sc-<id>` or web URL.
--- `:Shortcut story` with no argument opens the story named by the current git branch.
local commands = require('shortcut.commands')
local handlers = require('shortcut.buffer.handlers')
local uri = require('shortcut.uri')
local notify = require('shortcut.notify')

local M = {}

local USAGE = {
  story = 'usage: :Shortcut story [id | sc-<id> | url]',
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
      if kind == 'epic' then
        notify.info(USAGE[kind])
        return
      end
      -- The git branch's story. Not the current buffer's: that is already open.
      require('shortcut.target').resolve(
        nil,
        { command = 'story', buffer = false },
        function(err, target)
          if err then
            notify.error(('story: %s'):format(err))
            return
          end
          ---@cast target shortcut.target.Target
          local ok, open_err = pcall(handlers.open, 'story', target.id)
          if not ok then
            notify.error(('story: %s'):format(tostring(open_err)))
          end
        end
      )
      return
    end
    if #args > 1 then
      error(('expected one argument\n%s'):format(USAGE[kind]), 0)
    end
    local target = M.parse_arg(kind, args[1])
    handlers.open(kind, target.id, { comment = target.comment, workspace = target.workspace })
  end
end

commands.register('story', {
  desc = "Open a story by ID, sc-<id> or URL (default: the git branch's)",
  run = run('story'),
})
commands.register('epic', { desc = 'Open an epic by ID, sc-<id> or URL', run = run('epic') })

return M

--- shortcut.nvim: browse, search and edit Shortcut stories and epics from Neovim.
local M = {}

--- Configure the plugin. Optional: without it, the defaults apply.
---@param opts? table See `shortcut.Config`.
---@return boolean ok `false` if the options were invalid (the error has been reported).
function M.setup(opts)
  return require('shortcut.config').setup(opts)
end

return M

--- shortcut.nvim: browse, search and edit Shortcut stories and epics from Neovim.
local M = {}

--- Configure the plugin. Optional: without it, the defaults apply.
---@param opts? table See `shortcut.Config`.
---@return boolean ok `false` if the options were invalid (the error has been reported).
function M.setup(opts)
  return require('shortcut.config').setup(opts)
end

--- Make `gf` on `sc-<id>` work in a buffer whose filetype sets its own 'includeexpr' (e.g. from
--- `after/ftplugin/<filetype>.lua`). The original expression still handles every other name.
--- Done automatically for `gitcommit`.
---@param buf? integer Defaults to the current buffer.
function M.chain_includeexpr(buf)
  require('shortcut.buffer.handlers').chain_includeexpr(buf)
end

--- An 'includeexpr' function mapping `sc-<id>` to a name `gf` can open. Other names are passed to
--- `fallback` (a Vimscript expression or a Lua function), or returned unchanged.
---@param fname string
---@param fallback? string|fun(fname: string): string
---@return string
function M.includeexpr(fname, fallback)
  return require('shortcut.buffer.handlers').includeexpr(fname, fallback)
end

return M

--- Thin wrapper around `vim.notify` so every message the plugin shows is consistently prefixed.
local M = {}

local PREFIX = 'shortcut.nvim: '

---@param msg string
---@param level integer
local function notify(msg, level)
  vim.notify(PREFIX .. msg, level)
end

---@param msg string
function M.error(msg)
  notify(msg, vim.log.levels.ERROR)
end

---@param msg string
function M.warn(msg)
  notify(msg, vim.log.levels.WARN)
end

---@param msg string
function M.info(msg)
  notify(msg, vim.log.levels.INFO)
end

return M

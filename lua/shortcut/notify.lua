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

--- Untrusted text (e.g. a story title) made fit for a one-line message, prompt or window title:
--- control characters (newlines included), Unicode line/paragraph separators and bidirectional
--- overrides become spaces, runs of spaces collapse, and text longer
--- than `max` characters is cut with `…`.
---@param s any
---@param max? integer
---@return string
function M.flatten(s, max)
  if type(s) ~= 'string' then
    return ''
  end
  s = s
    :gsub('%c', ' ')
    -- U+2028..U+202E (separators, bidi embeddings/overrides), U+2066..U+2069 (bidi isolates).
    :gsub(
      '\226\128[\168-\174]',
      ' '
    )
    :gsub('\226\129[\166-\169]', ' ')
    :gsub('%s%s+', ' ')
  s = vim.trim(s)
  if max and vim.fn.strchars(s) > max then
    s = vim.fn.strcharpart(s, 0, math.max(max - 1, 0)) .. '…'
  end
  return s
end

return M

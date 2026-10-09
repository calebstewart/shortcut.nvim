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

--- An error message without the `<file>.lua:<line>: ` (or `[string "…"]:<line>: `) position
--- Lua puts in front of errors raised with `error(msg)`, and only its first line (never a stack
--- traceback, should one have been added).
---@param err any
---@return string
function M.strip_location(err)
  local msg = tostring(err)
  local traceback = msg:find('\nstack traceback:', 1, true)
  if traceback then
    msg = msg:sub(1, traceback - 1)
  end
  msg = msg:gsub('^%[string "[^\n]-"%]:%d+: ', '', 1):gsub('^[^\n]-%.lua:%d+: ', '', 1)
  return msg
end

local cpo_restore_pending = false

--- Refuse a write, from a `BufWriteCmd`, `FileWriteCmd` or `FileAppendCmd` handler: report `msg`
--- as an error and make the write fail, so that `:wq {file}` and `:x {file}` don't go on to close
--- the window (and `:wqa` doesn't exit).
---
--- Raising a Lua error doesn't do that when the command is typed (Neovim reports the error, with
--- a stack trace, and quits anyway). A write handler makes a write fail by leaving the buffer
--- modified, but Neovim only checks that for a write to the buffer's own name, unless
--- 'cpoptions' contains `+`: so `+` is added until the command has finished. The message is
--- shown then too, so that it is not presented as an error in an autocommand.
---@param msg string
function M.refuse_write(msg)
  if not vim.o.cpoptions:find('+', 1, true) then
    vim.o.cpoptions = vim.o.cpoptions .. '+'
    cpo_restore_pending = true
  end
  vim.schedule(function()
    if cpo_restore_pending then
      cpo_restore_pending = false
      vim.o.cpoptions = (vim.o.cpoptions:gsub('%+', ''))
    end
    M.error(msg)
  end)
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

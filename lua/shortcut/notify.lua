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
  -- Only a position at the very start, with no space in its path (`/x/y.lua:3: `,
  -- `.../y.lua:3: `), never a `.lua:<n>: ` further on in the message.
  msg = msg:gsub('^%[string "[^\n]-"%]:%d+: ', '', 1):gsub('^%S-%.lua:%d+: ', '', 1)
  return msg
end

--- Whether `refuse_write()` added `+` to 'cpoptions' (and has not removed it yet).
local cpo_added = false

local CPO_GROUP = 'shortcut.notify.cpo'

--- Remove the `+` that `refuse_write()` added, if it is still there.
local function restore_cpo()
  if not cpo_added then
    return
  end
  cpo_added = false
  pcall(vim.api.nvim_del_augroup_by_name, CPO_GROUP)
  vim.o.cpoptions = (vim.o.cpoptions:gsub('%+', ''))
end

--- Refuse a write, from a `BufWriteCmd`, `FileWriteCmd` or `FileAppendCmd` handler: report `msg`
--- as an error and make the write fail, so that `:wq {file}` and `:x {file}` don't go on to close
--- the window (and `:wqa` doesn't exit).
---
--- Raising a Lua error doesn't do that when the command is typed (Neovim reports the error, with
--- a stack trace, and quits anyway). A write handler makes a write fail by leaving the buffer
--- modified, but Neovim only checks that for a write to the buffer's own name, unless
--- 'cpoptions' contains `+`: so `+` is added for this write only. It is removed once the command
--- has finished, or as soon as any other write starts (`:w a.md | wincmd p | w b.txt`): with it,
--- `:w {file}` of an ordinary buffer would reset that buffer's 'modified'. The message is shown
--- once the command has finished, so that it is not presented as an error in an autocommand.
---@param msg string
function M.refuse_write(msg)
  if not cpo_added and not vim.o.cpoptions:find('+', 1, true) then
    vim.o.cpoptions = vim.o.cpoptions .. '+'
    cpo_added = true
    -- The Pre event of every other kind of write. (A write handled by another `BufWriteCmd`
    -- never resets 'modified' by itself.)
    vim.api.nvim_create_autocmd(
      { 'BufWritePre', 'FileWritePre', 'FileAppendPre', 'FilterWritePre' },
      {
        group = vim.api.nvim_create_augroup(CPO_GROUP, { clear = true }),
        desc = "shortcut.nvim: remove the 'cpoptions' + of a refused write",
        callback = restore_cpo,
      }
    )
  end
  vim.schedule(function()
    restore_cpo()
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

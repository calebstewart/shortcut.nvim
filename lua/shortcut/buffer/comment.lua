--- Writing a comment on a story in a floating Markdown buffer.
---
--- The buffer is named `shortcut://story/<id>/comment` (`buftype=acwrite`). Its own
--- `BufWriteCmd` posts it (`POST /stories/{id}/comments`, see `shortcut.api.stories`); the
--- story buffer routing in `shortcut.buffer.handlers` leaves it alone. `:w` posts and closes
--- the float, `:q!` discards. An empty comment is not posted. If posting fails, the text stays
--- in the buffer (and the float is reopened with it if it was closed meanwhile, e.g. by `:wq`).
local notify = require('shortcut.notify')
local uri = require('shortcut.uri')

local M = {}

--- Longest title shown, in characters.
local MAX_TITLE = 70

---@type table<integer, true> Buffers whose comment is being posted.
local posting = {}

---@param id integer
---@param title? string The story's title.
---@return string
function M.title(id, title)
  local t = ('Comment on sc-%d'):format(id)
  title = notify.flatten(title)
  if title ~= '' then
    t = ('%s: %s'):format(t, title)
  end
  return notify.flatten(t, MAX_TITLE)
end

---@param name string
---@return integer?
local function find_buf(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return nil
end

--- Whether the float has a border to show its title on.
---@return string|nil border `nil` to use 'winborder'.
---@return boolean titled
local function border()
  local wb = vim.o.winborder
  if wb == 'none' then
    return nil, false
  end
  if wb == '' then
    return 'rounded', true
  end
  return nil, true
end

---@param buf integer
---@param title string
---@return integer win
local function open_win(buf, title)
  local columns, lines = vim.o.columns, vim.o.lines
  local width = math.max(math.min(80, columns - 4), 20)
  local height = math.max(math.min(12, lines - 6), 3)
  local b, titled = border()
  ---@type vim.api.keyset.win_config
  local config = {
    relative = 'editor',
    row = math.max(math.floor((lines - height) / 2) - 1, 0),
    col = math.max(math.floor((columns - width) / 2), 0),
    width = width,
    height = height,
    style = 'minimal',
    border = b,
  }
  if titled then
    config.title = ' ' .. notify.flatten(title, width - 4) .. ' '
    config.title_pos = 'center'
    config.footer = ' :w post · :q! discard '
    config.footer_pos = 'center'
  end
  local win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  return win
end

--- Set the story title shown on the float(s) of a comment buffer, once it is known.
---@param buf integer
---@param story_title string Untrusted: it is flattened.
function M.set_title(buf, story_title)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local info = vim.b[buf].shortcut_comment
  if type(info) ~= 'table' then
    return
  end
  info.title = story_title
  vim.b[buf].shortcut_comment = info
  local title = M.title(info.id, story_title)
  local _, titled = border()
  if not titled then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative and config.relative ~= '' then
      pcall(vim.api.nvim_win_set_config, win, {
        title = ' ' .. notify.flatten(title, config.width - 4) .. ' ',
        title_pos = 'center',
      })
    end
  end
end

--- Lines as the text of a comment: without leading and trailing blank lines or trailing
--- whitespace.
---@param lines string[]
---@return string
function M.text(lines)
  local text = table.concat(lines, '\n')
  text = text:gsub('^%s*\n', ''):gsub('%s+$', '')
  return text
end

---@param id integer
---@param err string
local function report_failure(id, err)
  notify.error(('failed to post the comment on sc-%d: %s'):format(id, err))
end

--- Post the comment in `buf`.
---@param buf integer
function M.post(buf)
  local info = vim.b[buf].shortcut_comment
  if type(info) ~= 'table' then
    return
  end
  local id = info.id --[[@as integer]]
  if posting[buf] then
    notify.warn(('the comment on sc-%d is already being posted'):format(id))
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = M.text(lines)
  if text == '' then
    notify.error(('the comment is empty: nothing was posted to sc-%d'):format(id))
    return
  end

  posting[buf] = true
  -- Not editable while posting: what is posted is what is in the buffer. Unmodified, so that
  -- `:wq` closes it; it is marked modified again if posting fails.
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  local http = require('shortcut.http')
  require('shortcut.api.stories').comments.create(id, { text = text }, function(err)
    posting[buf] = nil
    local valid = vim.api.nvim_buf_is_valid(buf)
    if err then
      local msg = err.status == 404 and ('sc-%d not found'):format(id) or http.format_error(err)
      if valid then
        vim.bo[buf].modifiable = true
        vim.bo[buf].modified = true
        report_failure(id, msg)
      else
        -- Closed meanwhile (`:wq`): don't lose the text.
        M.open(id, { lines = lines, title = info.title })
        report_failure(id, msg .. '; the comment has been reopened')
      end
      return
    end
    if valid then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        pcall(vim.api.nvim_win_close, win, true)
      end
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    local handlers = require('shortcut.buffer.handlers')
    local reload = handlers.reload_if_unmodified('story', id)
    if reload == 'modified' then
      notify.warn(
        ('comment posted on sc-%d; its buffer has unsaved changes, so it was not reloaded'):format(
          id
        )
      )
    else
      notify.info(('comment posted on sc-%d'):format(id))
    end
  end)
end

---@class shortcut.comment.OpenOpts
---@field title? string The story's title, if known (untrusted: it is flattened).
---@field lines? string[] Initial text.

--- Open the comment float for story `id`, or focus the one already open.
---@param id integer
---@param opts? shortcut.comment.OpenOpts
---@return integer buf
function M.open(id, opts)
  opts = opts or {}
  local name = uri.comment_name(id)
  local existing = find_buf(name)
  if existing and vim.b[existing].shortcut_comment then
    local win = vim.fn.win_findbuf(existing)[1]
    if win then
      vim.api.nvim_set_current_win(win)
    else
      open_win(existing, M.title(id, vim.b[existing].shortcut_comment.title))
    end
    if opts.lines then
      -- A failed post of a closed float: keep both texts.
      local cur = vim.api.nvim_buf_get_lines(existing, 0, -1, false)
      if not (#cur == 1 and cur[1] == '') then
        table.insert(cur, '')
      else
        cur = {}
      end
      vim.list_extend(cur, opts.lines)
      vim.bo[existing].modifiable = true
      vim.api.nvim_buf_set_lines(existing, 0, -1, false, cur)
    end
    return existing
  end
  if existing then
    -- Some other buffer by that name (e.g. `:e shortcut://story/<id>/comment`).
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  -- The title and any reopened text came from elsewhere: never let them set options.
  vim.bo[buf].modeline = false
  vim.b[buf].shortcut_comment = { id = id, title = opts.title }
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].filetype = 'markdown'
  if opts.lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
    vim.bo[buf].modified = true
  else
    vim.bo[buf].modified = false
  end

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    desc = 'shortcut.nvim: post the comment',
    callback = function(ev)
      M.post(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function(ev)
      posting[ev.buf] = nil
    end,
  })

  open_win(buf, M.title(id, opts.title))
  if not opts.lines then
    vim.cmd.startinsert()
  end
  return buf
end

--- The comment buffer of story `id`, if open.
---@param id integer
---@return integer?
function M.find(id)
  local buf = find_buf(uri.comment_name(id))
  return buf and vim.b[buf].shortcut_comment and buf or nil
end

return M

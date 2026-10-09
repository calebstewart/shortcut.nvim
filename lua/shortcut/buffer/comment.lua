--- Writing a comment on a story in a floating Markdown buffer.
---
--- The buffer is named `shortcut://story/<id>/comment` (`buftype=acwrite`). Its own
--- `BufWriteCmd` posts it (`POST /stories/{id}/comments`, see `shortcut.api.stories`); the
--- story buffer routing in `shortcut.buffer.handlers` leaves it alone. `:w` posts and closes
--- the float, `:q!` discards. An empty comment is not posted. If posting fails, the text stays
--- in the buffer (and the float is reopened with it if it was closed meanwhile, e.g. by `:wq`).
---
--- Only a write to the buffer's own name posts; `:w file`, `:saveas`, partial writes etc. are
--- refused. So is a write from another window (`:wall`, `:wqa`, `:xa` there): the draft is
--- kept, still modified, so `:wqa`/`:xa` don't exit. Neovim makes the buffer current for the
--- autocommand, so focus is tracked with `BufEnter`/`BufLeave`, which it doesn't trigger then.
--- Switching windows with autocommands suppressed (`:noautocmd wincmd p`, some plugins) leaves
--- that stale, so a command typed on the command line must also have been typed in the float's
--- window (recorded on `CmdlineLeave`). What remains: a write from a mapping or plugin
--- (`<Cmd>wall<CR>`) after such a switch is taken as coming from the float.
---
--- `:wqa`/`:xa` in the float itself post and wait for the answer (at most `QUIT_WAIT`): if it
--- fails, the buffer stays modified, so Neovim doesn't exit and the error is shown. As a last
--- resort, exiting with a post still in flight (e.g. `:w` then `:qa`) waits for it and saves the
--- draft if it fails (see `on_exit()`).
local notify = require('shortcut.notify')
local uri = require('shortcut.uri')

local M = {}

--- Longest title shown, in characters.
local MAX_TITLE = 70

---@type table<integer, true> Buffers whose comment is being posted.
local posting = {}

---@type table<integer, true> Comment buffers that are the user's current buffer.
local focused = {}

--- Set by `QuitPre` until the command has run: a write now is part of `:wqa`/`:xa`.
local quitting = false

--- The window an Ex command line was typed in, until the command has run.
---@type integer?
local cmdline_win

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

--- Longest wait for posts in flight when Neovim exits, in milliseconds.
M.EXIT_WAIT = 15000

--- Posts in flight, so that exiting (`:wqa`, `:xa`) waits for them.
---@type table<table, { id: integer, lines: string[], done: boolean, ok: boolean }>
local inflight = {}

--- Set once Neovim is exiting: a failed post is saved to a file instead of reopened.
local exiting = false

--- Where drafts that could not be posted while exiting are saved.
---@return string
function M.unsent_dir()
  return vim.fs.joinpath(vim.fn.stdpath('state') --[[@as string]], 'shortcut', 'unsent')
end

--- Save a draft that was not posted; returns the file, or `nil` if it could not be written.
---@param id integer
---@param lines string[]
---@return string?
local function save_unsent(id, lines)
  local dir = M.unsent_dir()
  local fs = require('shortcut.fs')
  -- Private: drafts may be confidential.
  if not fs.mkdir_p(dir, tonumber('700', 8)) then
    return nil
  end
  local data = table.concat(lines, '\n') .. '\n'
  local stamp = os.time()
  -- Exclusive creation: never overwrite another draft (e.g. one saved in the same second).
  for n = 1, 100 do
    local base = n == 1 and ('comment-sc-%d-%d.md'):format(id, stamp)
      or ('comment-sc-%d-%d-%d.md'):format(id, stamp, n)
    local path = vim.fs.joinpath(dir, base)
    local fd, _, code = vim.uv.fs_open(path, 'wx', tonumber('600', 8))
    if fd then
      local written = vim.uv.fs_write(fd, data, 0)
      vim.uv.fs_fsync(fd)
      vim.uv.fs_close(fd)
      return written == #data and path or nil
    elseif code ~= 'EEXIST' then
      return nil
    end
  end
  return nil
end

--- On exit, wait (at most `EXIT_WAIT`) for posts in flight, and save the drafts of those that
--- fail or don't finish, so `:wqa` never silently loses a comment.
function M.on_exit()
  exiting = true
  if next(inflight) == nil then
    return
  end
  vim.wait(M.EXIT_WAIT, function()
    for _, p in pairs(inflight) do
      if not p.done then
        return false
      end
    end
    return true
  end, 20)
  for key, p in pairs(inflight) do
    if not (p.done and p.ok) then
      local path = save_unsent(p.id, p.lines)
      -- Without an answer, the server may have got it: say so, lest it be posted twice.
      local what = p.done and 'was not posted'
        or 'was not confirmed as posted (it may still have been)'
      local msg = ('shortcut.nvim: the comment on sc-%d %s%s'):format(
        p.id,
        what,
        path and ('; it was saved to ' .. path) or ''
      )
      -- The UI may already be gone: stderr is shown in the terminal after exit.
      io.stderr:write(msg .. '\n')
      pcall(vim.api.nvim_echo, { { msg, 'ErrorMsg' } }, true, {})
    end
    inflight[key] = nil
  end
end

local exit_group ---@type integer?

--- Longest wait for the answer when posting as part of `:wqa`/`:xa`, in milliseconds.
M.QUIT_WAIT = 10000

---@type table<integer, fun()|true> Buffers whose `BufWriteCmd` is waiting for the answer: what
--- to do once it has returned (Neovim is still writing the buffer meanwhile, so the float must
--- not be closed).
local waiting = {}

--- Post the comment in `buf`. Returns whether a request was sent, and a function telling whether
--- it is done.
---@param buf integer
---@return boolean sent
---@return fun(): boolean done
function M.post(buf)
  local done = false
  local function is_done()
    return done
  end
  local info = vim.b[buf].shortcut_comment
  if type(info) ~= 'table' then
    return false, is_done
  end
  local id = info.id --[[@as integer]]
  if posting[buf] then
    notify.warn(('the comment on sc-%d is already being posted'):format(id))
    return false, is_done
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = M.text(lines)
  if text == '' then
    -- From the write: the write fails.
    notify.refuse_write(('the comment is empty: nothing was posted to sc-%d'):format(id))
    return false, is_done
  end

  if not exit_group then
    exit_group = vim.api.nvim_create_augroup('shortcut.buffer.comment', { clear = true })
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = exit_group,
      desc = 'shortcut.nvim: wait for comments being posted',
      callback = function()
        M.on_exit()
      end,
    })
  end

  posting[buf] = true
  local flight = { id = id, lines = lines, done = false, ok = false }
  inflight[flight] = flight
  -- Not editable while posting: what is posted is what is in the buffer. Unmodified, so that
  -- `:wq` closes it; it is marked modified again if posting fails.
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  local http = require('shortcut.http')
  require('shortcut.api.stories').comments.create(id, { text = text }, function(err)
    posting[buf] = nil
    done = true
    flight.done, flight.ok = true, not err
    if not exiting then
      inflight[flight] = nil
    end
    local valid = vim.api.nvim_buf_is_valid(buf)
    if err then
      local msg = err.status == 404 and ('sc-%d not found'):format(id) or http.format_error(err)
      if exiting then
        -- `on_exit()` saves the draft.
        return
      end
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
    if exiting then
      return
    end
    local function finish()
      if vim.api.nvim_buf_is_valid(buf) then
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
    end
    if waiting[buf] then
      waiting[buf] = finish
    else
      finish()
    end
  end)
  return true, is_done
end

---@param target string
---@return string
local function refusal(target)
  return ('cannot write the comment to %s: :w posts it, :q! discards it'):format(
    notify.flatten(target)
  )
end

--- The `BufWriteCmd` of a comment buffer: only a write of the buffer to its own name (`:w`,
--- `:w!`, `:wq`, `:x`, `:up`) posts. Writing it elsewhere (`:w file`, `:saveas file`,
--- `:w shortcut://story/<id>`) is refused and sends nothing.
---@param ev vim.api.keyset.create_autocmd.callback_args
function M.on_write(ev)
  local buf = ev.buf
  local info = vim.b[buf].shortcut_comment
  if type(info) ~= 'table' then
    return
  end
  local name = uri.comment_name(info.id)
  local current = vim.api.nvim_buf_get_name(buf)
  if ev.match ~= name or current ~= name then
    if current ~= name then
      -- `:saveas` renamed the buffer before writing: give it its name back.
      pcall(vim.api.nvim_buf_set_name, buf, name)
    end
    -- The write fails: `:wq file` and `:x file` must not go on to quit and lose the draft.
    notify.refuse_write(refusal(ev.match))
    return
  end
  local typed_elsewhere = cmdline_win ~= nil
    and not (
      vim.api.nvim_win_is_valid(cmdline_win) and vim.api.nvim_win_get_buf(cmdline_win) == buf
    )
  if not focused[buf] or typed_elsewhere or vim.api.nvim_get_current_buf() ~= buf then
    -- `:wall`/`:wqa`/`:xa` from another window: the draft may be half-written. Left modified,
    -- so `:wqa`/`:xa` don't exit.
    notify.warn(
      ('the comment on sc-%d was not posted: only :w in its window posts it'):format(info.id)
    )
    return
  end
  if not quitting then
    M.post(buf)
    return
  end
  -- `:wqa`/`:xa`: wait for the answer, so that a failure keeps the buffer modified and stops
  -- Neovim from exiting, rather than being lost.
  waiting[buf] = true
  local sent, is_done = M.post(buf)
  local answered = not sent or vim.wait(M.QUIT_WAIT, is_done, 10)
  local finish = waiting[buf]
  waiting[buf] = nil
  if type(finish) == 'function' then
    -- Posted: close the float after the command (if Neovim doesn't exit first).
    vim.schedule(finish)
  end
  if not answered then
    -- Still in flight: don't exit. The float closes once it is posted.
    vim.bo[buf].modified = true
    notify.warn(
      ('the comment on sc-%d is still being posted: not exiting'):format(info.id --[[@as integer]])
    )
  end
end

local watch_group ---@type integer?

--- Track `QuitPre`, which `:wqa`/`:xa` trigger before writing, and the window Ex commands are
--- typed in.
local function watch_commands()
  if watch_group then
    return
  end
  watch_group = vim.api.nvim_create_augroup('shortcut.buffer.comment.watch', { clear = true })
  vim.api.nvim_create_autocmd('CmdlineLeave', {
    group = watch_group,
    pattern = ':',
    desc = 'shortcut.nvim: where a command that may write a comment was typed',
    callback = function()
      local win = vim.api.nvim_get_current_win()
      cmdline_win = win
      -- Once the command has run.
      vim.schedule(function()
        if cmdline_win == win then
          cmdline_win = nil
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd('QuitPre', {
    group = watch_group,
    desc = 'shortcut.nvim: wait for a comment posted by :wqa',
    callback = function()
      quitting = true
      -- Once the command has run (and not exited).
      vim.schedule(function()
        quitting = false
      end)
    end,
  })
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
      M.on_write(ev)
    end,
  })
  -- Part of the buffer (`:1,2w`, `:w >> file`): never posted, and never written anywhere.
  vim.api.nvim_create_autocmd({ 'FileWriteCmd', 'FileAppendCmd' }, {
    buffer = buf,
    desc = 'shortcut.nvim: refuse partial writes of a comment',
    callback = function(ev)
      notify.refuse_write(refusal(ev.match))
    end,
  })
  -- Not triggered when Neovim makes the buffer current for `:wall` from another window.
  vim.api.nvim_create_autocmd('BufEnter', {
    buffer = buf,
    callback = function(ev)
      focused[ev.buf] = true
    end,
  })
  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = buf,
    callback = function(ev)
      focused[ev.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function(ev)
      posting[ev.buf] = nil
      focused[ev.buf] = nil
    end,
  })
  watch_commands()

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

--- Working out "the current story" for commands like `:Shortcut comment`.
---
--- In order, the first that applies wins:
---   1. an explicit argument: an ID, `sc-<id>`, a Shortcut web URL or a `shortcut://` name,
---   2. the current buffer, if it shows a story or an epic (or is a comment being written),
---   3. the story named by the current git branch (see `shortcut.git`),
---   4. otherwise an error explaining how to name one.
local uri = require('shortcut.uri')

local M = {}

---@alias shortcut.target.Source 'arg'|'buffer'|'branch'

---@class shortcut.target.Target
---@field kind shortcut.Kind
---@field id integer
---@field source shortcut.target.Source
---@field buf? integer The Shortcut buffer it was taken from (source `'buffer'`).
---@field workspace? string Workspace slug of a web URL argument.
---@field comment? integer Comment anchor of a web URL argument.

---@class shortcut.target.Opts
---@field command string Subcommand name, for messages (e.g. `comment`).
---@field kinds? table<shortcut.Kind, true> Kinds the command works on (default: stories).
---@field buffer? boolean Consider the current buffer (default `true`).
---@field buf? integer The current buffer (default: the current buffer when `resolve()` is called).
---@field dir? string Where to look for the git repository (default: `shortcut.git.dir()`).
---@field resolve_kind? shortcut.buffer.Resolver How to tell whether an ID is a story or an epic
--- when epics are accepted (default: the buffer handlers' resolver).

local ARTICLE = { story = 'a story', epic = 'an epic' }

---@param kinds table<shortcut.Kind, true>
---@return string
local function kinds_text(kinds)
  if kinds.story and kinds.epic then
    return 'stories and epics'
  end
  return kinds.epic and 'epics' or 'stories'
end

---@param opts shortcut.target.Opts
---@return string
function M.usage(opts)
  return ('usage: :Shortcut %s [id | sc-<id> | url]'):format(opts.command)
end

--- Parse an explicit argument. `kind` is `'id'` for a bare ID or `sc-<id>`.
---@param arg string
---@return shortcut.uri.Target? target
---@return string? err
function M.parse_arg(arg)
  local target = arg:match('^%d+$') and uri.parse('sc-' .. arg) or uri.parse(arg)
  if not target then
    return nil, ("invalid story reference '%s'"):format(arg)
  end
  return target
end

--- The object shown in a buffer: a story or epic buffer, or the story a comment is being
--- written on.
---@param buf integer
---@return { kind: shortcut.Kind, id: integer }?
function M.from_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local comment = uri.parse_comment_name(name)
  if comment and vim.b[buf].shortcut_comment then
    return { kind = 'story', id = comment }
  end
  local info = vim.b[buf].shortcut
  local target = uri.parse(name)
  if
    type(info) == 'table'
    and target
    and uri.is_kind(target.kind)
    and target.kind == info.kind
    and target.id == info.id
  then
    return {
      kind = target.kind --[[@as shortcut.Kind]],
      id = target.id,
    }
  end
  return nil
end

--- Work out the target of a command. `callback(err, target)` runs on the main loop (or at once,
--- when no lookup is needed). Call this on the main loop.
---@param arg? string The explicit argument, if any.
---@param opts shortcut.target.Opts
---@param callback fun(err?: string, target?: shortcut.target.Target)
function M.resolve(arg, opts, callback)
  local kinds = opts.kinds or { story = true }
  local cmd = opts.command

  ---@param kind shortcut.Kind
  ---@param id integer
  ---@return string?
  local function check_kind(kind, id)
    if not kinds[kind] then
      return ('sc-%d is %s; :Shortcut %s works on %s'):format(
        id,
        ARTICLE[kind],
        cmd,
        kinds_text(kinds)
      )
    end
    return nil
  end

  if arg and arg ~= '' then
    local parsed, perr = M.parse_arg(arg)
    if not parsed then
      return callback(('%s\n%s'):format(perr, M.usage(opts)))
    end
    ---@param kind shortcut.Kind
    local function done(kind)
      local err = check_kind(kind, parsed.id)
      if err then
        return callback(err)
      end
      callback(nil, {
        kind = kind,
        id = parsed.id,
        source = 'arg',
        workspace = parsed.workspace,
        comment = parsed.comment,
      })
    end
    if parsed.kind ~= 'id' then
      return done(parsed.kind --[[@as shortcut.Kind]])
    end
    if not kinds.epic then
      -- Only stories make sense here: a bare ID is one.
      return done('story')
    end
    local resolve_kind = opts.resolve_kind
      or function(id, cb)
        return require('shortcut.buffer.handlers').resolve_kind(id, cb)
      end
    resolve_kind(parsed.id, function(kind, err)
      if err then
        return callback(('could not look up sc-%d: %s'):format(parsed.id, err))
      end
      if not kind then
        return callback(('sc-%d not found'):format(parsed.id))
      end
      done(kind)
    end)
    return
  end

  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if opts.buffer ~= false then
    local current = M.from_buffer(buf)
    if current then
      local err = check_kind(current.kind, current.id)
      if err then
        return callback(err)
      end
      return callback(nil, { kind = current.kind, id = current.id, source = 'buffer', buf = buf })
    end
  end

  if not kinds.story then
    return callback(('no %s given\n%s'):format(kinds_text(kinds), M.usage(opts)))
  end
  local git = require('shortcut.git')
  git.branch_story(opts.dir or git.dir(buf), function(err, id, branch)
    if id then
      return callback(nil, { kind = 'story', id = id, source = 'branch' })
    end
    local why = err and ('git: %s'):format(err)
      or ("git branch '%s' names no story"):format(
        require('shortcut.notify').flatten(branch or '', 80)
      )
    callback(
      ('no story given, and none found in the %s (%s)\n%s'):format(
        opts.buffer == false and 'git branch' or 'current buffer or git branch',
        why,
        M.usage(opts)
      )
    )
  end)
end

return M

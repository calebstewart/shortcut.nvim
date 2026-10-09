--- Quick actions on "the current story" (see `shortcut.target`): `:Shortcut comment`, `state`,
--- `browse`, `yank`, and `:Shortcut refresh`.
---
--- API facts (OpenAPI spec, see `shortcut.api`):
---   - `PUT /stories/{id}` (updateStory) takes `workflow_state_id` ("the ID of the workflow state
---     to put the story in", int64) and answers 200 with the `Story`.
---   - `Story` has `workflow_id` (its workflow) and `workflow_state_id`; `WorkflowState` has
---     `position` ("starting with 0 at the left").
---   - `POST /stories/{id}/comments` (createStoryComment): see `shortcut.buffer.comment`.
local async = require('shortcut.async')
local commands = require('shortcut.commands')
local notify = require('shortcut.notify')
local target = require('shortcut.target')

local M = {}

--- Longest story title shown in prompts and messages, in characters.
local MAX_TITLE = 60

local STORIES_AND_EPICS = { story = true, epic = true }

--- An error message without the `file:line: ` prefix Lua adds.
---@param err any
---@return string
local function message(err)
  return (tostring(err):gsub('^[^\n]-:%d+: ', '', 1))
end

--- Run `fn` as an async task; an error it raises is reported as `<cmd>: <message>`.
---@param cmd string
---@param fn async fun()
local function run(cmd, fn)
  async.run(fn, function(err)
    if err then
      notify.error(('%s: %s'):format(cmd, message(err)))
    end
  end)
end

---@param args string[]
---@param cmd string
local function at_most_one(args, cmd)
  if #args > 1 then
    error(('expected at most one argument\n%s'):format(target.usage({ command = cmd })), 0)
  end
end

--- Resolve the target, inside a task; raises on failure.
---@async
---@param arg? string
---@param opts shortcut.target.Opts
---@return shortcut.target.Target
local function resolve(arg, opts)
  local err, t = async.await(target.resolve, arg, opts)
  if err then
    error(err, 0)
  end
  return t --[[@as shortcut.target.Target]]
end

--- `GET /stories/{id}`, inside a task; raises on failure.
---@async
---@param id integer
---@return table story
function M.fetch_story(id)
  local http = require('shortcut.http')
  local err, story = async.await(require('shortcut.api.stories').get, id)
  if err then
    if err.status == 404 then
      error(('sc-%d not found (is it an epic?)'):format(id), 0)
    end
    error(err.kind == 'auth' and err.message or http.format_error(err), 0)
  end
  if type(story) ~= 'table' or type(story.id) ~= 'number' then
    error(('unexpected response from GET /stories/%d'):format(id), 0)
  end
  return story
end

--- The snapshot of a loaded story buffer for `id`, if any.
---@param id integer
---@param buf? integer A buffer known to show it.
---@return shortcut.story.Snapshot?
local function story_snapshot(id, buf)
  if not package.loaded['shortcut.buffer.story'] then
    -- Not loaded: no story buffer has been opened.
    return nil
  end
  buf = buf or require('shortcut.buffer.handlers').find('story', id)
  local snap = buf and require('shortcut.buffer.story').snapshot(buf)
  if snap and type(snap.story) == 'table' and snap.story.id == id then
    return snap
  end
  return nil
end

---------------------------------------------------------------------------------------------------
-- URLs
---------------------------------------------------------------------------------------------------

---@param slug string
---@param kind shortcut.Kind
---@param id integer
---@return string
local function build_url(slug, kind, id)
  local http = require('shortcut.http')
  return ('https://app.shortcut.com/%s/%s/%d'):format(http.encode_component(slug), kind, id)
end

--- The web app URL of a target, inside a task: the story's `app_url` if its buffer is loaded,
--- otherwise built from the workspace slug (the URL argument's, or the token's).
---@async
---@param t shortcut.target.Target
---@return string
function M.url(t)
  if t.kind == 'story' then
    local snap = story_snapshot(t.id, t.buf)
    local app_url = snap and snap.story.app_url
    local parsed = type(app_url) == 'string' and require('shortcut.uri').parse(app_url)
    -- Only a URL that really is this story's (it is opened and copied).
    if parsed and parsed.workspace and parsed.kind == 'story' and parsed.id == t.id then
      return notify.flatten(app_url)
    end
  end
  if t.workspace then
    return build_url(t.workspace, t.kind, t.id)
  end
  local err, user = async.await(require('shortcut.http').user)
  if err or not user then
    error(
      ('cannot build the URL of sc-%d: %s'):format(
        t.id,
        err and require('shortcut.http').format_error(err) or 'unknown workspace'
      ),
      0
    )
  end
  return build_url(user.url_slug, t.kind, t.id)
end

---------------------------------------------------------------------------------------------------
-- browse / yank
---------------------------------------------------------------------------------------------------

commands.register('browse', {
  desc = 'Open the current story or epic in the browser',
  run = function(args)
    at_most_one(args, 'browse')
    local opts = { command = 'browse', kinds = STORIES_AND_EPICS }
    run('browse', function()
      local url = M.url(resolve(args[1], opts))
      local _, err = vim.ui.open(url)
      if err then
        error(('cannot open %s: %s'):format(url, err), 0)
      end
    end)
  end,
})

--- Copy `text` to the unnamed register and the clipboard (`+`, and `*` when it is a different
--- selection, as on X11).
---@param text string
---@return string[] registers Those written.
function M.copy(text)
  vim.fn.setreg('"', text)
  local regs = { '"' }
  if vim.fn.has('clipboard') == 1 then
    if pcall(vim.fn.setreg, '+', text) then
      table.insert(regs, '+')
    end
    -- Where `*` is the same clipboard (macOS, Windows, most Wayland setups), it already holds
    -- the text.
    local ok, star = pcall(vim.fn.getreg, '*')
    if not (ok and star == text) and pcall(vim.fn.setreg, '*', text) then
      table.insert(regs, '*')
    end
  end
  return regs
end

commands.register('yank', {
  desc = 'Copy the URL of the current story or epic',
  run = function(args)
    at_most_one(args, 'yank')
    local opts = { command = 'yank', kinds = STORIES_AND_EPICS }
    run('yank', function()
      local url = M.url(resolve(args[1], opts))
      local regs = M.copy(url)
      local where = #regs > 1
          and ('registers %s'):format(table.concat(
            vim.tbl_map(function(r)
              return '"' .. r
            end, regs),
            ' '
          ))
        or 'the unnamed register (no clipboard available)'
      notify.info(('copied %s to %s'):format(url, where))
    end)
  end,
})

---------------------------------------------------------------------------------------------------
-- comment
---------------------------------------------------------------------------------------------------

commands.register('comment', {
  desc = 'Write a comment on the current story',
  run = function(args)
    at_most_one(args, 'comment')
    local opts = { command = 'comment' }
    run('comment', function()
      local t = resolve(args[1], opts)
      local comment = require('shortcut.buffer.comment')
      local snap = story_snapshot(t.id, t.buf)
      local title = snap and snap.story.name
      local existing = comment.find(t.id)
      local buf = comment.open(t.id, { title = type(title) == 'string' and title or nil })
      if snap or existing then
        return
      end
      local ok, story = pcall(M.fetch_story, t.id)
      if not ok then
        notify.warn(('comment: could not fetch sc-%d: %s'):format(t.id, message(story)))
        return
      end
      comment.set_title(buf, story.name)
    end)
  end,
})

---------------------------------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------------------------------

--- Whether the first of `args` is the target of `:Shortcut state`, rather than the start of a
--- state name. `sc-<id>` and links always are. A bare ID only is when it is the only argument:
--- with words after it, `2 Review` is read as a state name, so that a hand-typed name starting
--- with digits never moves another story. (Give the story as `sc-<id>` then.)
---@param args string[]
---@return boolean
local function state_target_first(args)
  local first = args[1]
  if not first or not target.parse_arg(first) then
    return false
  end
  return not first:match('^%d+$') or #args == 1
end

--- Split `[target] [state name...]` (see `state_target_first()`). The state name may contain
--- spaces.
---@param args string[]
---@return string? arg
---@return string? name
function M.state_args(args)
  if #args == 0 then
    return nil, nil
  end
  local first, rest = nil, args
  if state_target_first(args) then
    first, rest = args[1], vim.list_slice(args, 2)
  end
  local name = vim.trim(table.concat(rest, ' '))
  return first, name ~= '' and name or nil
end

--- The states of a workflow, ordered by position.
---@param workflow shortcut.refs.Workflow
---@return shortcut.refs.State[]
local function ordered_states(workflow)
  local states = vim.list_slice(workflow.states or {})
  table.sort(states, function(a, b)
    if a.position ~= b.position then
      return a.position < b.position
    end
    return a.id < b.id
  end)
  return states
end

--- Ask which state to move to. `callback(state?)`.
---@param states shortcut.refs.State[]
---@param current? integer
---@param prompt string
---@param callback fun(state?: shortcut.refs.State)
local function select_state(states, current, prompt, callback)
  vim.ui.select(states, {
    prompt = prompt,
    kind = 'shortcut.state',
    format_item = function(s)
      local name = notify.flatten(s.name)
      return s.id == current and (name .. ' (current)') or name
    end,
  }, function(choice)
    callback(choice)
  end)
end

commands.register('state', {
  desc = 'Change the workflow state of the current story',
  run = function(args)
    local arg, name = M.state_args(args)
    local opts = { command = 'state' }
    run('state', function()
      local http = require('shortcut.http')
      local cache = require('shortcut.cache')
      local t = resolve(arg, opts)
      local story = M.fetch_story(t.id)
      local load_err = async.await(cache.load, { 'workflows' })
      if load_err then
        error(('cannot load the workflows: %s'):format(http.format_error(load_err)), 0)
      end
      local workflow = cache.workflow(story.workflow_id)
      if not workflow then
        error(
          ('workflow %s of sc-%d is not in the lookup lists; try :Shortcut refresh'):format(
            tostring(story.workflow_id),
            t.id
          ),
          0
        )
      end

      local chosen ---@type shortcut.refs.State?
      if name then
        local found, err = cache.state_by_name(workflow.id, name)
        if not found then
          local id = name:match('^(%d+)%s')
          if id then
            err = ('%s; to name story %s, write sc-%s'):format(err, id, id)
          end
          error(err, 0)
        end
        chosen = found
      else
        local prompt = ('State of sc-%d: %s'):format(t.id, notify.flatten(story.name, MAX_TITLE))
        chosen =
          async.await(select_state, ordered_states(workflow), story.workflow_state_id, prompt)
        if not chosen then
          return
        end
      end
      local state_name = notify.flatten(chosen.name)
      if chosen.id == story.workflow_state_id then
        notify.info(('sc-%d is already in %s'):format(t.id, state_name))
        return
      end

      local err =
        async.await(require('shortcut.api.stories').update, t.id, { workflow_state_id = chosen.id })
      if err then
        error(('cannot move sc-%d to %s: %s'):format(t.id, state_name, http.format_error(err)), 0)
      end
      local reload = require('shortcut.buffer.handlers').reload_if_unmodified('story', t.id)
      if reload == 'modified' then
        notify.warn(
          ('sc-%d moved to %s; its buffer has unsaved changes, so its header is now stale'):format(
            t.id,
            state_name
          )
        )
      else
        notify.info(('sc-%d moved to %s'):format(t.id, state_name))
      end
    end)
  end,
  complete = function(arglead, args)
    return M.complete_state(arglead, args)
  end,
})

--- State names to complete: the current story buffer's workflow's, or else every workflow's.
--- Completion cannot wait (callbacks run meanwhile would hit the text lock): if the workflows
--- are not loaded yet, start loading them and offer nothing this time.
---@return string[]
local function state_names()
  local cache = require('shortcut.cache')
  local workflows = cache.workflows()
  if not workflows then
    cache.load({ 'workflows' }, function() end)
    return {}
  end
  local snap = nil ---@type shortcut.story.Snapshot?
  local cur = target.from_buffer(vim.api.nvim_get_current_buf())
  if cur and cur.kind == 'story' then
    snap = story_snapshot(cur.id)
  end
  local list = workflows
  local own = snap and cache.workflow(snap.story.workflow_id)
  if own then
    list = { own }
  end
  local names, seen = {}, {}
  for _, w in ipairs(list) do
    for _, s in ipairs(ordered_states(w)) do
      local n = notify.flatten(s.name)
      if n ~= '' and not seen[n] then
        seen[n] = true
        table.insert(names, n)
      end
    end
  end
  return names
end

--- Completion for `:Shortcut state [target] [state name]`. State names may contain spaces,
--- typed as is or escaped (`In\ Progress`): the words typed so far are matched as a prefix, and
--- the rest of the name is offered, with its spaces escaped.
---@param arglead string
---@param args string[]
---@return string[]
function M.complete_state(arglead, args)
  local words = vim.tbl_map(function(w)
    return (w:gsub('\\(.)', '%1'))
  end, args)
  local lead = arglead:gsub('\\(.)', '%1')
  -- As `state_args()` will read the command line: the word being completed is part of it.
  if #words > 0 and state_target_first(vim.list_extend(vim.list_slice(words), { lead })) then
    table.remove(words, 1)
  end
  local typed = table.concat(words, ' ')
  typed = (typed ~= '' and (typed .. ' ') or '') .. lead
  local offset = #typed - #lead
  local out = {}
  for _, n in ipairs(state_names()) do
    if n:sub(1, #typed):lower() == typed:lower() then
      table.insert(out, (n:sub(offset + 1):gsub('[\\ ]', '\\%0')))
    end
  end
  return out
end

---------------------------------------------------------------------------------------------------
-- refresh
---------------------------------------------------------------------------------------------------

commands.register('refresh', {
  desc = 'Fetch the lookup lists again and reload the current Shortcut buffer',
  run = function(args)
    if #args > 0 then
      error('expected no arguments', 0)
    end
    local cache = require('shortcut.cache')
    cache.clear()
    cache.load(nil, function(err)
      if err then
        notify.error(
          ('refresh: cannot fetch the lookup lists: %s'):format(
            require('shortcut.http').format_error(err)
          )
        )
      else
        notify.info('lookup lists refreshed')
      end
    end)
    local buf = vim.api.nvim_get_current_buf()
    if type(vim.b[buf].shortcut) == 'table' then
      if vim.bo[buf].modified then
        notify.warn('the current buffer has unsaved changes, so it was not reloaded')
      else
        require('shortcut.buffer.handlers').reload(buf)
      end
    end
  end,
})

return M

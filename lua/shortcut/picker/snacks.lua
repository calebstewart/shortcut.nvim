--- Pickers with snacks.nvim (`Snacks.picker`).
---
--- Snacks facts (snacks.nvim 2.31, `lua/snacks/picker/`; checked against the source):
---   - A finder is `fun(opts, ctx)` returning a list of items or an async function `fun(cb)`
---     that calls `cb(item)` per item. It runs in a `snacks.picker.Async` coroutine
---     (`ctx.async`), which waits with `ctx.async:suspend()` and is woken by
---     `ctx.async:resume()`; this is how snacks' own `proc` finder (behind live grep) streams.
---   - With `live = true`, every change to the input reruns the finder (debounced, 200 ms) with
---     the text in `ctx.filter.search`. Rerunning or closing the picker aborts the previous
---     finder task: it stops at its next `suspend()`, and its `abort` handlers run.
---   - A preview is `fun(ctx)` with `ctx.item`, `ctx.preview` (`reset()`, `set_lines()`,
---     `set_title()`, `notify()`, `win.buf`) and `ctx.picker`; `ctx.preview.item` is the item
---     being previewed.
---   - `confirm` is called with the action; the default split/vsplit/tab keys (`<c-s>`, `<c-v>`,
---     `<c-t>`) run it with `action.cmd` set to `split`, `vsplit` or `tab`.
---   - snacks' own GitHub pickers use `<a-b>` to open in the browser and `<c-y>` (input) / `y`
---     (list) to copy, which no default key uses; these pickers do the same.
local core = require('shortcut.picker')
local notify = require('shortcut.notify')

local M = {}

--- How long the cursor must stay on an item before its preview is fetched, in milliseconds.
--- Together with `shortcut.picker.PREVIEW_RATE`, this keeps previews well within the API's
--- rate limit while moving through the list.
M.PREVIEW_DELAY = 300

--- Prefix of the snacks source names (`shortcut_search`, `shortcut_mine`, `shortcut_epics`).
M.SOURCE_PREFIX = 'shortcut_'

---@class shortcut.picker.snacks.State
---@field query string The query for pickers that are not live.
---@field generation integer Bumped when the previewed item changes or the picker closes.
---@field pending? { cancel: fun() } Preview fetch in flight.
---@field last_error? string Last search error shown, so live typing doesn't repeat it.
---@field refs_warned? boolean

---@param state shortcut.picker.snacks.State
---@param err? shortcut.http.Error
---@param summary? shortcut.picker.CollectSummary
local function report(state, err, summary)
  local http = require('shortcut.http')
  if err then
    local msg = http.format_error(err)
    if msg ~= state.last_error then
      state.last_error = msg
      notify.error(msg)
    end
    return
  end
  state.last_error = nil
  if summary and summary.refs_err and not state.refs_warned then
    state.refs_warned = true
    notify.warn(
      ('lookup lists unavailable, showing IDs instead of names: %s'):format(
        http.format_error(summary.refs_err)
      )
    )
  end
end

--- The finder for `source`: searches `ctx.filter.search` for live pickers, `state.query`
--- otherwise, and streams pages into the picker. An aborted run cancels its requests.
---@param source shortcut.picker.Source
---@param state shortcut.picker.snacks.State
---@return fun(opts: table, ctx: table): table|fun(cb: fun(item: table))
function M.finder(source, state)
  return function(_, ctx)
    local query = vim.trim(source.live and ctx.filter.search or state.query)
    if query == '' then
      -- Shortcut rejects empty queries: nothing to show until something is typed.
      return {}
    end
    ---@async
    return function(cb)
      local async = ctx.async
      -- Items received but not yet handed to snacks: `queue[head..tail]`.
      local queue, head, tail = {}, 1, 0
      local done, err, summary = false, nil, nil
      local handle = core.collect(source.kind, query, function(items)
        for _, item in ipairs(items) do
          tail = tail + 1
          queue[tail] = item
        end
        async:resume()
      end, function(e, s)
        done, err, summary = true, e, s
        async:resume()
      end)
      async:on('abort', function()
        handle:cancel()
      end)
      while true do
        if head <= tail then
          local item = queue[head]
          queue[head] = nil
          head = head + 1
          cb(item)
        elseif done then
          break
        else
          async:suspend()
        end
      end
      vim.schedule(function()
        report(state, err, summary)
      end)
    end
  end
end

---@param preview table snacks.picker.Preview
---@param item shortcut.picker.Item
---@param lines string[]
local function show(preview, item, lines)
  preview:reset()
  local buf = preview.win.buf
  -- Remote content: never let it set options.
  vim.bo[buf].modeline = false
  preview:set_title(('sc-%d'):format(item.id))
  preview:set_lines(lines)
  -- Like snacks' own Markdown previews, without triggering FileType autocommands (ftplugins)
  -- for a scratch buffer, and without snacks' image rendering (which would fetch images the
  -- remote content links to).
  local ei = vim.o.eventignore
  vim.o.eventignore = 'all'
  vim.bo[buf].filetype = 'markdown'
  vim.o.eventignore = ei
  vim.bo[buf].modeline = false
  if not pcall(vim.treesitter.start, buf, 'markdown') then
    vim.bo[buf].syntax = 'markdown'
  end
end

---@param state shortcut.picker.snacks.State
local function cancel_preview(state)
  state.generation = state.generation + 1
  if state.pending then
    state.pending.cancel()
    state.pending = nil
  end
end

--- The previewer: the item rendered like its buffer, fetched (after `PREVIEW_DELAY`, and within
--- `shortcut.picker.PREVIEW_RATE`) with the full object, or from the session cache. Shows "Loading…" meanwhile; a result for an item
--- that is no longer previewed is dropped.
---@param state shortcut.picker.snacks.State
---@return fun(ctx: table)
function M.preview(state)
  return function(ctx)
    local item = ctx.item --[[@as shortcut.picker.Item]]
    local preview = ctx.preview
    cancel_preview(state)
    local cached = core.cached_preview(item)
    if cached then
      return show(preview, item, cached)
    end
    preview:reset()
    vim.bo[preview.win.buf].modeline = false
    preview:set_title(('sc-%d'):format(item.id))
    preview:set_lines({ 'Loading…' })
    local generation = state.generation
    local function current()
      return state.generation == generation
        and preview.item == item
        and not ctx.picker.closed
        and preview.win:buf_valid()
    end
    local function fetch()
      if not current() then
        return
      end
      local wait = core.preview_wait()
      if wait > 0 then
        -- Too many previews fetched in the last minute: try again when one is allowed.
        preview:set_lines({ 'Loading… (waiting: many previews were fetched in the last minute)' })
        vim.defer_fn(fetch, wait)
        return
      end
      state.pending = core.preview_lines(item, function(err, lines)
        state.pending = nil
        if not current() then
          return
        end
        if err then
          preview:notify(err, 'error', { item = false })
          return
        end
        ---@cast lines string[]
        show(preview, item, lines)
      end)
    end
    vim.defer_fn(fetch, M.PREVIEW_DELAY)
  end
end

--- Open the selected items (or the current one), in the current window or as `action.cmd`
--- (`split`, `vsplit`, `tab`) asks.
---@param picker table snacks.Picker
---@param action? table
function M.confirm(picker, _, action)
  local items = picker:selected({ fallback = true })
  picker:close()
  local cmd = action and action.cmd or nil
  -- After the picker's windows are gone and insert mode has ended.
  vim.schedule(function()
    for _, item in ipairs(items) do
      core.open(item, cmd)
    end
  end)
end

--- The snacks picker options for `source`.
---@param source shortcut.picker.Source
---@param query string Starting query; empty for the source's default.
---@return table opts
function M.opts(source, query)
  ---@type shortcut.picker.snacks.State
  local state = { query = query, generation = 0 }
  local initial = query ~= '' and query or source.default_query or ''
  local opts = {
    source = M.SOURCE_PREFIX .. source.name,
    title = source.title,
    live = source.live,
    supports_live = source.live,
    search = source.live and initial or nil,
    show_empty = true,
    finder = M.finder(source, state),
    format = function(item)
      return core.format(item)
    end,
    preview = M.preview(state),
    sort = { fields = { 'score:desc', 'idx' } },
    confirm = M.confirm,
    actions = {
      shortcut_copy_url = {
        desc = 'Copy the web link',
        action = function(_, item)
          if item then
            core.copy_url(item)
          end
        end,
      },
      shortcut_browse = {
        desc = 'Open in the browser',
        action = function(_, item)
          if item then
            core.browse(item)
          end
        end,
      },
    },
    win = {
      input = {
        keys = {
          ['<a-b>'] = { 'shortcut_browse', mode = { 'n', 'i' } },
          ['<c-y>'] = { 'shortcut_copy_url', mode = { 'n', 'i' } },
        },
      },
      list = {
        keys = {
          ['<a-b>'] = 'shortcut_browse',
          ['y'] = 'shortcut_copy_url',
        },
      },
    },
    on_close = function()
      cancel_preview(state)
    end,
  }
  -- snacks applies a source's user config (`picker.sources.<name>`) before the options passed
  -- here; apply it on top instead, so users can change keys, layout etc.
  local ok, snacks = pcall(require, 'snacks')
  local user = ok and vim.tbl_get(snacks, 'config', 'picker', 'sources', opts.source) or nil
  if type(user) == 'table' then
    opts = vim.tbl_deep_extend('force', opts, user)
  end
  return opts
end

--- Open a snacks picker for `source`.
---@param source shortcut.picker.Source
---@param query string
---@return table picker
function M.open(source, query)
  core.define_highlights()
  return require('snacks').picker.pick(M.opts(source, query))
end

return M

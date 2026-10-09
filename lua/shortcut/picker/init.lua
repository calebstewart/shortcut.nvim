--- Pickers: `:Shortcut search`, `:Shortcut mine` and `:Shortcut epics`.
---
--- With snacks.nvim (`shortcut.picker.snacks`): live search, streamed pages and previews. Without
--- it (`shortcut.picker.fallback`): `vim.ui.input` for the query, then `vim.ui.select`.
---
--- This module holds what both share and what does not depend on snacks: the queries, turning
--- search results into items, how rows look, fetching previews, and the actions on an item.
---
--- Search operator facts (Shortcut's help center, "Search Operators",
--- https://www.shortcut.com/help/fields-and-features/search-operators, formerly
--- https://help.shortcut.com/hc/en-us/articles/360000046646-Search-Operators):
---   - `owner:<mention name>` (without `@`) finds stories or epics owned by a user,
---   - `is:done`, `is:started`, `is:unstarted`, `is:archived`, ... filter by state type,
---   - prefixing an operator with `!` or `-` negates it,
---   - several operators in a query must all match (AND).
local notify = require('shortcut.notify')

local M = {}

--- Excludes finished and archived work.
M.NOT_DONE = '!is:done !is:archived'

--- What `:Shortcut epics` starts with when given no query (the API rejects an empty one).
M.DEFAULT_EPICS_QUERY = M.NOT_DONE

---@alias shortcut.picker.Name 'search'|'mine'|'epics'

---@class shortcut.picker.Source
---@field name shortcut.picker.Name
---@field kind shortcut.api.search.Kind What is searched.
---@field live boolean Every change to the query searches again.
---@field title string
---@field desc string `:Shortcut help` text.
---@field default_query? string Starting query when none is given.

---@type table<shortcut.picker.Name, shortcut.picker.Source>
M.SOURCES = {
  search = {
    name = 'search',
    kind = 'stories',
    live = true,
    title = 'Shortcut stories',
    desc = 'Search stories (live with snacks.nvim)',
  },
  mine = {
    name = 'mine',
    kind = 'stories',
    live = false,
    title = 'My unfinished stories',
    desc = 'Your unfinished stories',
  },
  epics = {
    name = 'epics',
    kind = 'epics',
    live = true,
    title = 'Shortcut epics',
    desc = 'Search epics (live with snacks.nvim)',
    default_query = M.DEFAULT_EPICS_QUERY,
  },
}

--- Lookup lists the items need, by search kind.
---@type table<shortcut.api.search.Kind, shortcut.refs.Kind[]>
M.REF_KINDS = {
  stories = { 'workflows', 'members' },
  epics = { 'epic_workflow' },
}

--- The object kind of a search kind's results.
---@type table<shortcut.api.search.Kind, shortcut.Kind>
local OBJECT_KIND = { stories = 'story', epics = 'epic' }

--- `:Shortcut mine`'s query.
---@param mention_name string
---@return string
function M.mine_query(mention_name)
  local name = mention_name:gsub('^@', '')
  if name:find('[%s"]') then
    name = '"' .. name:gsub('"', '') .. '"'
  end
  return ('owner:%s %s'):format(name, M.NOT_DONE)
end

---------------------------------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------------------------------

---@class shortcut.picker.Item
---@field text string What the picker matches against.
---@field kind shortcut.Kind
---@field id integer
---@field name string The title, on one line.
---@field state string The state's name (`unknown-<id>` if it can't be looked up).
---@field state_type? string `backlog`, `unstarted`, `started`, `done`, or another type.
---@field story_type? string
---@field owners string[] Mention names.
---@field url? string The web app link, if it is an `https://` URL.

--- Epics' deprecated `state` field, for when the epic workflow is not available.
local LEGACY_EPIC_STATES = { ['to do'] = 'unstarted', ['in progress'] = 'started', done = 'done' }

---@param v any
---@return boolean
local function present(v)
  return v ~= nil and v ~= vim.NIL
end

--- A URL that is safe to open or copy: `https://`, one line, no spaces.
---@param v any
---@return string?
function M.safe_url(v)
  if type(v) ~= 'string' or not v:match('^https://[^%s%c]+$') then
    return nil
  end
  return v
end

--- An item from a search result (`StorySearchResult` or `EpicSearchResult`). Names are looked up
--- in the lookup-list cache (load `REF_KINDS[kind]` first); server strings end up on one line.
---@param kind shortcut.api.search.Kind
---@param obj table
---@return shortcut.picker.Item?
function M.make_item(kind, obj)
  if type(obj) ~= 'table' or type(obj.id) ~= 'number' then
    return nil
  end
  local story = require('shortcut.buffer.story')
  local cache = require('shortcut.cache')
  local one_line = story.one_line
  local state, state_type ---@type string, string?
  local owners = {}
  local story_type ---@type string?
  if kind == 'stories' then
    local st = present(obj.workflow_state_id) and cache.state(obj.workflow_state_id) or nil
    if st then
      state, state_type = st.name, st.type
    else
      state = present(obj.workflow_state_id) and story.unknown(obj.workflow_state_id) or '?'
    end
    for _, id in ipairs(type(obj.owner_ids) == 'table' and obj.owner_ids or {}) do
      local m = cache.member(id)
      table.insert(owners, one_line(m and m.mention_name or story.unknown(id)))
    end
    story_type = type(obj.story_type) == 'string' and one_line(obj.story_type) or nil
  else
    local st = present(obj.epic_state_id) and cache.epic_state(obj.epic_state_id) or nil
    if st then
      state, state_type = st.name, st.type
    elseif type(obj.state) == 'string' and obj.state ~= '' then
      state, state_type = obj.state, LEGACY_EPIC_STATES[obj.state:lower()]
    else
      state = present(obj.epic_state_id) and story.unknown(obj.epic_state_id) or '?'
    end
  end
  state = one_line(state)
  state_type = state_type and state_type ~= '' and one_line(state_type) or nil
  local name = one_line(obj.name)
  local text = table.concat(
    vim.tbl_filter(function(s)
      return s ~= ''
    end, {
      ('sc-%d'):format(obj.id),
      state,
      story_type or '',
      name,
      #owners > 0 and ('@' .. table.concat(owners, ' @')) or '',
    }),
    ' '
  )
  ---@type shortcut.picker.Item
  return {
    text = text,
    kind = OBJECT_KIND[kind],
    id = obj.id,
    name = name,
    state = state,
    state_type = state_type,
    story_type = story_type,
    owners = owners,
    url = M.safe_url(obj.app_url),
  }
end

---------------------------------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------------------------------

--- Highlight group of a state, by state type. Unknown types get a neutral group.
---@type table<string, string>
M.STATE_HL = {
  backlog = 'ShortcutStateBacklog',
  unstarted = 'ShortcutStateUnstarted',
  started = 'ShortcutStateStarted',
  done = 'ShortcutStateDone',
}
M.STATE_HL_OTHER = 'ShortcutStateOther'

--- Story type markers and their highlight groups.
---@type table<string, { [1]: string, [2]: string }>
M.TYPE_MARKERS = {
  feature = { 'feat ', 'ShortcutTypeFeature' },
  bug = { 'bug  ', 'ShortcutTypeBug' },
  chore = { 'chore', 'ShortcutTypeChore' },
}

--- Default links of the highlight groups.
local HIGHLIGHTS = {
  ShortcutId = 'Number',
  ShortcutStateBacklog = 'DiagnosticHint',
  ShortcutStateUnstarted = 'DiagnosticInfo',
  ShortcutStateStarted = 'DiagnosticWarn',
  ShortcutStateDone = 'DiagnosticOk',
  ShortcutTypeFeature = 'Function',
  ShortcutTypeBug = 'DiagnosticError',
  ShortcutTypeChore = 'Constant',
  ShortcutOwners = 'Comment',
}

local highlights_defined = false

--- Define the highlight groups (as default links, so colour schemes and users can change them).
function M.define_highlights()
  for name, link in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  -- Neutral: no attributes of its own.
  vim.api.nvim_set_hl(0, M.STATE_HL_OTHER, { default = true })
  if not highlights_defined then
    highlights_defined = true
    vim.api.nvim_create_autocmd('ColorScheme', {
      group = vim.api.nvim_create_augroup('shortcut.picker.highlights', { clear = true }),
      callback = M.define_highlights,
    })
  end
end

--- Pad `s` with spaces to `width` display cells.
---@param s string
---@param width integer
---@return string
local function pad(s, width)
  local w = vim.api.nvim_strwidth(s)
  return w < width and s .. (' '):rep(width - w) or s
end

--- A row as `{ text, highlight group? }` chunks: `sc-<id>`, the state (highlighted by type), for
--- stories a type marker, the title, and for stories the owners (dimmed).
---@param item shortcut.picker.Item
---@return { [1]: string, [2]: string? }[]
function M.format(item)
  local chunks = {
    { pad(('sc-%d'):format(item.id), 9), 'ShortcutId' },
    { ' ' },
    { pad(item.state, 12), M.STATE_HL[item.state_type or ''] or M.STATE_HL_OTHER },
    { ' ' },
  }
  if item.kind == 'story' then
    local marker = M.TYPE_MARKERS[item.story_type or '']
    table.insert(chunks, marker or { pad(item.story_type or '?', 5) })
    table.insert(chunks, { ' ' })
  end
  table.insert(chunks, { item.name })
  if item.kind == 'story' and #item.owners > 0 then
    table.insert(chunks, { ' ' })
    table.insert(chunks, { '@' .. table.concat(item.owners, ' @'), 'ShortcutOwners' })
  end
  return chunks
end

--- A row as plain text, for `vim.ui.select`: `sc-<id> [state] title`.
---@param item shortcut.picker.Item
---@return string
function M.label(item)
  return ('sc-%d [%s] %s'):format(item.id, item.state, item.name)
end

---------------------------------------------------------------------------------------------------
-- Searching
---------------------------------------------------------------------------------------------------

---@class shortcut.picker.Collect
---@field cancel fun(self: shortcut.picker.Collect)

---@class shortcut.picker.CollectSummary: shortcut.api.search.Summary
---@field refs_err? shortcut.http.Error Set if the lookup lists were unavailable.

--- Search `kind` for `query`, page by page (see `shortcut.api.search.stream`): load the lookup
--- lists, then call `on_items(items)` for each page of results, then `on_done(err, summary)`.
--- Cancelling stops everything in flight; no callback is called after that.
---@param kind shortcut.api.search.Kind
---@param query string
---@param on_items fun(items: shortcut.picker.Item[])
---@param on_done fun(err?: shortcut.http.Error, summary?: shortcut.picker.CollectSummary)
---@return shortcut.picker.Collect
function M.collect(kind, query, on_items, on_done)
  local cache = require('shortcut.cache')
  local search = require('shortcut.api.search')
  local cancelled = false
  local current ---@type { cancel: fun(self: any) }?
  local handle = {
    cancel = function()
      if cancelled then
        return
      end
      cancelled = true
      if current then
        current:cancel()
        current = nil
      end
    end,
  }
  current = cache.load(M.REF_KINDS[kind], function(refs_err)
    current = nil
    if cancelled then
      return
    end
    current = search.stream(kind, query, {}, function(results)
      local items = {}
      for _, obj in ipairs(results) do
        local item = M.make_item(kind, obj)
        if item then
          table.insert(items, item)
        end
      end
      on_items(items)
    end, function(err, summary)
      current = nil
      if cancelled then
        return
      end
      ---@cast summary shortcut.picker.CollectSummary
      summary.refs_err = refs_err
      on_done(err, summary)
    end)
  end)
  return handle
end

---------------------------------------------------------------------------------------------------
-- Previews
---------------------------------------------------------------------------------------------------

--- Previews kept per session.
M.PREVIEW_CACHE_SIZE = 50

---@type table<string, string[]>
local preview_cache = {}
---@type string[] Keys, oldest first.
local preview_order = {}

---@param item shortcut.picker.Item
---@return string
local function preview_key(item)
  return item.kind .. ':' .. item.id
end

--- The cached preview of an item, if any.
---@param item shortcut.picker.Item
---@return string[]?
function M.cached_preview(item)
  return preview_cache[preview_key(item)]
end

---@param key string
---@param lines string[]
local function remember(key, lines)
  if not preview_cache[key] then
    table.insert(preview_order, key)
    while #preview_order > M.PREVIEW_CACHE_SIZE do
      preview_cache[table.remove(preview_order, 1)] = nil
    end
  end
  preview_cache[key] = lines
end

--- Fetch the full object behind an item and render it as its buffer would show it.
--- `callback(err, lines)` runs on the main loop, unless the returned handle is cancelled first.
--- Results are cached for the session (`PREVIEW_CACHE_SIZE` items).
---@param item shortcut.picker.Item
---@param callback fun(err?: string, lines?: string[])
---@return { cancel: fun() }
function M.preview_lines(item, callback)
  local key = preview_key(item)
  local cancelled = false
  local function deliver(err, lines)
    if not cancelled then
      callback(err, lines)
    end
  end
  if preview_cache[key] then
    local lines = preview_cache[key]
    vim.schedule(function()
      deliver(nil, lines)
    end)
    return {
      cancel = function()
        cancelled = true
      end,
    }
  end
  local handle
  if item.kind == 'story' then
    local story = require('shortcut.buffer.story')
    handle = story.fetch(item.id, function(err, obj, epic)
      if err then
        return deliver(err)
      end
      local show_owners = require('shortcut.config').get().tasks.show_owners
      local ok, lines =
        pcall(story.render, obj, story.cache_refs(epic), { show_owners = show_owners })
      if not ok then
        return deliver(tostring(lines))
      end
      remember(key, lines)
      deliver(nil, lines)
    end)
  else
    local epic = require('shortcut.buffer.epic')
    handle = epic.fetch(item.id, function(err, obj, stories)
      if err then
        return deliver(err)
      end
      local ok, lines = pcall(epic.render, obj, stories, epic.cache_refs())
      if not ok then
        return deliver(tostring(lines))
      end
      remember(key, lines)
      deliver(nil, lines)
    end)
  end
  return {
    cancel = function()
      if not cancelled then
        cancelled = true
        handle.cancel()
      end
    end,
  }
end

--- Forget cached previews (for tests).
function M._clear_preview_cache()
  preview_cache, preview_order = {}, {}
end

---------------------------------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------------------------------

--- Window commands run before opening, by snacks' `cmd` of the confirm action.
local WINDOW_CMD = {
  split = 'split',
  vsplit = 'vsplit',
  tab = 'tabnew',
  tabdrop = 'tabnew',
}

--- Open an item's buffer (`shortcut://<kind>/<id>`): in the current window, or after `cmd`
--- (`split`, `vsplit`, `tab`), as snacks' split actions ask.
---@param item shortcut.picker.Item
---@param cmd? string
function M.open(item, cmd)
  local ok, err = pcall(function()
    local win_cmd = cmd and WINDOW_CMD[cmd]
    if win_cmd then
      vim.cmd(win_cmd)
    end
    require('shortcut.buffer.handlers').open(item.kind, item.id)
  end)
  if not ok then
    notify.error(tostring(err))
  end
end

--- Copy an item's web link to the clipboard (the `+` register, or `"` without a clipboard).
---@param item shortcut.picker.Item
---@return boolean ok
function M.copy_url(item)
  if not item.url then
    notify.error(('sc-%d has no web link'):format(item.id))
    return false
  end
  local reg = vim.fn.has('clipboard') == 1 and '+' or '"'
  local ok, err = pcall(vim.fn.setreg, reg, item.url)
  if not ok then
    notify.error(('could not copy the link: %s'):format(tostring(err)))
    return false
  end
  notify.info(('copied %s'):format(item.url))
  return true
end

--- Open an item's web link in the browser.
---@param item shortcut.picker.Item
---@return boolean ok
function M.browse(item)
  if not item.url then
    notify.error(('sc-%d has no web link'):format(item.id))
    return false
  end
  local _, err = vim.ui.open(item.url)
  if err then
    notify.error(('could not open the link: %s'):format(err))
    return false
  end
  return true
end

---------------------------------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------------------------------

--- Whether snacks.nvim's picker is available.
---@return boolean
function M.has_snacks()
  local ok, snacks = pcall(require, 'snacks')
  return ok and type(snacks) == 'table' and snacks.picker ~= nil
end

--- Open a picker. `args` are joined into the starting query. An implementation's
--- `open(source, query)` gets an empty `query` if none was given (except for `mine`, whose
--- query is built here).
---@param name shortcut.picker.Name
---@param args? string[]
function M.run(name, args)
  local source = M.SOURCES[name]
  assert(source, 'unknown picker ' .. tostring(name))
  local query = vim.trim(table.concat(args or {}, ' '))
  local impl = M.has_snacks() and require('shortcut.picker.snacks')
    or require('shortcut.picker.fallback')
  if name ~= 'mine' then
    return impl.open(source, query)
  end
  require('shortcut.http').user(function(err, user)
    if err or not user then
      notify.error(
        err and require('shortcut.http').format_error(err) or 'could not find your mention name'
      )
      return
    end
    impl.open(source, M.mine_query(user.mention_name))
  end)
end

local commands = require('shortcut.commands')
for name, source in pairs(M.SOURCES) do
  commands.register(name, {
    desc = source.desc,
    run = function(args)
      if name == 'mine' and #args > 0 then
        error('expected no arguments', 0)
      end
      M.run(name, args)
    end,
  })
end

return M

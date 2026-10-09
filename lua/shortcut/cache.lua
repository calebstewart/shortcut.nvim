--- Cache of the workspace's lookup lists (workflows and their states, the epic workflow,
--- members, labels, groups and iterations), and name <-> ID lookups on them.
---
--- Stories and epics only carry IDs; renderers turn them into names, and edits turn names back
--- into IDs. The lists are fetched once and kept:
---   - in memory, per workspace,
---   - on disk, in `stdpath('cache')/shortcut/<url_slug>/refs.json` (directory 0700, file
---     0600: it holds member names), written atomically. An unreadable or corrupt file is a
---     miss. The token is never stored.
--- An entry expires `config.cache.ttl` seconds after it was fetched. An expired list is still
--- answered at once (flagged `stale`) while it is refetched in the background, so being offline
--- never makes callers wait. Without any copy, callers wait for the fetch; callers asking while
--- a fetch is running share it. After a failed fetch, the list is not fetched again for
--- `RETRY_FAILED_AFTER` seconds: callers get the expired copy, or the error, immediately.
---
--- The workspace is the token's (`http.user()`), so switching tokens never mixes lists.
---
--- `get()`/`load()` are asynchronous. The lookups (`state()`, `member_by_mention()`, ...) are
--- synchronous and use what was last loaded for the workspace: `load()` the lists first.
--- Returned records are shared: do not modify them.
local config = require('shortcut.config')
local fs = require('shortcut.fs')
local http = require('shortcut.http')
local refs = require('shortcut.api.refs')

local M = {}

--- Format of `refs.json`. A file with another version is ignored (and replaced).
M.VERSION = 1

M.KINDS = refs.KINDS

--- Seconds during which a failed fetch is not retried.
M.RETRY_FAILED_AFTER = 60

---@class shortcut.cache.Entry
---@field fetched_at integer `os.time()` when fetched.
---@field data any
---@field index? table Built on demand: lookups by ID.

---@class shortcut.cache.File
---@field version integer
---@field url_slug string
---@field lists table<shortcut.refs.Kind, shortcut.cache.Entry>

--- Set when `data` is an expired copy.
---@class shortcut.cache.Info
---@field stale true
---@field refreshing boolean A refetch is in progress.
---@field err? shortcut.http.Error Why the last refetch failed, if it did (recently).

---@alias shortcut.cache.Callback fun(err?: shortcut.http.Error, data?: any, info?: shortcut.cache.Info)

---@class shortcut.cache.Waiter
---@field callback shortcut.cache.Callback
---@field done boolean

---@class shortcut.cache.Flight
---@field waiters shortcut.cache.Waiter[]
---@field generation integer
---@field handle? shortcut.http.Handle

--- Lists in memory, by workspace slug (lowercase).
---@type table<string, table<shortcut.refs.Kind, shortcut.cache.Entry>>
local memory = {}

--- Fetches in progress, by `<slug>/<kind>`.
---@type table<string, shortcut.cache.Flight>
local inflight = {}

--- Recently failed fetches, by `<slug>/<kind>`.
---@type table<string, { err: shortcut.http.Error, at: integer }>
local failures = {}

--- Bumped by `clear()`: fetches started before are not stored.
local generation = 0

--- The workspace of the latest `get()`: the one lookups use.
---@type string?
local current

--- Paths whose write failure has been reported.
---@type table<string, true>
local warned = {}

--- Current time, in seconds. Replaced in tests.
---@return integer
function M._now()
  return os.time()
end

---------------------------------------------------------------------------------------------------
-- Disk
---------------------------------------------------------------------------------------------------

--- Directory of every workspace's cache.
---@return string
function M.root()
  return vim.fs.joinpath(vim.fn.stdpath('cache') --[[@as string]], 'shortcut')
end

--- A slug as a directory name: lowercase, anything but letters, digits, `-` and `_`
--- percent-encoded (slugs are `[a-z0-9-]` in practice; this just keeps out `/` and `..`).
---@param slug string
---@return string
local function dir_name(slug)
  return (slug:lower():gsub('[^%w%-_]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

--- The cache file of a workspace.
---@param slug string
---@return string
function M.path(slug)
  return vim.fs.joinpath(M.root(), dir_name(slug), 'refs.json')
end

---@param entry any
---@return boolean
local function valid_entry(entry)
  return type(entry) == 'table'
    and type(entry.fetched_at) == 'number'
    and type(entry.data) == 'table'
end

--- Read a workspace's cache file. Anything unexpected counts as no file.
---@param slug string
---@return shortcut.cache.File?
local function read_disk(slug)
  local data = fs.read_file(M.path(slug))
  if not data then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
  if
    not ok
    or type(decoded) ~= 'table'
    or decoded.version ~= M.VERSION
    or type(decoded.url_slug) ~= 'string'
    or decoded.url_slug:lower() ~= slug
    or type(decoded.lists) ~= 'table'
  then
    return nil
  end
  local lists = {}
  for _, kind in ipairs(M.KINDS) do
    local entry = decoded.lists[kind]
    if valid_entry(entry) then
      lists[kind] = { fetched_at = entry.fetched_at, data = entry.data }
    end
  end
  return { version = M.VERSION, url_slug = slug, lists = lists }
end

--- Store one list in a workspace's cache file, keeping the others.
---@param slug string
---@param kind shortcut.refs.Kind
---@param entry shortcut.cache.Entry
local function write_disk(slug, kind, entry)
  local path = M.path(slug)
  local file = read_disk(slug) or { version = M.VERSION, url_slug = slug, lists = {} }
  file.lists[kind] = { fetched_at = entry.fetched_at, data = entry.data }
  local private = tonumber('700', 8)
  local ok, err = fs.mkdir_p(M.root(), private)
  if ok then
    ok, err = fs.mkdir_p(vim.fs.dirname(path), private)
  end
  if ok then
    ok, err = fs.write_atomic(path, vim.json.encode(file))
  end
  if not ok and not warned[path] then
    warned[path] = true
    require('shortcut.notify').warn(
      ('cannot save the lookup-list cache (%s); lists will be fetched again next session'):format(
        err
      )
    )
  end
end

---------------------------------------------------------------------------------------------------
-- get / load
---------------------------------------------------------------------------------------------------

---@param entry? shortcut.cache.Entry
---@return boolean
local function fresh(entry)
  if not entry then
    return false
  end
  local age = M._now() - entry.fetched_at
  return age >= 0 and age < config.get().cache.ttl
end

---@param waiter shortcut.cache.Waiter
---@param err? shortcut.http.Error
---@param data? any
---@param info? shortcut.cache.Info
local function deliver(waiter, err, data, info)
  if waiter.done then
    return
  end
  waiter.done = true
  -- One failing callback must not keep the others from being called.
  local ok, cb_err = pcall(waiter.callback, err, data, info)
  if not ok then
    require('shortcut.notify').error(vim.split(tostring(cb_err), '\n', { plain = true })[1])
  end
end

---@param slug string
---@param kind shortcut.refs.Kind
---@param entry shortcut.cache.Entry
local function remember(slug, kind, entry)
  memory[slug] = memory[slug] or {}
  memory[slug][kind] = entry
end

--- The error of a fetch that failed less than `RETRY_FAILED_AFTER` seconds ago.
---@param key string
---@return shortcut.http.Error?
local function recent_failure(key)
  local failure = failures[key]
  if not failure then
    return nil
  end
  local age = M._now() - failure.at
  if age >= 0 and age < M.RETRY_FAILED_AFTER then
    return failure.err
  end
  failures[key] = nil
  return nil
end

--- Start fetching a list. Its waiters get the result; the cache is only updated if `clear()` was
--- not called meanwhile.
---@param slug string
---@param kind shortcut.refs.Kind
---@param key string
---@return shortcut.cache.Flight
local function start_fetch(slug, kind, key)
  ---@type shortcut.cache.Flight
  local flight = { waiters = {}, generation = generation }
  inflight[key] = flight
  flight.handle = refs.fetch(kind, function(err, data)
    if inflight[key] == flight then
      inflight[key] = nil
    end
    local current_generation = flight.generation == generation
    local slim
    if not err then
      local slim_err
      slim, slim_err = refs.slim(kind, data)
      if not slim then
        err = { kind = 'decode', message = slim_err, method = 'GET', path = refs.path(kind) }
      end
    end
    if err then
      if current_generation then
        failures[key] = { err = err, at = M._now() }
      end
      for _, w in ipairs(flight.waiters) do
        deliver(w, err)
      end
      return
    end
    if current_generation then
      failures[key] = nil
      local entry = { fetched_at = M._now(), data = slim }
      remember(slug, kind, entry)
      write_disk(slug, kind, entry)
    end
    for _, w in ipairs(flight.waiters) do
      deliver(w, nil, slim)
    end
  end)
  return flight
end

---@param slug string
---@param kind shortcut.refs.Kind
---@param waiter shortcut.cache.Waiter
local function get_in(slug, kind, waiter)
  local mem = memory[slug] and memory[slug][kind]
  if fresh(mem) then
    return deliver(waiter, nil, mem.data)
  end
  local key = slug .. '/' .. kind
  local flight = inflight[key]
  -- The newest expired copy.
  local stale = mem
  if not flight then
    local file = read_disk(slug)
    local disk = file and file.lists[kind]
    if fresh(disk) then
      ---@cast disk shortcut.cache.Entry
      remember(slug, kind, disk)
      return deliver(waiter, nil, disk.data)
    end
    if disk and (not stale or disk.fetched_at > stale.fetched_at) then
      stale = disk
    end
  end
  local failed = recent_failure(key)
  if stale then
    -- Answer now; refresh in the background.
    if not flight and not failed then
      flight = start_fetch(slug, kind, key)
    end
    remember(slug, kind, stale)
    return deliver(
      waiter,
      nil,
      stale.data,
      { stale = true, refreshing = flight ~= nil, err = failed }
    )
  end
  if failed then
    return deliver(waiter, failed)
  end
  flight = flight or start_fetch(slug, kind, key)
  table.insert(flight.waiters, waiter)
end

---@class shortcut.cache.Handle
---@field cancel fun(self: shortcut.cache.Handle)

--- A lookup list of the token's workspace: from memory, else from disk, else fetched.
--- `callback(err, data, info)` runs on the main loop. `data` is a list of `shortcut.refs.*`
--- records (for `epic_workflow`, a `shortcut.refs.EpicWorkflow`); do not modify it. If the list
--- expired, `data` is the expired copy and `info` says so (and why the last refetch failed, if
--- it did). `err` is set only when there is no copy at all.
---
--- Cancelling the returned handle only drops this callback: a fetch it started continues for the
--- other callers and the cache.
---@param kind shortcut.refs.Kind
---@param callback shortcut.cache.Callback
---@return shortcut.cache.Handle
function M.get(kind, callback)
  vim.validate('kind', kind, refs.is_kind, 'lookup list kind')
  vim.validate('callback', callback, 'function')
  ---@type shortcut.cache.Waiter
  local waiter = { callback = callback, done = false }
  http.user(function(err, user)
    if waiter.done then
      return
    end
    if err or not user then
      return deliver(waiter, err)
    end
    local slug = user.url_slug:lower()
    current = slug
    get_in(slug, kind, waiter)
  end)
  return {
    cancel = function()
      waiter.done = true
    end,
  }
end

--- Load several lists (default: all of them) in parallel, for the synchronous lookups.
--- `callback(err, stale)` runs once all are loaded, or with the first error. `stale` lists the
--- kinds answered with an expired copy (see `get()`), or is `nil` if every list is fresh.
---@param kinds? shortcut.refs.Kind[]
---@param callback fun(err?: shortcut.http.Error, stale?: table<shortcut.refs.Kind, shortcut.cache.Info>)
---@return shortcut.cache.Handle
function M.load(kinds, callback)
  vim.validate('kinds', kinds, 'table', true)
  vim.validate('callback', callback, 'function')
  kinds = kinds or M.KINDS
  local handles = {} ---@type shortcut.cache.Handle[]
  local remaining, finished = #kinds, false
  local stale = nil ---@type table<shortcut.refs.Kind, shortcut.cache.Info>?
  ---@param err? shortcut.http.Error
  local function finish(err)
    if finished then
      return
    end
    finished = true
    for _, h in ipairs(handles) do
      h:cancel()
    end
    callback(err, not err and stale or nil)
  end
  if remaining == 0 then
    vim.schedule(function()
      if not finished then
        finish()
      end
    end)
  end
  for _, kind in ipairs(kinds) do
    table.insert(
      handles,
      M.get(kind, function(err, _, info)
        if err then
          return finish(err)
        end
        if info then
          stale = stale or {}
          stale[kind] = info
        end
        remaining = remaining - 1
        if remaining == 0 then
          finish()
        end
      end)
    )
  end
  return {
    cancel = function()
      finished = true
      for _, h in ipairs(handles) do
        h:cancel()
      end
    end,
  }
end

--- Forget every list, in memory and on disk, for every workspace, and any failed fetch. Fetches
--- in progress still answer the callers waiting for them, but are not stored.
function M.clear()
  memory = {}
  inflight = {}
  failures = {}
  generation = generation + 1
  local root = M.root()
  for name, ftype in vim.fs.dir(root) do
    if ftype == 'directory' then
      local dir = vim.fs.joinpath(root, name)
      for file in vim.fs.dir(dir) do
        -- The cache file, and temporary files left by an interrupted write.
        if file == 'refs.json' or file:match('^%.refs%.json%..*%.tmp$') then
          vim.uv.fs_unlink(vim.fs.joinpath(dir, file))
        end
      end
      -- Only if nothing else is in it.
      vim.uv.fs_rmdir(dir)
    end
  end
end

--- Bumped by every `clear()`: data derived from the lists (e.g. picker previews) made under
--- another generation is outdated.
---@return integer
function M.generation()
  return generation
end

--- What is cached on disk, for `:checkhealth`.
---@return { slug: string, path: string, lists?: table<shortcut.refs.Kind, { fetched_at: integer, count: integer }>, invalid?: boolean }[]
function M.disk_info()
  local out = {}
  local root = M.root()
  for name, ftype in vim.fs.dir(root) do
    local path = vim.fs.joinpath(root, name, 'refs.json')
    if ftype == 'directory' and fs.exists(path) then
      -- Directory names are lowercase slugs, encoded only if unusual.
      local slug = name:gsub('%%(%x%x)', function(h)
        return string.char(tonumber(h, 16))
      end)
      local file = read_disk(slug)
      if not file then
        table.insert(out, { slug = slug, path = path, invalid = true })
      else
        local lists = {}
        for kind, entry in pairs(file.lists) do
          local data = entry.data
          lists[kind] = {
            fetched_at = entry.fetched_at,
            count = kind == 'epic_workflow' and #(data.epic_states or {}) or #data,
          }
        end
        table.insert(out, { slug = slug, path = path, lists = lists })
      end
    end
  end
  table.sort(out, function(a, b)
    return a.slug < b.slug
  end)
  return out
end

--- The workspace lookups use (the latest `get()`'s), if any.
---@return string?
function M.workspace()
  return current
end

---------------------------------------------------------------------------------------------------
-- Lookups
---------------------------------------------------------------------------------------------------

---@param kind shortcut.refs.Kind
---@return shortcut.cache.Entry?
local function loaded(kind)
  return current and memory[current] and memory[current][kind] or nil
end

--- Records of a list by ID. For `workflows`, states by ID.
---@param kind shortcut.refs.Kind
---@return table<integer|string, table>?
local function index(kind)
  local entry = loaded(kind)
  if not entry then
    return nil
  end
  if not entry.index then
    local idx = {}
    if kind == 'workflows' then
      for _, w in ipairs(entry.data) do
        for _, s in ipairs(w.states or {}) do
          idx[s.id] = s
        end
      end
    elseif kind == 'epic_workflow' then
      for _, s in ipairs(entry.data.epic_states or {}) do
        idx[s.id] = s
      end
    else
      for _, item in ipairs(entry.data) do
        idx[item.id] = item
      end
    end
    entry.index = idx
  end
  return entry.index
end

--- A workflow state by ID.
---@param id integer
---@return shortcut.refs.State?
function M.state(id)
  local idx = index('workflows')
  return idx and idx[id] --[[@as shortcut.refs.State?]]
end

--- Every workflow, as last loaded, or `nil` if the list is not loaded.
---@return shortcut.refs.Workflow[]?
function M.workflows()
  local entry = loaded('workflows')
  return entry and entry.data or nil
end

--- A whole list, as last loaded, or `nil` if it is not loaded (e.g. for completion).
---@param kind shortcut.refs.Kind
---@return any?
function M.list(kind)
  local entry = loaded(kind)
  return entry and entry.data or nil
end

--- A workflow by ID.
---@param id integer
---@return shortcut.refs.Workflow?
function M.workflow(id)
  local entry = loaded('workflows')
  for _, w in ipairs(entry and entry.data or {}) do
    if w.id == id then
      return w
    end
  end
  return nil
end

--- An epic state by ID.
---@param id integer
---@return shortcut.refs.EpicState?
function M.epic_state(id)
  local idx = index('epic_workflow')
  return idx and idx[id] --[[@as shortcut.refs.EpicState?]]
end

--- A member by UUID.
---@param id string
---@return shortcut.refs.Member?
function M.member(id)
  local idx = index('members')
  return idx and idx[id] --[[@as shortcut.refs.Member?]]
end

--- A label by ID.
---@param id integer
---@return shortcut.refs.Label?
function M.label(id)
  local idx = index('labels')
  return idx and idx[id] --[[@as shortcut.refs.Label?]]
end

--- An iteration by ID.
---@param id integer
---@return shortcut.refs.Iteration?
function M.iteration(id)
  local idx = index('iterations')
  return idx and idx[id] --[[@as shortcut.refs.Iteration?]]
end

--- A group (team) by UUID.
---@param id string
---@return shortcut.refs.Group?
function M.group(id)
  local idx = index('groups')
  return idx and idx[id] --[[@as shortcut.refs.Group?]]
end

--- Levenshtein distance between two (short) strings.
---@param a string
---@param b string
---@return integer
local function distance(a, b)
  if a == b then
    return 0
  end
  local prev = {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    local cur = { [0] = i }
    local ca = a:byte(i)
    for j = 1, #b do
      local cost = ca == b:byte(j) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[#b]
end

--- Up to three names close to `wanted`: containing it, or a few edits away.
---@param wanted string
---@param names string[]
---@return string[]
local function close_matches(wanted, names)
  local w = wanted:lower()
  local limit = math.max(2, math.floor(#w / 3))
  local scored, seen = {}, {}
  for _, name in ipairs(names) do
    local n = name:lower()
    if not seen[n] then
      seen[n] = true
      local d = distance(w, n)
      if #w >= 2 and n:find(w, 1, true) then
        d = math.min(d, 1)
      end
      if d <= limit then
        table.insert(scored, { name = name, d = d })
      end
    end
  end
  table.sort(scored, function(x, y)
    if x.d ~= y.d then
      return x.d < y.d
    end
    return x.name < y.name
  end)
  local out = {}
  for i = 1, math.min(3, #scored) do
    out[i] = scored[i].name
  end
  return out
end

---@generic T
---@param what string E.g. `label`.
---@param items T[]
---@param wanted string
---@param names_of fun(item: T): string[] The names an item answers to.
---@param prefer? fun(item: T): boolean Breaks ties between several matches (e.g. not archived).
---@param where? string Appended to the "unknown" message, e.g. ` in workflow 'X'`.
---@return T? item
---@return string? err
local function find(what, items, wanted, names_of, prefer, where)
  where = where or ''
  local function matches(eq)
    local out = {}
    for _, item in ipairs(items) do
      for _, name in ipairs(names_of(item)) do
        if eq(name) then
          table.insert(out, item)
          break
        end
      end
    end
    return out
  end
  local lower = wanted:lower()
  for _, found in ipairs({
    matches(function(n)
      return n == wanted
    end),
    matches(function(n)
      return n:lower() == lower
    end),
  }) do
    if #found > 1 and prefer then
      local preferred = vim.tbl_filter(prefer, found)
      if #preferred == 1 then
        found = preferred
      end
    end
    if #found == 1 then
      return found[1]
    elseif #found > 1 then
      local ids = vim.tbl_map(function(item)
        return tostring(item.id)
      end, found)
      return nil,
        ("ambiguous %s '%s'%s: matches IDs %s"):format(what, wanted, where, table.concat(ids, ', '))
    end
  end
  local all = {}
  for _, item in ipairs(items) do
    vim.list_extend(all, names_of(item))
  end
  local close = close_matches(wanted, all)
  local hint = #close > 0
      and (' (did you mean %s?)'):format(table.concat(
        vim.tbl_map(function(n)
          return "'" .. n .. "'"
        end, close),
        ', '
      ))
    or ''
  return nil, ("unknown %s '%s'%s%s"):format(what, wanted, where, hint)
end

---@param kind shortcut.refs.Kind
---@return any? data
---@return string? err
local function list(kind)
  local entry = loaded(kind)
  if not entry then
    return nil, ('the %s list is not loaded'):format((kind:gsub('_', ' ')))
  end
  return entry.data
end

---@param item { name: string }
---@return string[]
local function name_of(item)
  return { item.name }
end

--- A workflow state by name, within one workflow (names are only unique there). Exact match
--- first, then ignoring case.
---@param workflow_id integer
---@param name string
---@return shortcut.refs.State? state
---@return string? err
function M.state_by_name(workflow_id, name)
  local _, err = list('workflows')
  if err then
    return nil, err
  end
  local workflow = M.workflow(workflow_id)
  if not workflow then
    return nil, ('unknown workflow %s'):format(tostring(workflow_id))
  end
  return find(
    'state',
    workflow.states,
    vim.trim(name),
    name_of,
    nil,
    (" in workflow '%s'"):format(workflow.name)
  )
end

--- An epic state by name, ignoring case.
---@param name string
---@return shortcut.refs.EpicState? state
---@return string? err
function M.epic_state_by_name(name)
  local data, err = list('epic_workflow')
  if not data then
    return nil, err
  end
  return find('epic state', data.epic_states, vim.trim(name), name_of)
end

--- A member by mention name, ignoring case and an optional leading `@`. Disabled members are
--- found too: check `disabled`.
---@param mention string
---@return shortcut.refs.Member? member
---@return string? err
function M.member_by_mention(mention)
  local data, err = list('members')
  if not data then
    return nil, err
  end
  return find('member', data, (vim.trim(mention):gsub('^@', '')), function(m)
    return { m.mention_name }
  end, function(m)
    return not m.disabled
  end)
end

--- A label by name, ignoring case. Between labels differing only in case or archived state, the
--- exact or unarchived one wins.
---@param name string
---@return shortcut.refs.Label? label
---@return string? err
function M.label_by_name(name)
  local data, err = list('labels')
  if not data then
    return nil, err
  end
  ---@param l shortcut.refs.Label
  return find('label', data, vim.trim(name), name_of, function(l)
    return not l.archived
  end)
end

--- An iteration by name, ignoring case. Iteration names need not be unique: several matches are
--- an error, unless only one of them is not done.
---@param name string
---@return shortcut.refs.Iteration? iteration
---@return string? err
function M.iteration_by_name(name)
  local data, err = list('iterations')
  if not data then
    return nil, err
  end
  ---@param i shortcut.refs.Iteration
  return find('iteration', data, vim.trim(name), name_of, function(i)
    return i.status ~= 'done'
  end)
end

--- A group (team) by name or mention name (with an optional leading `@`), ignoring case.
---@param name string
---@return shortcut.refs.Group? group
---@return string? err
function M.group_by_name(name)
  local data, err = list('groups')
  if not data then
    return nil, err
  end
  local wanted = vim.trim(name)
  return find('team', data, wanted:sub(1, 1) == '@' and wanted:sub(2) or wanted, function(g)
    return { g.name, g.mention_name }
  end, function(g)
    return not g.archived
  end)
end

--- Forget the in-memory state without touching the disk (for tests).
function M._reset()
  memory = {}
  inflight = {}
  failures = {}
  current = nil
  warned = {}
  generation = generation + 1
end

return M

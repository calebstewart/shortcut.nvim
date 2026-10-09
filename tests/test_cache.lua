local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local TOKEN = 'test-token-0000-1111-2222-3333wxyz'
local TOKEN2 = 'test-token-9999-8888-7777-6666abcd'

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua(
        [[
        local token, token2 = ...
        vim.env.SHORTCUT_API_TOKEN = token
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        dofile('tests/fake_transport.lua')

        _G.cache = require('shortcut.cache')
        _G.now = 1000000
        cache._now = function() return _G.now end

        -- Requests per path; `_G.fail[path] = status` makes a path fail.
        _G.counts, _G.fail = {}, {}
        local fixtures = {
          ['/workflows'] = 'workflows',
          ['/epic-workflow'] = 'epic_workflow',
          ['/members'] = 'members',
          ['/labels'] = 'labels',
          ['/groups'] = 'groups',
          ['/iterations'] = 'iterations',
        }
        _G.routes = function(req)
          local path = req.url:gsub('^https://api%.app%.shortcut%.com/api/v3', ''):gsub('%?.*', '')
          _G.counts[path] = (_G.counts[path] or 0) + 1
          if _G.fail[path] then
            return { status = _G.fail[path], body = '{}' }
          end
          local other = vim.tbl_contains(req.headers, 'Shortcut-Token: ' .. token2)
          if path == '/member' then
            return { status = 200, fixture = other and 'member_other' or 'member' }
          end
          if other and path == '/labels' then
            return { status = 200, body = '[{"id": 9, "name": "other-label", "archived": false}]' }
          end
          return { status = 200, fixture = fixtures[path] }
        end

        function _G.get(kind)
          local r
          cache.get(kind, function(err, data, info) r = { err = err, data = data, info = info } end)
          vim.wait(2000, function() return r ~= nil end, 2)
          return r
        end

        function _G.load(kinds)
          local r
          cache.load(kinds, function(err) r = { err = err } end)
          vim.wait(2000, function() return r ~= nil end, 2)
          return r
        end

        --- A new session: nothing in memory, identity forgotten.
        function _G.new_session()
          cache._reset()
          require('shortcut.http')._clear_cache()
        end
      ]],
        { TOKEN, TOKEN2 }
      )
    end,
    post_once = child.stop,
  },
})

local function get(kind)
  return child.lua_get('_G.get(...)', { kind })
end

local function count(path)
  return child.lua_get('_G.counts[...] or 0', { path })
end

local function names(list)
  return vim.tbl_map(function(x)
    return x.name
  end, list)
end

---@param slug string
---@return string
local function cache_file(slug)
  return child.lua_get('cache.path(...)', { slug })
end

T['get()'] = new_set()

T['get()']['fetches a list once, then answers from memory'] = function()
  local r = get('labels')
  eq(r.err, nil)
  eq(r.info, nil)
  eq(names(r.data), { 'bug', 'Frontend', 'old-label' })
  eq(get('labels').data, r.data)
  eq(count('/labels'), 1)
  eq(child.lua_get('cache.workspace()'), 'acme')
end

T['get()']['stores lists on disk, privately, without the token'] = function()
  get('labels')
  get('members')
  local path = cache_file('acme')
  local root = child.lua_get('vim.fn.stdpath("cache")')
  eq(path, root .. '/shortcut/acme/refs.json')
  -- Inside the test's temporary HOME, not the real cache.
  eq(vim.startswith(root, child.lua_get('vim.uv.fs_realpath(vim.env.HOME)')), true)
  eq(child.lua_get('vim.fn.getfperm(...)', { path }), 'rw-------')
  eq(child.lua_get('vim.fn.getfperm(vim.fs.dirname(...))', { path }), 'rwx------')

  local raw = table.concat(child.lua_get('vim.fn.readfile(...)', { path }), '\n')
  eq(raw:find(TOKEN, 1, true), nil)
  eq(raw:find('@example.com', 1, true), nil)
  local file = vim.json.decode(raw)
  eq(file.version, 1)
  eq(file.url_slug, 'acme')
  eq(file.lists.labels.fetched_at, 1000000)
  eq(#file.lists.labels.data, 3)
  eq(#file.lists.members.data, 3)
end

T['get()']['falls back to disk in a new session'] = function()
  get('labels')
  child.lua('_G.new_session()')
  local r = get('labels')
  eq(r.err, nil)
  eq(names(r.data), { 'bug', 'Frontend', 'old-label' })
  eq(count('/labels'), 1)
end

T['get()']['refetches after the TTL, in memory and on disk'] = function()
  get('labels')
  child.lua('_G.now = _G.now + 24 * 60 * 60 - 1')
  get('labels')
  eq(count('/labels'), 1)
  child.lua('_G.now = _G.now + 1')
  get('labels')
  eq(count('/labels'), 2)

  -- The disk copy was refreshed too.
  child.lua('_G.new_session(); _G.now = _G.now + 10')
  get('labels')
  eq(count('/labels'), 2)
  child.lua('_G.new_session(); _G.now = _G.now + 24 * 60 * 60')
  get('labels')
  eq(count('/labels'), 3)
end

T['get()']['uses config.cache.ttl'] = function()
  child.lua([[require('shortcut').setup({ cache = { ttl = 60 } })]])
  get('labels')
  child.lua('_G.now = _G.now + 60')
  get('labels')
  eq(count('/labels'), 2)
end

T['get()']['an entry from the future counts as expired'] = function()
  get('labels')
  child.lua('_G.now = _G.now - 3600')
  get('labels')
  eq(count('/labels'), 2)
end

T['get()']['concurrent callers share one fetch'] = function()
  child.lua([[
    _G.results = {}
    for i = 1, 3 do
      cache.get('members', function(err, data) _G.results[i] = { err = err, n = #data } end)
    end
    vim.wait(2000, function() return #_G.results == 3 end, 2)
  ]])
  eq(child.lua_get('_G.results'), { { n = 3 }, { n = 3 }, { n = 3 } })
  eq(count('/members'), 1)
  eq(count('/member'), 1)
end

T['get()']['a cancelled caller is not called; the fetch still fills the cache'] = function()
  child.lua([[
    _G.called = false
    cache.get('labels', function() _G.called = true end):cancel()
    vim.wait(50)
  ]])
  eq(child.lua_get('_G.called'), false)
  get('labels')
  eq(count('/labels'), 1)
end

T['get()']['reports a failed fetch'] = function()
  child.lua([[_G.fail['/labels'] = 500]])
  local r = get('labels')
  eq(r.err.status, 500)
  eq(r.data, nil)
  -- Not remembered.
  child.lua([[_G.fail['/labels'] = nil]])
  eq(get('labels').err, nil)
  eq(count('/labels'), 2)
end

T['get()']['uses the expired copy when refetching fails'] = function()
  get('labels')
  child.lua([[_G.fail['/labels'] = 503; _G.now = _G.now + 2 * 24 * 60 * 60]])
  local r = get('labels')
  eq(r.err, nil)
  eq(names(r.data), { 'bug', 'Frontend', 'old-label' })
  eq(r.info.stale, true)
  eq(r.info.err.status, 503)

  -- Also from disk in a new session.
  child.lua('_G.new_session()')
  r = get('labels')
  eq(r.info.stale, true)
  eq(#r.data, 3)
end

T['get()']['reports a response of the wrong shape'] = function()
  child.lua([[
    local routes = _G.routes
    _G.routes = function(req)
      if req.url:find('/labels') then return { status = 200, body = '{"not": "a list"}' } end
      return routes(req)
    end
  ]])
  local r = get('labels')
  eq(r.err.kind, 'decode')
  eq(r.err.message, 'unexpected response from GET /labels')
end

T['get()']['reports a missing token'] = function()
  child.lua('vim.env.SHORTCUT_API_TOKEN = nil; require("shortcut.auth").reset()')
  local r = get('labels')
  eq(r.err.kind, 'auth')
  eq(child.lua_get('_G.requests'), {})
end

T['get()']['treats a corrupt or unreadable file as a miss'] = function()
  get('labels')
  local path = cache_file('acme')
  for _, content in ipairs({
    'not json',
    '[]',
    '{"version": 99, "url_slug": "acme", "lists": {}}',
    '{"version": 1, "url_slug": "other", "lists": {"labels": {"fetched_at": 1000000, "data": []}}}',
    '{"version": 1, "url_slug": "acme", "lists": {"labels": {"fetched_at": "x", "data": []}}}',
  }) do
    child.lua('vim.fn.writefile({ ... }, select(2, ...))', { content, path })
    child.lua('_G.new_session()')
    local before = count('/labels')
    local r = get('labels')
    eq(r.err, nil)
    eq(#r.data, 3)
    eq(count('/labels'), before + 1)
    -- Replaced by a valid file.
    eq(vim.json.decode(child.lua_get('vim.fn.readfile(...)[1]', { path })).version, 1)
  end

  if child.lua_get('vim.uv.getuid()') ~= 0 then
    child.lua('vim.uv.fs_chmod(..., 0)', { path })
    child.lua('_G.new_session()')
    local before = count('/labels')
    eq(#get('labels').data, 3)
    eq(count('/labels'), before + 1)
  end
end

T['get()']['warns once if the cache cannot be written'] = function()
  -- A file where the cache directory should be.
  child.lua([[
    local root = cache.root()
    vim.fn.mkdir(vim.fs.dirname(root), 'p')
    vim.fn.writefile({}, root)
  ]])
  eq(get('labels').err, nil)
  eq(get('members').err, nil)
  local msgs = child.lua_get('_G.messages')
  eq(#msgs, 1)
  eq(msgs[1].msg:find('cannot save the lookup%-list cache') ~= nil, true)
end

T['get()']['keeps workspaces apart'] = function()
  eq(names(get('labels').data), { 'bug', 'Frontend', 'old-label' })
  child.lua('vim.env.SHORTCUT_API_TOKEN = ...; require("shortcut.auth").reset()', { TOKEN2 })
  eq(names(get('labels').data), { 'other-label' })
  eq(child.lua_get('cache.workspace()'), 'other')
  eq(count('/labels'), 2)
  eq(child.lua_get('vim.uv.fs_stat(...) ~= nil', { cache_file('acme') }), true)
  eq(child.lua_get('vim.uv.fs_stat(...) ~= nil', { cache_file('other') }), true)

  -- Back to the first token: its lists are still cached.
  child.lua('vim.env.SHORTCUT_API_TOKEN = ...; require("shortcut.auth").reset()', { TOKEN })
  eq(names(get('labels').data), { 'bug', 'Frontend', 'old-label' })
  eq(count('/labels'), 2)
end

T['get()']['the cache directory name cannot escape the cache root'] = function()
  local root = child.lua_get('cache.root()')
  eq(cache_file('../x/..'), root .. '/%2E%2E%2Fx%2F%2E%2E/refs.json')
  eq(cache_file('Acme'), root .. '/acme/refs.json')
end

T['clear()'] = new_set()

T['clear()']['empties memory and disk'] = function()
  get('labels')
  local path = cache_file('acme')
  eq(child.lua_get('vim.uv.fs_stat(...) ~= nil', { path }), true)
  child.lua('cache.clear()')
  eq(child.lua_get('vim.uv.fs_stat(...) == nil', { path }), true)
  eq(child.lua_get('vim.uv.fs_stat(vim.fs.dirname(...)) == nil', { path }), true)
  get('labels')
  eq(count('/labels'), 2)
end

T['clear()']['a fetch in progress is not stored'] = function()
  child.lua([[
    _G.r = nil
    cache.get('labels', function(err, data) _G.r = { err = err, n = #data } end)
    -- Let the identity request go out, then clear while /labels is in flight.
    vim.wait(2000, function() return (_G.counts['/labels'] or 0) == 1 end, 1)
    cache.clear()
    vim.wait(2000, function() return _G.r ~= nil end, 2)
  ]])
  eq(child.lua_get('_G.r'), { n = 3 })
  eq(child.lua_get('vim.uv.fs_stat(...) == nil', { cache_file('acme') }), true)
  get('labels')
  eq(count('/labels'), 2)
end

T['clear()']['works without a cache directory'] = function()
  expect.no_error(function()
    child.lua('cache.clear()')
  end)
end

T['load()'] = new_set()

T['load()']['loads every list'] = function()
  eq(child.lua_get('_G.load()'), {})
  for _, path in ipairs({
    '/workflows',
    '/epic-workflow',
    '/members',
    '/labels',
    '/groups',
    '/iterations',
  }) do
    eq(count(path), 1)
  end
  eq(count('/member'), 1)
end

T['load()']['reports the first error'] = function()
  child.lua([[_G.fail['/groups'] = 500]])
  local r = child.lua_get([[_G.load({ 'labels', 'groups' })]])
  eq(r.err.status, 500)
  eq(r.err.path, '/groups')
end

T['load()']['with no kinds still calls back'] = function()
  eq(child.lua_get('_G.load({})'), {})
end

T['lookups'] = new_set({
  hooks = {
    pre_case = function()
      child.lua('_G.load()')
    end,
  },
})

---@param expr string
---@param ... any
---@return any[] # The results, as a list.
local function lookup(expr, ...)
  return child.lua_get('{ ' .. expr .. ' }', { ... })
end

T['lookups']['by ID'] = function()
  eq(lookup('cache.state(...)', 502)[1], {
    id = 502,
    name = 'In Progress',
    type = 'started',
    position = 1,
    color = '#cccccc',
    workflow_id = 500,
  })
  eq(lookup('cache.workflow(...)', 510)[1].name, 'Design')
  eq(lookup('cache.epic_state(...)', 523)[1].name, 'Done')
  eq(lookup('cache.member(...)', '00000000-0000-4000-8000-000000000103')[1].disabled, true)
  eq(lookup('cache.label(...)', 602)[1].name, 'Frontend')
  eq(lookup('cache.iteration(...)', 701)[1].name, 'Sprint 1')
  eq(lookup('cache.group(...)', '00000000-0000-4000-8000-000000000202')[1].name, 'Design Team')
  eq(lookup('cache.label(...)', 999), {})
  eq(lookup('cache.state(...)', 601), {})
end

T['lookups']['state names are scoped to a workflow'] = function()
  eq(lookup('cache.state_by_name(...)', 500, 'In Progress')[1].id, 502)
  eq(lookup('cache.state_by_name(...)', 510, 'In Progress')[1].id, 512)
  eq(lookup('cache.state_by_name(...)', 510, ' in progress ')[1].id, 512)
  eq(
    lookup('cache.state_by_name(...)', 500, 'Shipped')[2],
    "unknown state 'Shipped' in workflow 'Engineering'"
  )
  eq(
    lookup('cache.state_by_name(...)', 500, 'Dnoe')[2],
    "unknown state 'Dnoe' in workflow 'Engineering' (did you mean 'Done'?)"
  )
  eq(lookup('cache.state_by_name(...)', 999, 'Done')[2], 'unknown workflow 999')
end

T['lookups']['epic states'] = function()
  eq(lookup('cache.epic_state_by_name(...)', 'in progress')[1].id, 522)
  eq(lookup('cache.epic_state_by_name(...)', 'Xyzzy')[2], "unknown epic state 'Xyzzy'")
end

T['lookups']['members by mention name'] = function()
  eq(lookup('cache.member_by_mention(...)', 'jdoe')[1].name, 'Jane Doe')
  eq(lookup('cache.member_by_mention(...)', '@JDoe')[1].name, 'Jane Doe')
  eq(lookup('cache.member_by_mention(...)', 'alex.smith')[1].mention_name, 'Alex.Smith')
  local former = lookup('cache.member_by_mention(...)', '@former')[1]
  eq(former.disabled, true)
  eq(
    lookup('cache.member_by_mention(...)', '@jdo')[2],
    "unknown member 'jdo' (did you mean 'jdoe'?)"
  )
  eq(lookup('cache.member_by_mention(...)', 'zzzzzzzz')[2], "unknown member 'zzzzzzzz'")
end

T['lookups']['labels by name'] = function()
  eq(lookup('cache.label_by_name(...)', 'BUG')[1].id, 601)
  eq(lookup('cache.label_by_name(...)', 'frontend')[1].id, 602)
  eq(
    lookup('cache.label_by_name(...)', 'front')[2],
    "unknown label 'front' (did you mean 'Frontend'?)"
  )
end

T['lookups']['iterations by name'] = function()
  eq(lookup('cache.iteration_by_name(...)', 'sprint 2')[1].id, 702)
  eq(
    lookup('cache.iteration_by_name(...)', 'Sprint 3')[2],
    "unknown iteration 'Sprint 3' (did you mean 'Sprint 1', 'Sprint 2'?)"
  )
end

T['lookups']['groups by name or mention name'] = function()
  eq(lookup('cache.group_by_name(...)', 'design team')[1].mention_name, 'design')
  eq(lookup('cache.group_by_name(...)', '@platform')[1].name, 'Platform Team')
  eq(lookup('cache.group_by_name(...)', 'platform')[1].name, 'Platform Team')
end

T['lookups']['ambiguous names'] = function()
  child.lua([[
    local entry = { fetched_at = _G.now, data = {
      { id = 1, name = 'Sprint', status = 'done' },
      { id = 2, name = 'Sprint', status = 'started' },
      { id = 3, name = 'Dup', status = 'started' },
      { id = 4, name = 'dup', status = 'started' },
      { id = 5, name = 'Same', status = 'started' },
      { id = 6, name = 'same', status = 'started' },
      { id = 7, name = 'SAME', status = 'started' },
    } }
    cache._reset()
    _G.new_session()
    vim.fn.writefile({ vim.json.encode({ version = 1, url_slug = 'acme', lists = { iterations = entry } }) }, cache.path('acme'))
    _G.get('iterations')
  ]])
  -- Only one of them is not done.
  eq(lookup('cache.iteration_by_name(...)', 'sprint')[1].id, 2)
  -- An exact match wins over case-insensitive ones.
  eq(lookup('cache.iteration_by_name(...)', 'dup')[1].id, 4)
  eq(
    lookup('cache.iteration_by_name(...)', 'sAmE')[2],
    "ambiguous iteration 'sAmE': matches IDs 5, 6, 7"
  )
end

T['lookups']['before the lists are loaded'] = function()
  child.lua('_G.new_session()')
  eq(lookup('cache.label(...)', 601), {})
  eq(lookup('cache.label_by_name(...)', 'bug')[2], 'the labels list is not loaded')
  eq(lookup('cache.state_by_name(...)', 500, 'Done')[2], 'the workflows list is not loaded')
  eq(lookup('cache.epic_state_by_name(...)', 'Done')[2], 'the epic workflow list is not loaded')
end

T['lookups']['use the current workspace'] = function()
  child.lua('vim.env.SHORTCUT_API_TOKEN = ...; require("shortcut.auth").reset()', { TOKEN2 })
  child.lua([[_G.get('labels')]])
  eq(lookup('cache.label_by_name(...)', 'other-label')[1].id, 9)
  eq(lookup('cache.label(...)', 601), {})
end

T['health'] = new_set()

T['health']['reports the cache'] = function()
  child.lua([[_G.get('labels'); _G.get('members'); _G.now = _G.now + 2 * 3600]])
  child.lua([[_G.responses = { { status = 200, fixture = 'member' } }; _G.routes = nil]])
  child.cmd('checkhealth shortcut')
  local report = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  local function has(text)
    if not report:find(text, 1, true) then
      error(('%q not found in the report:\n%s'):format(text, report), 2)
    end
  end
  has('Lookup-list cache')
  has(child.lua_get('cache.root()'))
  has('workspace acme (current)')
  has('labels: 3 entries, fetched 2h ago')
  has('members: 3 entries, fetched 2h ago')
  has('workflows: not cached')
end

T['health']['reports expired, corrupt and missing caches'] = function()
  child.cmd('checkhealth shortcut')
  local report = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  eq(report:find('nothing cached yet', 1, true) ~= nil, true)

  child.lua([[_G.get('labels'); _G.now = _G.now + 3 * 24 * 3600]])
  child.lua([[
    vim.fn.mkdir(cache.root() .. '/broken', 'p')
    vim.fn.writefile({ 'junk' }, cache.root() .. '/broken/refs.json')
  ]])
  child.cmd('checkhealth shortcut')
  report = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  eq(report:find('labels: 3 entries, fetched 3d ago (expired)', 1, true) ~= nil, true)
  eq(report:find('workspace broken: unreadable or corrupt', 1, true) ~= nil, true)
end

return T

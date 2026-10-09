local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local TOKEN = 'test-token-0000-1111-2222-3333wxyz'
local BASE = 'https://api.app.shortcut.com/api/v3'

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua(
        [[
        vim.env.SHORTCUT_API_TOKEN = ...
        dofile('tests/fake_transport.lua')

        --- Call `require('shortcut.api.' .. mod)[fn](...)` (`fn` may be dotted, e.g.
        --- `tasks.create`) and wait for its callback.
        function _G.call(mod, fn, ...)
          local f = require('shortcut.api.' .. mod)
          for part in fn:gmatch('[^.]+') do
            f = f[part]
          end
          local r
          local args = vim.F.pack_len(...)
          args[args.n + 1] = function(err, data, resp)
            r = { err = err, data = data, resp = resp }
          end
          f(unpack(args, 1, args.n + 1))
          vim.wait(2000, function() return r ~= nil end, 2)
          return r
        end
      ]],
        { TOKEN }
      )
    end,
    post_once = child.stop,
  },
})

---@param mod string
---@param fn string
---@param ... any
---@return table
local function call(mod, fn, ...)
  return child.lua_get('_G.call(...)', { mod, fn, ... })
end

---@param responses table[]
local function respond(responses)
  child.lua('_G.responses = ...', { responses })
end

--- The requests made, as `{ method, url, body }` with `body` decoded.
local function requests()
  return vim.tbl_map(function(r)
    return { r.method, r.url, r.body and vim.json.decode(r.body) or nil }
  end, child.lua_get('_G.requests'))
end

local function fixture(name)
  return vim.json.decode(table.concat(vim.fn.readfile('tests/fixtures/' .. name .. '.json'), '\n'))
end

---------------------------------------------------------------------------------------------------

T['stories'] = new_set()

T['stories']['get()'] = function()
  respond({ { status = 200, fixture = 'story' } })
  local r = call('stories', 'get', 101)
  eq(r.err, nil)
  eq(r.data.id, 101)
  eq(r.data.name, 'Example Story')
  eq(#r.data.tasks, 2)
  eq(#r.data.comments, 2)
  eq(r.data.label_ids, { 601, 602 })
  eq(requests(), { { 'GET', BASE .. '/stories/101' } })
end

T['stories']['update()'] = function()
  respond({ { status = 200, fixture = 'story' } })
  local r = call('stories', 'update', 101, { name = 'Renamed', labels = { { name = 'bug' } } })
  eq(r.err, nil)
  eq(requests(), {
    { 'PUT', BASE .. '/stories/101', { name = 'Renamed', labels = { { name = 'bug' } } } },
  })
end

T['stories']['update() sends null for vim.NIL and {} for no fields'] = function()
  respond({ { status = 200, body = '{}' }, { status = 200, body = '{}' } })
  child.lua([[_G.call('stories', 'update', 7, { epic_id = vim.NIL })]])
  call('stories', 'update', 7, {})
  local raw = child.lua_get('vim.tbl_map(function(r) return r.body end, _G.requests)')
  eq(raw, { '{"epic_id":null}', '{}' })
end

T['stories']['create()'] = function()
  respond({ { status = 201, fixture = 'story' } })
  local r = call('stories', 'create', { name = 'New', workflow_state_id = 501 })
  eq(r.err, nil)
  eq(r.resp.status, 201)
  eq(requests(), { { 'POST', BASE .. '/stories', { name = 'New', workflow_state_id = 501 } } })
end

T['stories']['create() needs a name'] = function()
  local r = call('stories', 'create', { name = ' ' })
  eq(r.err.kind, 'invalid')
  eq(r.err.message, 'a story needs a name')
  eq(requests(), {})
end

T['stories']['comments.create()'] = function()
  respond({ { status = 201, fixture = 'comment' } })
  local r = call('stories', 'comments.create', 101, { text = 'Hello' })
  eq(r.err, nil)
  eq(r.data.text, 'A new comment.')
  eq(requests(), { { 'POST', BASE .. '/stories/101/comments', { text = 'Hello' } } })

  r = call('stories', 'comments.create', 101, { text = '' })
  eq(r.err.kind, 'invalid')
  eq(#requests(), 1)
end

T['stories']['tasks.create()'] = function()
  respond({ { status = 201, fixture = 'task' } })
  local r = call('stories', 'tasks.create', 101, { description = 'Do it', complete = false })
  eq(r.err, nil)
  eq(r.data.id, 113)
  eq(requests(), {
    { 'POST', BASE .. '/stories/101/tasks', { description = 'Do it', complete = false } },
  })
end

T['stories']['tasks.update()'] = function()
  respond({ { status = 200, fixture = 'task' } })
  local r = call('stories', 'tasks.update', 101, 112, { complete = true })
  eq(r.err, nil)
  eq(requests(), { { 'PUT', BASE .. '/stories/101/tasks/112', { complete = true } } })
end

T['stories']['tasks.delete()'] = function()
  respond({ { status = 204, body = '' } })
  local r = call('stories', 'tasks.delete', 101, 112)
  eq(r.err, nil)
  eq(r.data, nil)
  eq(r.resp.status, 204)
  eq(requests(), { { 'DELETE', BASE .. '/stories/101/tasks/112' } })
end

T['stories']['rejects invalid IDs'] = function()
  for _, id in ipairs({ "'1'", '0', '-1', '1.5', 'nil' }) do
    expect.error(function()
      child.lua(('require("shortcut.api.stories").get(%s, function() end)'):format(id))
    end, 'positive integer')
  end
  expect.error(function()
    child.lua('require("shortcut.api.stories").tasks.delete(1, "x", function() end)')
  end, 'task_id')
  eq(requests(), {})
end

T['stories']['works with async.await and is cancellable'] = function()
  respond({ { status = 200, fixture = 'story' } })
  child.lua([[
    local async = require('shortcut.async')
    async.run(function()
      local err, story = async.await(require('shortcut.api.stories').get, 101)
      _G.result = { err = err, name = story and story.name }
    end)
    vim.wait(2000, function() return _G.result ~= nil end, 2)
  ]])
  eq(child.lua_get('_G.result'), { name = 'Example Story' })

  child.lua([[
    local async = require('shortcut.async')
    _G.result = nil
    local task = async.run(function()
      _G.result = { async.await(require('shortcut.api.stories').get, 101) }
    end)
    task:cancel()
    vim.wait(50)
  ]])
  eq(child.lua_get('_G.result'), vim.NIL)
  eq(child.lua_get('_G.cancelled'), 1)
end

---------------------------------------------------------------------------------------------------

T['epics'] = new_set()

T['epics']['get()'] = function()
  respond({ { status = 200, fixture = 'epic' } })
  local r = call('epics', 'get', 201)
  eq(r.data.name, 'Example Epic')
  eq(r.data.epic_state_id, 522)
  eq(requests(), { { 'GET', BASE .. '/epics/201' } })
end

T['epics']['update()'] = function()
  respond({ { status = 200, fixture = 'epic' } })
  call('epics', 'update', 201, { epic_state_id = 523 })
  eq(requests(), { { 'PUT', BASE .. '/epics/201', { epic_state_id = 523 } } })
end

T['epics']['stories()'] = function()
  respond({ { status = 200, fixture = 'epic_stories' } })
  local r = call('epics', 'stories', 201)
  eq(
    vim.tbl_map(function(s)
      return s.id
    end, r.data),
    { 101, 102, 103 }
  )
  eq(requests(), { { 'GET', BASE .. '/epics/201/stories' } })
end

---------------------------------------------------------------------------------------------------

T['search'] = new_set()

T['search']['stories() sends the query, page size and detail'] = function()
  respond({ { status = 200, fixture = 'search_stories_1' } })
  local r = call('search', 'stories', 'owner:jdoe state:"In Progress"', nil)
  eq(r.err, nil)
  eq(#r.data.data, 2)
  eq(r.data.total, 3)
  eq(requests(), {
    {
      'GET',
      BASE
        .. '/search/stories?detail=slim&page_size=25&query=owner%3Ajdoe%20state%3A%22In%20Progress%22',
    },
  })
end

T['search']['epics() takes options'] = function()
  respond({ { status = 200, fixture = 'search_epics' } })
  local r = call('search', 'epics', 'example', { page_size = 5, detail = 'full' })
  eq(r.data.data[1].id, 201)
  eq(requests(), { { 'GET', BASE .. '/search/epics?detail=full&page_size=5&query=example' } })
end

T['search']['caps page_size at 250'] = function()
  respond({ { status = 200, fixture = 'search_epics' } })
  call('search', 'epics', 'x', { page_size = 1000 })
  eq(requests()[1][2], BASE .. '/search/epics?detail=slim&page_size=250&query=x')
end

T['search']['uses config.picker.page_size'] = function()
  child.lua([[require('shortcut').setup({ picker = { page_size = 7 } })]])
  respond({ { status = 200, fixture = 'search_epics' } })
  call('search', 'epics', 'x', nil)
  eq(requests()[1][2], BASE .. '/search/epics?detail=slim&page_size=7&query=x')
end

T['search']['rejects an empty query without sending it'] = function()
  for _, q in ipairs({ '', '   ' }) do
    local r = call('search', 'stories', q, nil)
    eq(r.err.kind, 'invalid')
    eq(r.err.message, 'the search query is empty')
  end
  eq(requests(), {})
end

T['search']['next_path() strips the API base'] = function()
  local function next_path(s)
    return child.lua_get('require("shortcut.api.search").next_path(...)', { s })
  end
  eq(next_path('/api/v3/search/stories?query=a&next=b'), '/search/stories?query=a&next=b')
  eq(next_path('https://api.app.shortcut.com/api/v3/search/epics?next=x'), '/search/epics?next=x')
  eq(next_path('/search/stories?next=x'), vim.NIL)
  eq(next_path('/api/v3x/search'), vim.NIL)
  eq(next_path('https://evil.example.com/api/v3/search/stories'), vim.NIL)
  eq(next_path('/api/v3/search\n'), vim.NIL)
end

T['search']['next_page() requests next as is, without the /api/v3 prefix or a query'] = function()
  local next_page = fixture('search_stories_1').next
  eq(next_page:sub(1, 8), '/api/v3/')
  respond({ { status = 200, fixture = 'search_stories_2' } })
  local r = call('search', 'next_page', next_page)
  eq(r.err, nil)
  eq(#r.data.data, 1)
  eq(requests(), { { 'GET', 'https://api.app.shortcut.com' .. next_page } })
  eq(requests()[1][2]:find('/api/v3/api/v3', 1, true), nil)
end

T['search']['next_page() rejects a link elsewhere'] = function()
  local r = call('search', 'next_page', 'https://evil.example.com/x')
  eq(r.err.kind, 'invalid')
  eq(requests(), {})
end

T['search']['stream()'] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        --- Start a stream; collect pages in _G.pages and the end in _G.done.
        function _G.stream(kind, query, opts, cancel_after)
          _G.pages, _G.done = {}, nil
          _G.s = require('shortcut.api.search').stream(kind, query, opts, function(items, info)
            table.insert(_G.pages, { ids = vim.tbl_map(function(i) return i.id end, items), info = info })
            if cancel_after and #_G.pages >= cancel_after then _G.s:cancel() end
          end, function(err, summary)
            _G.done = { err = err, summary = summary }
          end)
        end
        function _G.wait_done()
          vim.wait(2000, function() return _G.done ~= nil end, 2)
          return { pages = _G.pages, done = _G.done }
        end
      ]])
    end,
  },
})

T['search']['stream()']['follows next until the last page'] = function()
  respond({
    { status = 200, fixture = 'search_stories_1' },
    { status = 200, fixture = 'search_stories_2' },
  })
  child.lua([[_G.stream('stories', 'example')]])
  local r = child.lua_get('_G.wait_done()')
  eq(r.pages, {
    { ids = { 101, 102 }, info = { page = 1, count = 2, total = 3 } },
    { ids = { 103 }, info = { page = 2, count = 3, total = 3 } },
  })
  eq(r.done, { summary = { count = 3, total = 3, truncated = false } })
  local next_page = fixture('search_stories_1').next
  eq(
    vim.tbl_map(function(q)
      return q[2]
    end, requests()),
    {
      BASE .. '/search/stories?detail=slim&page_size=25&query=example',
      'https://api.app.shortcut.com' .. next_page,
    }
  )
end

T['search']['stream()']['stops at max_results'] = function()
  respond({
    { status = 200, fixture = 'search_stories_1' },
    { status = 200, fixture = 'search_stories_2' },
  })
  child.lua([[_G.stream('stories', 'example', { max_results = 1 })]])
  local r = child.lua_get('_G.wait_done()')
  eq(r.pages, { { ids = { 101 }, info = { page = 1, count = 1, total = 3 } } })
  eq(r.done, { summary = { count = 1, total = 3, truncated = true } })
  eq(#requests(), 1)
end

T['search']['stream()']['uses config.picker.max_results'] = function()
  child.lua([[require('shortcut').setup({ picker = { max_results = 2 } })]])
  respond({
    { status = 200, fixture = 'search_stories_1' },
    { status = 200, fixture = 'search_stories_2' },
  })
  child.lua([[_G.stream('stories', 'example')]])
  local r = child.lua_get('_G.wait_done()')
  eq(#r.pages, 1)
  eq(r.done.summary, { count = 2, total = 3, truncated = true })
  eq(#requests(), 1)
end

T['search']['stream()']['can be cancelled between pages'] = function()
  respond({
    { status = 200, fixture = 'search_stories_1' },
    { status = 200, fixture = 'search_stories_2' },
  })
  child.lua([[_G.stream('stories', 'example', nil, 1); vim.wait(100)]])
  eq(#child.lua_get('_G.pages'), 1)
  eq(child.lua_get('_G.done'), vim.NIL)
  eq(#requests(), 1)
end

T['search']['stream()']['can be cancelled with a request in flight'] = function()
  respond({ { status = 200, fixture = 'search_stories_1' } })
  child.lua([[_G.stream('stories', 'example'); _G.s:cancel(); vim.wait(100)]])
  eq(child.lua_get('_G.pages'), {})
  eq(child.lua_get('_G.done'), vim.NIL)
  eq(child.lua_get('_G.cancelled'), 1)
  eq(child.lua_get('_G.s:is_cancelled()'), true)
end

T['search']['stream()']['reports a failed page after the pages before it'] = function()
  respond({
    { status = 200, fixture = 'search_stories_1' },
    { status = 400, body = '{"message": "A maximum of 1000 search results are supported."}' },
  })
  child.lua([[_G.stream('stories', 'example')]])
  local r = child.lua_get('_G.wait_done()')
  eq(#r.pages, 1)
  eq(r.done.err.status, 400)
  eq(r.done.summary, { count = 2, total = 3, truncated = false })
end

T['search']['stream()']['stops if on_page raises an error, without calling on_done'] = function()
  respond({
    { status = 200, fixture = 'search_stories_1' },
    { status = 200, fixture = 'search_stories_2' },
  })
  child.lua([[
    _G.done = nil
    _G.s = require('shortcut.api.search').stream('stories', 'example', nil, function()
      error('boom')
    end, function() _G.done = true end)
    vim.wait(100)
  ]])
  eq(child.lua_get('_G.s:is_cancelled()'), true)
  eq(child.lua_get('_G.done'), vim.NIL)
  eq(#requests(), 1)
  expect.no_error(function()
    assert(child.cmd_capture('messages'):find('boom', 1, true))
  end)
end

T['search']['stream()']['reports an empty query'] = function()
  child.lua([[_G.stream('epics', '')]])
  local r = child.lua_get('_G.wait_done()')
  eq(r.pages, {})
  eq(r.done.err.kind, 'invalid')
  eq(requests(), {})
end

---------------------------------------------------------------------------------------------------

T['refs'] = new_set()

T['refs']['fetch the lists from their endpoints'] = function()
  local cases = {
    { 'workflows', '/workflows', 'workflows' },
    { 'epic_workflow', '/epic-workflow', 'epic_workflow' },
    { 'members', '/members', 'members' },
    { 'labels', '/labels?slim=true', 'labels' },
    { 'groups', '/groups', 'groups' },
    { 'iterations', '/iterations', 'iterations' },
  }
  for i, c in ipairs(cases) do
    respond({ { status = 200, fixture = c[3] } })
    local r = call('refs', c[1])
    eq(r.err, nil)
    eq(type(r.data), 'table')
    eq(requests()[i], { 'GET', BASE .. c[2] })
  end
end

---@param kind string
---@return any
local function slim(kind)
  return child.lua_get(
    [[require('shortcut.api.refs').slim(..., vim.json.decode(_G.fixture(select(2, ...)), { luanil = { object = true, array = true } }))]],
    { kind, kind }
  )
end

T['refs']['slim() keeps what the plugin uses'] = function()
  local workflows = slim('workflows')
  eq(#workflows, 2)
  eq(workflows[1].id, 500)
  eq(workflows[1].name, 'Engineering')
  eq(workflows[1].default_state_id, 501)
  eq(workflows[1].states[2], {
    id = 502,
    name = 'In Progress',
    type = 'started',
    position = 1,
    color = '#cccccc',
    workflow_id = 500,
  })

  local epic_workflow = slim('epic_workflow')
  eq(epic_workflow.default_epic_state_id, 521)
  eq(
    vim.tbl_map(function(s)
      return s.name
    end, epic_workflow.epic_states),
    { 'To Do', 'In Progress', 'Done' }
  )

  local members = slim('members')
  eq(members[1], {
    id = '00000000-0000-4000-8000-000000000101',
    mention_name = 'jdoe',
    name = 'Jane Doe',
    disabled = false,
    role = 'admin',
  })
  eq(members[3].disabled, true)
  -- Not stored: email addresses.
  eq(vim.inspect(members):find('@example.com', 1, true), nil)

  eq(slim('labels')[3], { id = 603, name = 'old-label', color = '#ff0000', archived = true })
  local groups = slim('groups')
  eq(groups[1].mention_name, 'platform')
  eq(groups[1].workflow_ids, { 500, 510 })
  eq(slim('iterations')[2], {
    id = 702,
    name = 'Sprint 2',
    status = 'started',
    start_date = '2026-01-19',
    end_date = '2026-02-01',
  })
end

T['refs']['slim() rejects unexpected shapes and drops malformed entries'] = function()
  local function slim_raw(kind, data)
    return child.lua_get('{ require("shortcut.api.refs").slim(...) }', { kind, data })
  end
  eq(slim_raw('members', 'x')[2], 'unexpected response from GET /members')
  eq(slim_raw('labels', { a = 1 })[2], 'unexpected response from GET /labels')
  eq(slim_raw('epic_workflow', {})[2], 'unexpected response from GET /epic-workflow')
  eq(slim_raw('labels', { { id = 1, name = 'ok' }, { name = 'no id' }, 'junk' })[1], {
    { id = 1, name = 'ok', archived = false },
  })
  eq(slim_raw('workflows', { { id = 1, states = { { id = 2, position = 0 } } } })[1], {
    { id = 1, name = '1', states = {} },
  })
end

return T

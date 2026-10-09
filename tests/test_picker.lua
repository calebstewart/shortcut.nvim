local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local TOKEN = 'test-token-0000-1111-2222-3333wxyz'
local BASE = 'https://api.app.shortcut.com/api/v3'
local JDOE = '00000000-0000-4000-8000-000000000101'
local ALEX = '00000000-0000-4000-8000-000000000102'

-- Where snacks.nvim is (see the Makefile); its tests are skipped without it.
local SNACKS = vim.env.SNACKS_NVIM or (vim.fn.getcwd() .. '/deps/snacks.nvim')
local HAS_SNACKS = vim.uv.fs_stat(SNACKS .. '/lua/snacks/init.lua') ~= nil

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua(
        [[
        vim.env.SHORTCUT_API_TOKEN = ...
        dofile('tests/fake_transport.lua')
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        -- Never the system clipboard (which may be missing or broken, e.g. in the Nix sandbox).
        _G.clipboard = {}
        local function copy(reg)
          return function(lines) _G.clipboard[reg] = lines end
        end
        local function paste(reg)
          return function() return _G.clipboard[reg] or {} end
        end
        vim.g.clipboard = {
          name = 'test',
          copy = { ['+'] = copy('+'), ['*'] = copy('*') },
          paste = { ['+'] = paste('+'), ['*'] = paste('*') },
        }
        _G.counts = {}
        -- `_G.overrides[path]` replaces a path's response.
        _G.overrides = {}
        local fixtures = {
          ['/member'] = 'member',
          ['/workflows'] = 'workflows',
          ['/epic-workflow'] = 'epic_workflow',
          ['/members'] = 'members',
          ['/labels'] = 'labels',
          ['/groups'] = 'groups',
          ['/iterations'] = 'iterations',
          ['/search/epics'] = 'search_epics',
          ['/epics/202'] = 'epic_render',
          ['/epics/202/stories'] = 'epic_render_stories',
          ['/epics/201'] = 'epic',
          ['/stories/101'] = 'story_render',
        }
        _G.routes = function(req)
          local path = req.url:gsub('^https://api%.app%.shortcut%.com/api/v3', ''):gsub('%?.*', '')
          _G.counts[path] = (_G.counts[path] or 0) + 1
          if _G.overrides[path] then
            return _G.overrides[path]
          end
          if path == '/search/stories' then
            -- `_G.responses` first (a test's own pages), then the two fixture pages.
            if #_G.responses > 0 then
              return nil
            end
            local next_page = req.url:find('next=', 1, true)
            return { status = 200, fixture = next_page and 'search_stories_2' or 'search_stories_1' }
          end
          if fixtures[path] then
            return { status = 200, fixture = fixtures[path] }
          end
          return { status = 404, body = '{"message": "Resource not found."}' }
        end
        _G.picker = require('shortcut.picker')

        --- Run `picker.collect()` and wait for it to finish.
        function _G.collect(kind, query)
          local r = { pages = {} }
          picker.collect(kind, query, function(items)
            table.insert(r.pages, items)
          end, function(err, summary)
            r.err, r.summary, r.done = err, summary, true
          end)
          vim.wait(2000, function() return r.done end, 2)
          return r
        end
      ]],
        { TOKEN }
      )
    end,
    post_once = child.stop,
  },
})

local function messages()
  return child.lua_get('_G.messages')
end

local function count(path)
  return child.lua_get('_G.counts[...] or 0', { path })
end

--- URLs requested, in order.
local function urls()
  return vim.tbl_map(function(r)
    return r.url
  end, child.lua_get('_G.requests'))
end

--- URLs requested for a path.
local function urls_for(path)
  return vim.tbl_filter(function(u)
    return u:gsub('%?.*', '') == BASE .. path
  end, urls())
end

---------------------------------------------------------------------------------------------------

T['queries'] = new_set()

T['queries']['mine excludes done and archived stories'] = function()
  eq(child.lua_get('picker.mine_query("jdoe")'), 'owner:jdoe !is:done !is:archived')
  eq(child.lua_get('picker.mine_query("@jdoe")'), 'owner:jdoe !is:done !is:archived')
  eq(child.lua_get('picker.mine_query("odd name")'), 'owner:"odd name" !is:done !is:archived')
end

T['queries']['epics start with not-done epics'] = function()
  eq(child.lua_get('picker.SOURCES.epics.default_query'), '!is:done !is:archived')
  eq(child.lua_get('picker.SOURCES.search.default_query'), vim.NIL)
end

---------------------------------------------------------------------------------------------------

T['collect()'] = new_set()

T['collect()']['passes the query through and streams every page'] = function()
  local r = child.lua_get('collect(...)', { 'stories', 'owner:jdoe state:"In Progress"' })
  eq(r.err, nil)
  eq(#r.pages, 2)
  eq(
    vim.tbl_map(function(p)
      return vim.tbl_map(function(i)
        return i.id
      end, p)
    end, r.pages),
    { { 101, 102 }, { 103 } }
  )
  eq(r.summary.count, 3)
  eq(r.summary.truncated, false)
  local search = urls_for('/search/stories')
  eq(
    search[1],
    BASE
      .. '/search/stories?detail=slim&page_size=25&query=owner%3Ajdoe%20state%3A%22In%20Progress%22'
  )
  eq(#search, 2)
  -- The lookup lists were loaded first.
  eq(count('/workflows'), 1)
  eq(count('/members'), 1)
end

T['collect()']['items carry names from the lookup lists'] = function()
  local r = child.lua_get('collect(...)', { 'stories', 'example' })
  eq(r.pages[1][1], {
    text = 'sc-101 In Progress feature Example Story @jdoe',
    kind = 'story',
    id = 101,
    name = 'Example Story',
    state = 'In Progress',
    state_type = 'started',
    story_type = 'feature',
    owners = { 'jdoe' },
    url = 'https://app.shortcut.com/example-workspace/story/101',
  })
end

T['collect()']['epics'] = function()
  local r = child.lua_get('collect(...)', { 'epics', 'example' })
  eq(r.err, nil)
  local item = r.pages[1][1]
  eq(item.kind, 'epic')
  eq(item.id, 201)
  eq(item.state, 'In Progress')
  eq(item.state_type, 'started')
  eq(count('/epic-workflow'), 1)
  eq(count('/workflows'), 0)
  eq(urls_for('/search/epics')[1], BASE .. '/search/epics?detail=slim&page_size=25&query=example')
end

T['collect()']['stops at max_results'] = function()
  child.lua([[require('shortcut').setup({ picker = { max_results = 2 } })]])
  local r = child.lua_get('collect(...)', { 'stories', 'example' })
  eq(#r.pages, 1)
  eq(#r.pages[1], 2)
  eq(r.summary.truncated, true)
  eq(r.summary.total, 3)
  eq(#urls_for('/search/stories'), 1)
end

T['collect()']['an empty query is rejected without a request'] = function()
  local r = child.lua_get('collect(...)', { 'stories', '   ' })
  eq(r.err.kind, 'invalid')
  eq(r.pages, {})
  eq(#urls_for('/search/stories'), 0)
end

T['collect()']['cancelling stops the request in flight; nothing is delivered after'] = function()
  child.lua([[
    _G.responses = { { status = 200, fixture = 'search_stories_1', hold = true } }
    _G.got = {}
    _G.h = picker.collect('stories', 'example', function(items)
      table.insert(_G.got, items)
    end, function() _G.got.done = true end)
    vim.wait(2000, function() return #_G.held > 0 end, 2)
  ]])
  eq(child.lua_get('#_G.held'), 1)
  child.lua('_G.h:cancel()')
  eq(child.lua_get('_G.cancelled'), 1)
  child.lua('_G.held[1](); vim.wait(50)')
  eq(child.lua_get('_G.got'), {})
end

T['collect()']['cancelling while the lookup lists load sends no search'] = function()
  child.lua([[
    _G.overrides['/workflows'] = { status = 200, fixture = 'workflows', hold = true }
    _G.got = {}
    _G.h = picker.collect('stories', 'example', function(items)
      table.insert(_G.got, items)
    end, function() _G.got.done = true end)
    vim.wait(2000, function() return #_G.held > 0 end, 2)
    _G.h:cancel()
    _G.held[1]()
    vim.wait(50)
  ]])
  eq(child.lua_get('_G.got'), {})
  eq(#urls_for('/search/stories'), 0)
end

T['collect()']['without lookup lists, items show IDs and the error is reported'] = function()
  child.lua([[_G.overrides['/workflows'] = { status = 500 }]])
  local r = child.lua_get('collect(...)', { 'stories', 'example' })
  eq(r.err, nil)
  eq(r.summary.refs_err.status, 500)
  eq(r.pages[1][1].state, 'unknown-502')
  eq(r.pages[1][1].state_type, nil)
end

---------------------------------------------------------------------------------------------------

T['items'] = new_set({
  hooks = {
    pre_case = function()
      -- Load the lookup lists the items use.
      child.lua([[
        local done
        require('shortcut.cache').load({ 'workflows', 'members', 'epic_workflow' }, function() done = true end)
        vim.wait(2000, function() return done end, 2)
      ]])
    end,
  },
})

local function item(kind, obj)
  return child.lua_get('picker.make_item(...)', { kind, obj })
end

T['items']['server strings are flattened to one line'] = function()
  local it = item('stories', {
    id = 7,
    name = 'Line one\nline two\r\nthree',
    story_type = 'bug',
    workflow_state_id = 503,
    owner_ids = { JDOE, ALEX },
    app_url = 'https://app.shortcut.com/x/story/7',
  })
  eq(it.name, 'Line one line two three')
  eq(it.state, 'Done')
  eq(it.state_type, 'done')
  eq(it.owners, { 'jdoe', 'Alex.Smith' })
  eq(it.text, 'sc-7 Done bug Line one line two three @jdoe @Alex.Smith')
end

T['items']['unknown states and members'] = function()
  local it = item('stories', {
    id = 8,
    name = 'X',
    workflow_state_id = 999,
    owner_ids = { '00000000-0000-4000-8000-000000000999' },
  })
  eq(it.state, 'unknown-999')
  eq(it.state_type, nil)
  eq(it.owners, { 'unknown-00000000-0000-4000-8000-000000000999' })
  eq(it.story_type, nil)
  eq(it.url, nil)
end

T['items']['only https links are kept'] = function()
  for _, url in ipairs({ 'javascript:alert(1)', 'http://x', 'https://a b', 'https://a\nb', 42 }) do
    eq(item('stories', { id = 1, name = 'x', app_url = url }).url, nil)
  end
end

T['items']['epics fall back to the legacy state field'] = function()
  local it = item('epics', { id = 9, name = 'E', epic_state_id = 999, state = 'done' })
  eq(it.state, 'done')
  eq(it.state_type, 'done')
  it = item('epics', { id = 9, name = 'E', epic_state_id = 521 })
  eq(it.state, 'To Do')
  eq(it.state_type, 'unstarted')
end

T['items']['results without an ID are skipped'] = function()
  eq(item('stories', { name = 'x' }), vim.NIL)
end

---------------------------------------------------------------------------------------------------

T['format()'] = new_set()

local function format(it)
  return child.lua_get('picker.format(...)', { it })
end

local function story_item(extra)
  return vim.tbl_extend('force', {
    text = '',
    kind = 'story',
    id = 42,
    name = 'Title',
    state = 'In Progress',
    state_type = 'started',
    story_type = 'feature',
    owners = { 'jdoe', 'Alex.Smith' },
  }, extra or {})
end

T['format()']['story rows: id, state, type, title, owners'] = function()
  eq(format(story_item()), {
    { 'sc-42    ', 'ShortcutId' },
    { ' ' },
    { 'In Progress ', 'ShortcutStateStarted' },
    { ' ' },
    { 'feat ', 'ShortcutTypeFeature' },
    { ' ' },
    { 'Title' },
    { ' ' },
    { '@jdoe @Alex.Smith', 'ShortcutOwners' },
  })
end

T['format()']['states are highlighted by type, unknown types neutrally'] = function()
  local function hl(t)
    return format(story_item({ state_type = t }))[3][2]
  end
  eq(hl('backlog'), 'ShortcutStateBacklog')
  eq(hl('unstarted'), 'ShortcutStateUnstarted')
  eq(hl('started'), 'ShortcutStateStarted')
  eq(hl('done'), 'ShortcutStateDone')
  eq(hl('someday'), 'ShortcutStateOther')
  eq(format(story_item({ state_type = vim.NIL }))[3][2], 'ShortcutStateOther')
end

T['format()']['type markers'] = function()
  eq(format(story_item({ story_type = 'bug' }))[5], { 'bug  ', 'ShortcutTypeBug' })
  eq(format(story_item({ story_type = 'chore' }))[5], { 'chore', 'ShortcutTypeChore' })
  eq(format(story_item({ story_type = 'spike' }))[5], { 'spike' })
end

T['format()']['epic rows: id, state, name'] = function()
  eq(format(story_item({ kind = 'epic', state = 'Done', state_type = 'done', owners = {} })), {
    { 'sc-42    ', 'ShortcutId' },
    { ' ' },
    { 'Done        ', 'ShortcutStateDone' },
    { ' ' },
    { 'Title' },
  })
end

T['format()']['label() for vim.ui.select'] = function()
  eq(child.lua_get('picker.label(...)', { story_item() }), 'sc-42 [In Progress] Title')
end

T['format()']['highlight groups are defined as default links'] = function()
  child.lua('picker.define_highlights()')
  eq(child.lua_get('vim.api.nvim_get_hl(0, { name = "ShortcutStateDone" }).link'), 'DiagnosticOk')
  eq(child.lua_get('vim.api.nvim_get_hl(0, { name = "ShortcutOwners" }).link'), 'Comment')
  -- A colour scheme change keeps them.
  child.cmd('highlight clear | doautocmd ColorScheme')
  eq(child.lua_get('vim.api.nvim_get_hl(0, { name = "ShortcutStateDone" }).link'), 'DiagnosticOk')
end

---------------------------------------------------------------------------------------------------

T['preview_lines()'] = new_set()

--- `picker.preview_lines()` for an item, waited for.
local function preview_lines(kind, id)
  return child.lua_get(
    [[(function(kind, id)
      local r
      picker.preview_lines({ kind = kind, id = id }, function(err, lines) r = { err = err, lines = lines } end)
      vim.wait(2000, function() return r ~= nil end, 2)
      return r
    end)(...)]],
    { kind, id }
  )
end

T['preview_lines()']['renders the full story, cached for the session'] = function()
  local r = preview_lines('story', 101)
  eq(r.err, nil)
  local expected = child.lua_get([[(function()
    local story = require('shortcut.buffer.story')
    local f = assert(io.open('tests/fixtures/story_render.json'))
    local s = vim.json.decode(f:read('*a'), { luanil = { object = true, array = true } })
    f:close()
    local epic = { id = s.epic_id, name = nil }
    return story.render(s, story.cache_refs(epic))
  end)()]])
  -- Same as the buffer, apart from the epic name (fetched with the story).
  eq(#r.lines, #expected)
  eq(r.lines[1], '---')
  eq(vim.tbl_contains(r.lines, '<!-- shortcut:tasks -->'), true)
  eq(count('/stories/101'), 1)
  eq(child.lua_get('picker.cached_preview({ kind = "story", id = 101 }) ~= nil'), true)
  preview_lines('story', 101)
  eq(count('/stories/101'), 1)
end

T['preview_lines()']['renders the full epic with its stories'] = function()
  local r = preview_lines('epic', 202)
  eq(r.err, nil)
  eq(r.lines[2], 'id: 202')
  eq(vim.tbl_contains(r.lines, '<!-- shortcut:stories -->'), true)
  eq(count('/epics/202/stories'), 1)
end

T['preview_lines()']['errors are reported, not cached'] = function()
  local r = preview_lines('story', 999)
  eq(r.err:find('not found') ~= nil, true)
  eq(child.lua_get('picker.cached_preview({ kind = "story", id = 999 })'), vim.NIL)
end

T['preview_lines()']['the cache is bounded'] = function()
  child.lua('picker.PREVIEW_CACHE_SIZE = 1')
  preview_lines('story', 101)
  preview_lines('epic', 202)
  eq(child.lua_get('picker.cached_preview({ kind = "story", id = 101 })'), vim.NIL)
  eq(child.lua_get('picker.cached_preview({ kind = "epic", id = 202 }) ~= nil'), true)
end

T['preview_lines()']['cancelling drops the result'] = function()
  child.lua([[
    _G.overrides['/stories/101'] = { status = 200, fixture = 'story_render', hold = true }
    _G.got = false
    local h = picker.preview_lines({ kind = 'story', id = 101 }, function() _G.got = true end)
    vim.wait(2000, function() return #_G.held > 0 end, 2)
    h.cancel()
    for _, f in ipairs(_G.held) do f() end
    vim.wait(50)
  ]])
  eq(child.lua_get('_G.got'), false)
end

---------------------------------------------------------------------------------------------------

T['actions'] = new_set()

T['actions']['copy the web link'] = function()
  child.lua([[picker.copy_url({ id = 1, url = 'https://app.shortcut.com/x/story/1' })]])
  eq(child.lua_get([[_G.clipboard['+'] ]]), { 'https://app.shortcut.com/x/story/1' })
  eq(messages()[1].msg, 'shortcut.nvim: copied https://app.shortcut.com/x/story/1')
end

T['actions']['open in the browser'] = function()
  child.lua([[
    _G.opened = {}
    vim.ui.open = function(url) table.insert(_G.opened, url); return {}, nil end
    picker.browse({ id = 1, url = 'https://app.shortcut.com/x/story/1' })
    picker.browse({ id = 2 })
  ]])
  eq(child.lua_get('_G.opened'), { 'https://app.shortcut.com/x/story/1' })
  eq(messages()[1].msg, 'shortcut.nvim: sc-2 has no web link')
end

T['actions']['open, in the current window or a split'] = function()
  child.lua([[picker.open({ kind = 'story', id = 101 })]])
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/101')
  child.lua([[picker.open({ kind = 'epic', id = 202 }, 'vsplit')]])
  eq(child.api.nvim_buf_get_name(0), 'shortcut://epic/202')
  eq(#child.api.nvim_tabpage_list_wins(0), 2)
  child.lua([[picker.open({ kind = 'epic', id = 202 }, 'tab')]])
  eq(#child.api.nvim_list_tabpages(), 2)
  eq(child.api.nvim_buf_get_name(0), 'shortcut://epic/202')
end

---------------------------------------------------------------------------------------------------

T['fallback'] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        _G.inputs, _G.selects = {}, {}
        -- `_G.answer` is what vim.ui.input returns; `_G.choice` the index vim.ui.select picks.
        vim.ui.input = function(opts, on_confirm)
          table.insert(_G.inputs, opts)
          on_confirm(_G.answer)
        end
        vim.ui.select = function(items, opts, on_choice)
          table.insert(_G.selects, {
            prompt = opts.prompt,
            labels = vim.tbl_map(opts.format_item, items),
          })
          on_choice(_G.choice and items[_G.choice] or nil)
        end
        function _G.wait_selected()
          vim.wait(2000, function() return #_G.selects > 0 end, 2)
        end
      ]])
    end,
  },
})

T['fallback']['search asks for a query, then opens the selected story'] = function()
  child.lua([[_G.answer = 'example'; _G.choice = 1]])
  child.cmd('Shortcut search')
  child.lua('wait_selected(); vim.wait(50)')
  eq(child.lua_get('_G.inputs')[1].prompt, 'Shortcut stories: ')
  eq(child.lua_get('_G.selects'), {
    {
      prompt = 'Shortcut stories',
      labels = {
        'sc-101 [In Progress] Example Story',
        'sc-102 [Backlog] Another Example Story',
        'sc-103 [Done] A Finished Example Story',
      },
    },
  })
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/101')
  eq(messages()[1], {
    msg = 'shortcut.nvim: live search and previews need snacks.nvim; using vim.ui.input and vim.ui.select',
    level = child.lua_get('vim.log.levels.INFO'),
  })
  -- Said once.
  child.lua([[_G.answer = nil]])
  child.cmd('Shortcut search')
  eq(#messages(), 1)
end

T['fallback']['search with arguments does not ask'] = function()
  child.cmd('Shortcut search type:bug owner:jdoe')
  child.lua('wait_selected()')
  eq(child.lua_get('_G.inputs'), {})
  eq(
    urls_for('/search/stories')[1],
    BASE .. '/search/stories?detail=slim&page_size=25&query=type%3Abug%20owner%3Ajdoe'
  )
  -- Nothing chosen: nothing opened.
  eq(child.api.nvim_buf_get_name(0), '')
end

T['fallback']['a cancelled or empty input searches nothing'] = function()
  child.lua([[_G.answer = '  ']])
  child.cmd('Shortcut search')
  child.lua('vim.wait(50)')
  eq(#urls_for('/search/stories'), 0)
  eq(child.lua_get('#_G.selects'), 0)
end

T['fallback']['mine searches your unfinished stories without asking'] = function()
  child.cmd('Shortcut mine')
  child.lua('wait_selected()')
  eq(child.lua_get('_G.inputs'), {})
  eq(
    urls_for('/search/stories')[1],
    BASE
      .. '/search/stories?detail=slim&page_size=25&query=owner%3Ajdoe%20%21is%3Adone%20%21is%3Aarchived'
  )
  eq(child.lua_get('_G.selects')[1].prompt, 'My unfinished stories')
end

T['fallback']['mine takes no arguments'] = function()
  child.cmd('Shortcut mine extra')
  eq(messages()[1].msg, 'shortcut.nvim: mine: expected no arguments')
end

T['fallback']['epics suggests the default query and opens the epic'] = function()
  child.lua([[_G.answer = '!is:done !is:archived'; _G.choice = 1]])
  child.cmd('Shortcut epics')
  child.lua('wait_selected(); vim.wait(50)')
  eq(child.lua_get('_G.inputs')[1].default, '!is:done !is:archived')
  eq(child.lua_get('_G.selects')[1].labels, { 'sc-201 [In Progress] Example Epic' })
  eq(child.api.nvim_buf_get_name(0), 'shortcut://epic/201')
end

T['fallback']['search errors and empty results are reported'] = function()
  child.lua(
    [[_G.overrides['/search/stories'] = { status = 400, body = '{"message": "bad query"}' }]]
  )
  child.cmd('Shortcut search owner:')
  child.lua('vim.wait(200, function() return #_G.messages > 1 end, 2)')
  eq(messages()[2].msg, 'shortcut.nvim: GET /search/stories: HTTP 400: bad query')
  child.lua(
    [[_G.overrides['/search/stories'] = { status = 200, body = '{"data": [], "next": null, "total": 0}' }]]
  )
  child.cmd('Shortcut search nothing')
  child.lua('vim.wait(200, function() return #_G.messages > 2 end, 2)')
  eq(messages()[3].msg, 'shortcut.nvim: no results for nothing')
  eq(child.lua_get('#_G.selects'), 0)
end

T['fallback']['a truncated list says so'] = function()
  child.lua([[require('shortcut').setup({ picker = { max_results = 2 } })]])
  child.cmd('Shortcut search example')
  child.lua('wait_selected()')
  eq(child.lua_get('_G.selects')[1].prompt, 'Shortcut stories (first 2 of 3)')
end

---------------------------------------------------------------------------------------------------

T['loading'] = new_set()

T['loading']['nothing is loaded at startup; snacks only when a picker opens'] = function()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  eq(child.lua_get([[package.loaded['shortcut.picker'] == nil]]), true)
  eq(child.lua_get([[package.loaded['snacks'] == nil]]), true)
  eq(
    child.lua_get([[vim.tbl_contains(vim.fn.getcompletion('Shortcut ', 'cmdline'), 'mine')]]),
    true
  )
  eq(child.lua_get([[package.loaded['shortcut.picker'] == nil]]), true)
end

---------------------------------------------------------------------------------------------------

T['snacks'] = new_set({
  hooks = {
    pre_case = function()
      if not HAS_SNACKS then
        MiniTest.skip('snacks.nvim not available (run `make deps`)')
      end
      child.lua(
        [[
        vim.opt.runtimepath:prepend(...)
        vim.o.columns, vim.o.lines = 160, 40
        require('snacks').setup({})
        require('shortcut.picker.snacks').PREVIEW_DELAY = 0

        function _G.current()
          return Snacks.picker.get()[1]
        end
        --- Wait for the picker to settle with `n` items.
        function _G.wait_items(n)
          vim.wait(3000, function()
            local p = current()
            return p and not p.finder:running() and #p:items() == n
          end, 5)
          local p = current()
          return p and vim.tbl_map(function(i) return i.id end, p:items()) or {}
        end
        function _G.preview_lines()
          local p = current()
          return vim.api.nvim_buf_get_lines(p.preview.win.buf, 0, -1, false)
        end
      ]],
        { SNACKS }
      )
    end,
  },
})

T['snacks']['search streams pages into a live picker'] = function()
  child.cmd('Shortcut search example')
  eq(child.lua_get('wait_items(3)'), { 101, 102, 103 })
  local p = child.lua_get([[(function()
    local p = current()
    return { live = p.opts.live, source = p.opts.source, search = p.input.filter.search }
  end)()]])
  eq(p, { live = true, source = 'shortcut_search', search = 'example' })
  eq(#urls_for('/search/stories'), 2)
  -- The row format.
  local row = child.lua_get([[vim.api.nvim_buf_get_lines(current().list.win.buf, 0, 1, false)[1] ]])
  eq(row:find('sc-101', 1, true) ~= nil, true)
  eq(row:find('Example Story', 1, true) ~= nil, true)
  eq(row:find('@jdoe', 1, true) ~= nil, true)
end

T['snacks']['changing the query cancels the search in flight; stale results never show'] = function()
  child.lua([[_G.responses = { { status = 200, fixture = 'search_stories_1', hold = true } }]])
  child.cmd('Shortcut search slow')
  child.lua('vim.wait(2000, function() return #_G.held > 0 end, 2)')
  eq(child.lua_get('#_G.held'), 1)
  -- A new query, as typing it would.
  child.lua([[
    local p = current()
    p.input.filter.search = 'other'
    p:find({ refresh = false })
  ]])
  eq(child.lua_get('wait_items(3)'), { 101, 102, 103 })
  eq(child.lua_get('_G.cancelled'), 1)
  -- The cancelled answer arriving late changes nothing.
  child.lua('_G.held[1](); vim.wait(100)')
  eq(child.lua_get('wait_items(3)'), { 101, 102, 103 })
  local search = urls_for('/search/stories')
  eq(search[1]:find('query=slow', 1, true) ~= nil, true)
  eq(search[2]:find('query=other', 1, true) ~= nil, true)
end

T['snacks']['an empty query shows nothing and sends nothing'] = function()
  child.cmd('Shortcut search')
  child.lua('vim.wait(300)')
  eq(child.lua_get('#current():items()'), 0)
  eq(#urls_for('/search/stories'), 0)
end

T['snacks']['epics start with the default query'] = function()
  child.cmd('Shortcut epics')
  eq(child.lua_get('wait_items(1)'), { 201 })
  eq(child.lua_get('current().input.filter.search'), '!is:done !is:archived')
end

T['snacks']['mine is not live and filters locally'] = function()
  child.cmd('Shortcut mine')
  eq(child.lua_get('wait_items(3)'), { 101, 102, 103 })
  eq(child.lua_get('current().opts.live'), false)
  eq(
    urls_for('/search/stories')[1],
    BASE
      .. '/search/stories?detail=slim&page_size=25&query=owner%3Ajdoe%20%21is%3Adone%20%21is%3Aarchived'
  )
  -- Typing filters the list without searching again.
  child.lua([[
    local p = current()
    p.input.filter.pattern = 'Finished'
    p:find({ refresh = false })
    vim.wait(1000, function() return p.list:count() == 1 end, 5)
  ]])
  eq(child.lua_get('current().list:count()'), 1)
  eq(#urls_for('/search/stories'), 2)
end

T['snacks']['the preview renders the full story, without modelines'] = function()
  child.lua([[_G.overrides['/stories/102'] = { status = 200, fixture = 'story', hold = true }]])
  child.cmd('Shortcut search example')
  child.lua('wait_items(3)')
  child.lua([[vim.wait(2000, function() return preview_lines()[1] == '---' end, 5)]])
  local lines = child.lua_get('preview_lines()')
  eq(lines[1], '---')
  eq(lines[2], 'id: 301')
  local buf = child.lua_get('current().preview.win.buf')
  eq(child.lua_get('vim.bo[...].modeline', { buf }), false)
  eq(child.lua_get('vim.bo[...].filetype', { buf }), 'markdown')

  -- Moving on shows "Loading…" until the story arrives.
  child.lua([[current():action('list_down')]])
  child.lua([[vim.wait(2000, function() return #_G.held > 0 end, 5)]])
  eq(child.lua_get('preview_lines()'), { 'Loading…' })
  eq(child.lua_get('vim.bo[...].modeline', { child.lua_get('current().preview.win.buf') }), false)

  -- Back to the first: from the cache, no new request; the late answer for the second is dropped.
  child.lua([[current():action('list_up'); vim.wait(100)]])
  eq(child.lua_get('preview_lines()')[2], 'id: 301')
  eq(count('/stories/101'), 1)
  eq(child.lua_get('_G.cancelled') >= 1, true)
  child.lua('for _, h in ipairs(_G.held) do h() end; vim.wait(100)')
  eq(child.lua_get('preview_lines()')[2], 'id: 301')
end

T['snacks']['confirm opens the buffer'] = function()
  child.cmd('Shortcut search example')
  child.lua('wait_items(3)')
  child.lua([[current():action('confirm'); vim.wait(200)]])
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/101')
  eq(child.lua_get('Snacks.picker.get()[1] == nil'), true)
end

T['snacks']['the split keys open in a split'] = function()
  child.cmd('Shortcut epics')
  child.lua('wait_items(1)')
  child.lua([[current():action('edit_vsplit'); vim.wait(200)]])
  eq(child.api.nvim_buf_get_name(0), 'shortcut://epic/201')
  eq(#child.api.nvim_tabpage_list_wins(0), 2)
end

T['snacks']['copy and browse keys'] = function()
  child.lua([[
    _G.opened = {}
    vim.ui.open = function(url) table.insert(_G.opened, url); return {}, nil end
  ]])
  child.cmd('Shortcut search example')
  child.lua('wait_items(3)')
  child.lua([[
    local p = current()
    p:action('shortcut_browse')
    p:action('shortcut_copy_url')
  ]])
  eq(child.lua_get('_G.opened'), { 'https://app.shortcut.com/example-workspace/story/101' })
  eq(
    child.lua_get([[_G.clipboard['+'] ]]),
    { 'https://app.shortcut.com/example-workspace/story/101' }
  )
  -- Bound in the input and list windows.
  local keys = child.lua_get([[(function()
    local p = current()
    local input, list = p.opts.win.input.keys, p.opts.win.list.keys
    return { input['<M-b>'][1], input['<C-Y>'][1], list['<M-b>'], list['y'] }
  end)()]])
  eq(keys, { 'shortcut_browse', 'shortcut_copy_url', 'shortcut_browse', 'shortcut_copy_url' })
end

T['snacks']['user source config applies on top'] = function()
  child.lua([[
    Snacks.config.picker.sources = { shortcut_search = { title = 'Custom', win = { list = { keys = { y = false } } } } }
  ]])
  child.cmd('Shortcut search example')
  child.lua('wait_items(3)')
  eq(child.lua_get('current().opts.title'), 'Custom')
  eq(child.lua_get('current().opts.win.list.keys.y'), false)
  eq(child.lua_get([[current().opts.win.list.keys['<M-b>'] ]]), 'shortcut_browse')
end

T['snacks']['search errors are reported once while typing'] = function()
  child.lua(
    [[_G.overrides['/search/stories'] = { status = 400, body = '{"message": "bad query"}' }]]
  )
  child.cmd('Shortcut search owner:')
  child.lua([[vim.wait(2000, function() return #_G.messages > 0 end, 5)]])
  child.lua([[
    local p = current()
    p.input.filter.search = 'owner:x'
    p:find({ refresh = false })
    vim.wait(300)
  ]])
  eq(messages(), {
    { msg = 'shortcut.nvim: GET /search/stories: HTTP 400: bad query', level = 4 },
  })
end

return T

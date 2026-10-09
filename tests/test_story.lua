local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local TOKEN = 'test-token-0000-1111-2222-3333wxyz'
local JDOE = '00000000-0000-4000-8000-000000000101'
local ALEX = '00000000-0000-4000-8000-000000000102'
local GONE = '00000000-0000-4000-8000-000000000999'

--- (Re)start the child in time zone `tz`. Comment dates are shown in local time, and the C
--- library may read `TZ` only once, so it is set in the child's environment from the start.
--- POSIX forms work without the tz database (e.g. in the Nix build sandbox).
---@param tz string
local function restart(tz)
  local old = vim.env.TZ
  vim.env.TZ = tz
  child.restart({ '-u', 'tests/minimal_init.lua' })
  vim.env.TZ = old
end

local T = new_set({
  hooks = {
    pre_case = function()
      restart('UTC0')
      child.lua([[
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        _G.story = require('shortcut.buffer.story')
        _G.fm = require('shortcut.buffer.frontmatter')
        function _G.decode(name)
          return vim.json.decode(_G.read_fixture(name), { luanil = { object = true, array = true } })
        end
        function _G.read_fixture(name)
          local f = assert(io.open(('tests/fixtures/%s.json'):format(name)))
          local s = f:read('*a')
          f:close()
          return s
        end

        -- Lookup functions over the fixtures, as the cache provides them.
        local refs = require('shortcut.api.refs')
        local function index(list)
          local out = {}
          for _, x in ipairs(list) do out[x.id] = x end
          return out
        end
        local states = {}
        for _, w in ipairs(refs.slim('workflows', decode('workflows'))) do
          for _, s in ipairs(w.states) do states[s.id] = s end
        end
        local members = index(refs.slim('members', decode('members')))
        local labels = index(refs.slim('labels', decode('labels')))
        local iterations = index(refs.slim('iterations', decode('iterations')))
        _G.refs = {
          state = function(id) return states[id] end,
          member = function(id) return members[id] end,
          label = function(id) return labels[id] end,
          iteration = function(id) return iterations[id] end,
          epic = { id = 201, name = 'Example Epic' },
        }
      ]])
    end,
    post_once = child.stop,
  },
})

--- Render the `story_render` fixture, modified by `patch` (Lua code run with `s` as the story).
---@param patch? string
---@param opts? table
---@param refs_code? string Lua expression for the refs (default `_G.refs`).
local function render(patch, opts, refs_code)
  return child.lua(
    ([[
    local patch, opts = ...
    local s = decode('story_render')
    if patch ~= nil and patch ~= vim.NIL then loadstring('local s = ...; ' .. patch)(s) end
    local lines, meta = story.render(s, %s, opts ~= vim.NIL and opts or nil)
    -- Sparse integer keys don't survive RPC: key comments by strings.
    local comments = {}
    for id, line in pairs(meta.comments) do comments[tostring(id)] = line end
    meta.comments = comments
    return { lines = lines, meta = meta }
  ]]):format(refs_code or '_G.refs'),
    { patch, opts }
  )
end

local HEADER = {
  '---',
  'id: 301',
  'type: bug',
  'state: In Progress',
  'owners: [Alex.Smith, jdoe]',
  'epic: 201 Example Epic',
  'iteration: Sprint 2',
  'estimate: 5',
  'labels: [Frontend, bug]',
  'url: https://app.shortcut.com/example-workspace/story/301',
  '---',
}

local BODY = {
  '# Render me',
  '',
  'Intro paragraph.',
  '',
  '## Tasks',
  '',
  '- [ ] not a real task, just text',
  '',
  '<!-- shortcut:tasks -->',
  '## Tasks',
  '- [x] Done task · @jdoe',
  '- [ ] Open task',
  '- [ ] Shared task · @jdoe @Alex.Smith',
  '',
  '<!-- shortcut:comments (read-only) -->',
  '## Comments',
  '**@jdoe** · 2026-02-01 10:00',
  '> First comment.',
  '>',
  '> With a paragraph.',
  '>',
  '> **@Alex.Smith** · 2026-02-01 10:15',
  '> > A reply.',
  '>',
  '> **@unknown-' .. GONE .. '** · 2026-02-01 11:00',
  '> > A later reply, by someone no longer in the workspace.',
  '',
  '**@jdoe** · 2026-02-03 09:30',
  '> Last top-level comment.',
  '> Second line.',
}

local FULL = vim.list_extend(vim.deepcopy(HEADER), BODY)

T['render()'] = new_set()

T['render()']['renders the whole story'] = function()
  local r = render()
  eq(r.lines, FULL)
  eq(r.meta, {
    header = { first = 1, last = 11 },
    title = 12,
    description = { first = 14, last = 18 },
    tasks_marker = 20,
    tasks_section = { first = 20, last = 25 },
    tasks = { { id = 311, line = 22 }, { id = 312, line = 23 }, { id = 313, line = 24 } },
    comments_marker = 26,
    comments_section = { first = 26, last = 41 },
    comments = { ['321'] = 28, ['322'] = 33, ['324'] = 36, ['325'] = 39 },
  })
end

T['render()']['the header parses back to what was rendered'] = function()
  local r = render()
  local parsed = child.lua(
    [[
    local fields, body_start = fm.parse(...)
    return { fields = fields, body_start = body_start }
  ]],
    { r.lines }
  )
  eq(parsed.body_start, 12)
  eq(parsed.fields, {
    id = 301,
    type = 'bug',
    state = 'In Progress',
    owners = { 'Alex.Smith', 'jdoe' },
    epic = '201 Example Epic',
    iteration = 'Sprint 2',
    estimate = 5,
    labels = { 'Frontend', 'bug' },
    url = 'https://app.shortcut.com/example-workspace/story/301',
  })
end

T['render()']['missing epic, iteration, estimate, owners, labels, tasks and comments'] = function()
  local r = render([[
    s.epic_id = vim.NIL
    s.iteration_id = vim.NIL
    s.estimate = vim.NIL
    s.owner_ids = {}
    s.label_ids = {}
    s.labels = {}
    s.tasks = {}
    s.comments = {}
    s.description = ''
  ]])
  eq(r.lines, {
    '---',
    'id: 301',
    'type: bug',
    'state: In Progress',
    'owners: []',
    'epic:',
    'iteration:',
    'estimate:',
    'labels: []',
    'url: https://app.shortcut.com/example-workspace/story/301',
    '---',
    '# Render me',
    '',
    '<!-- shortcut:tasks -->',
    '## Tasks',
    '',
    '<!-- shortcut:comments (read-only) -->',
    '## Comments',
  })
  eq(r.meta.description, { first = 14, last = 13 })
  eq(r.meta.tasks, {})
  eq(r.meta.comments, {})
end

T['render()']['an estimate of 0 is shown'] = function()
  eq(render('s.estimate = 0').lines[8], 'estimate: 0')
end

T['render()']['task owners: none, one and several, or hidden'] = function()
  local tasks = { 22, 23, 24 }
  local r = render()
  eq(
    vim.tbl_map(function(i)
      return r.lines[i]
    end, tasks),
    { '- [x] Done task · @jdoe', '- [ ] Open task', '- [ ] Shared task · @jdoe @Alex.Smith' }
  )
  r = render(nil, { show_owners = false })
  eq(
    vim.tbl_map(function(i)
      return r.lines[i]
    end, tasks),
    { '- [x] Done task', '- [ ] Open task', '- [ ] Shared task' }
  )
end

T['render()']['a description with its own markers-like headings stays in the description'] = function()
  local r = render()
  -- `## Tasks` in the description comes before the tasks marker.
  eq(r.lines[16], '## Tasks')
  eq(r.lines[r.meta.tasks_marker], '<!-- shortcut:tasks -->')
  eq(r.meta.tasks_marker > r.meta.description.last, true)
end

T['render()']['unknown IDs are shown as unknown-<id>'] = function()
  local r = render(
    ([[
    s.owner_ids = { '%s' }
    s.label_ids = { 699 }
    s.labels = {}
    s.tasks = { { id = 1, description = 't', complete = false, position = 1, owner_ids = { '%s' } } }
  ]]):format(GONE, GONE),
    nil,
    '{}'
  )
  eq(vim.list_slice(r.lines, 1, 11), {
    '---',
    'id: 301',
    'type: bug',
    'state: unknown-502',
    'owners: [unknown-' .. GONE .. ']',
    'epic: 201 (name unavailable)',
    'iteration: unknown-702',
    'estimate: 5',
    'labels: [unknown-699]',
    'url: https://app.shortcut.com/example-workspace/story/301',
    '---',
  })
  eq(r.lines[r.meta.tasks[1].line], '- [ ] t · @unknown-' .. GONE)
  -- Rendering is stable, so editing won't mistake it for a change.
  eq(render(nil, nil, '{}').lines, render(nil, nil, '{}').lines)
end

T['render()']['label names come from the story, the cache only as a fallback'] = function()
  local r = render([[
    s.labels = { { id = 601, name = 'renamed' } }
    s.label_ids = { 601, 602 }
  ]])
  eq(r.lines[9], 'labels: [renamed, Frontend]')
end

T['render()']['quotes header values when needed'] = function()
  local r = render(
    [[s.story_type = 'feature'; s.labels = { { id = 1, name = 'a, b' }, { id = 2, name = 'true' } }; s.label_ids = { 1, 2 }]],
    nil,
    [[vim.tbl_extend('force', _G.refs, { epic = { id = 201, name = 'Epic: the sequel' } })]]
  )
  eq(r.lines[6], 'epic: "201 Epic: the sequel"')
  eq(r.lines[9], 'labels: ["a, b", "true"]')
end

T['render()']['comments: deleted ones skipped, unless they have replies'] = function()
  local r = render(([[
    s.comments = {
      { id = 1, author_id = '%s', created_at = '2026-03-01T10:00:00Z', deleted = true, text = vim.NIL },
      { id = 2, author_id = '%s', created_at = '2026-03-01T11:00:00Z', deleted = false, parent_id = 1, text = 'orphan reply' },
      { id = 3, author_id = '%s', created_at = '2026-03-01T12:00:00Z', deleted = true, text = vim.NIL },
      { id = 4, author_id = vim.NIL, created_at = 'garbage', deleted = false, parent_id = 99, text = 'no parent, no author' },
      { id = 5, author_id = '%s', created_at = '2026-03-01T13:00:00Z', deleted = false, parent_id = 2, text = 'deeper' },
      { id = 6, author_id = '%s', created_at = '2026-03-01T13:30:00Z', deleted = true, parent_id = 2, text = vim.NIL },
    }
  ]]):format(JDOE, ALEX, JDOE, JDOE, JDOE))
  local start = r.meta.comments_marker + 2
  eq(vim.list_slice(r.lines, start, #r.lines), {
    -- Unparsable dates sort first and are shown as they are.
    '**@unknown** · garbage',
    '> no parent, no author',
    '',
    '*(deleted comment)*',
    '>',
    '> **@Alex.Smith** · 2026-03-01 11:00',
    '> > orphan reply',
    '> >',
    '> > **@jdoe** · 2026-03-01 13:00',
    '> > > deeper',
  })
  eq(r.meta.comments, { ['4'] = start, ['1'] = start + 3, ['2'] = start + 5, ['5'] = start + 8 })
end

T['render()']['is pure: works in a fast event without touching buffers'] = function()
  local out = child.lua([[
    local bufs = vim.api.nvim_list_bufs()
    local result
    local timer = vim.uv.new_timer()
    timer:start(1, 0, function()
      timer:close()
      local ok, lines = pcall(story.render, decode('story_render'), _G.refs)
      result = { ok = ok, n = ok and #lines or lines, fast = vim.in_fast_event() }
    end)
    vim.wait(1000, function() return result ~= nil end)
    return { result = result, same_bufs = vim.deep_equal(bufs, vim.api.nvim_list_bufs()) }
  ]])
  eq(out, { result = { ok = true, n = #FULL, fast = true }, same_bufs = true })
end

T['times'] = new_set()

T['times']['parse ISO-8601 with Z, fractions and offsets'] = function()
  local cases = child.lua([[
    return vim.tbl_map(story.parse_time, {
      '1970-01-01T00:00:00Z',
      '2026-02-01T10:00:00Z',
      '2026-02-01T10:00:00.999999Z',
      '2026-02-01T12:00:00+02:00',
      '2026-02-01T05:30:00-0430',
      '2000-02-29T23:59:59Z',
    })
  ]])
  eq(cases, { 0, 1769940000, 1769940000, 1769940000, 1769940000, 951868799 })
  eq(child.lua_get([[story.parse_time('2026-02-01')]]), vim.NIL)
  eq(child.lua_get([[story.parse_time('2026-02-01T10:00:00')]]), vim.NIL)
  eq(child.lua_get([[story.parse_time(nil)]]), vim.NIL)
end

T['times']['are shown in local time'] = function()
  eq(child.lua_get([[story.format_time('2026-02-01T23:30:00Z')]]), '2026-02-01 23:30')
  restart('IST-5:30')
  child.lua([[_G.story = require('shortcut.buffer.story')]])
  eq(child.lua_get([[story.format_time('2026-02-01T23:30:00Z')]]), '2026-02-02 05:00')
  eq(child.lua_get([[story.format_time('not a time')]]), 'not a time')
end

---------------------------------------------------------------------------------------------------
-- Buffers
---------------------------------------------------------------------------------------------------

T['buffer'] = new_set({
  hooks = {
    pre_case = function()
      child.lua(
        [[
        vim.env.SHORTCUT_API_TOKEN = ...
        dofile('tests/fake_transport.lua')
        _G.counts = {}
        -- `_G.overrides[path]` replaces a path's response.
        _G.overrides = {}
        local fixtures = {
          ['/member'] = 'member',
          ['/workflows'] = 'workflows',
          ['/members'] = 'members',
          ['/labels'] = 'labels',
          ['/iterations'] = 'iterations',
          ['/stories/301'] = 'story_render',
          ['/epics/201'] = 'epic',
        }
        _G.routes = function(req)
          local path = req.url:gsub('^https://api%.app%.shortcut%.com/api/v3', ''):gsub('%?.*', '')
          _G.counts[path] = (_G.counts[path] or 0) + 1
          if _G.overrides[path] then return _G.overrides[path] end
          if fixtures[path] then return { status = 200, fixture = fixtures[path] } end
          return { status = 404, body = '{"message": "Resource not found."}' }
        end

        --- Wait for the current buffer to finish loading.
        function _G.wait_loaded()
          vim.wait(2000, function()
            local first = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ''
            return not first:match('^Loading ')
          end, 5)
        end
      ]],
        { TOKEN }
      )
    end,
  },
})

local function edit(name)
  child.cmd('edit ' .. child.fn.fnameescape(name))
  child.lua('vim.wait(20); _G.wait_loaded()')
end

local function lines()
  return child.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function messages()
  return child.lua_get('_G.messages')
end

local function count(path)
  return child.lua_get('_G.counts[...] or 0', { path })
end

T['buffer']['shows the rendered story, with task extmarks and a snapshot'] = function()
  edit('shortcut://story/301')
  eq(lines(), FULL)
  eq(child.bo.filetype, 'markdown')
  eq(child.bo.modified, false)
  eq(child.bo.modifiable, true)
  eq(child.api.nvim_win_get_cursor(0), { 1, 0 })
  -- Loading is not undoable.
  eq(child.fn.undotree().seq_last, 0)
  eq(messages(), {})
  -- Story, epic and lists were fetched once each.
  for _, path in ipairs({ '/stories/301', '/epics/201', '/workflows', '/members', '/labels' }) do
    eq({ path, count(path) }, { path, 1 })
  end

  eq(child.lua_get('story.task_marks(0)'), {
    { id = 311, row = 21 },
    { id = 312, row = 22 },
    { id = 313, row = 23 },
  })
  local details = child.lua_get([[
    vim.tbl_map(function(m) return m[4].invalidate end,
      vim.api.nvim_buf_get_extmarks(0, story.tasks_ns(), 0, -1, { details = true }))
  ]])
  eq(details, { true, true, true })

  local snap = child.lua([[
    local s = story.snapshot()
    return {
      id = s.story.id,
      updated_at = s.updated_at,
      lines = s.lines,
      tasks = s.meta.tasks,
      show_owners = s.show_owners,
      epic = s.refs.epic,
      marks = vim.tbl_count(s.task_marks),
    }
  ]])
  eq(snap, {
    id = 301,
    updated_at = '2026-02-03T09:30:00Z',
    lines = FULL,
    tasks = { { id = 311, line = 22 }, { id = 312, line = 23 }, { id = 313, line = 24 } },
    show_owners = true,
    epic = { id = 201, name = 'Example Epic' },
    marks = 3,
  })
end

T['buffer']['deleting a task line invalidates its extmark; undo restores it'] = function()
  edit('shortcut://story/301')
  child.api.nvim_win_set_cursor(0, { 23, 0 })
  child.cmd('normal! dd')
  eq(child.lua_get('story.task_marks(0)'), { { id = 311, row = 21 }, { id = 313, row = 22 } })
  child.cmd('undo')
  eq(#child.lua_get('story.task_marks(0)'), 3)
  -- A new line has no mark.
  child.api.nvim_buf_set_lines(0, 24, 24, false, { '- [ ] new task' })
  eq(#child.lua_get('story.task_marks(0)'), 3)
end

T['buffer']['tasks.show_owners = false hides task owners'] = function()
  child.lua([[require('shortcut').setup({ tasks = { show_owners = false } })]])
  edit('shortcut://story/301')
  eq(lines()[24], '- [ ] Shared task')
  eq(child.lua_get('story.snapshot().show_owners'), false)
end

T['buffer'][':e! fetches the story again'] = function()
  edit('shortcut://story/301')
  child.lua([[
    local s = vim.json.decode(_G.read_fixture('story_render'))
    s.name = 'Renamed'
    s.updated_at = '2026-02-04T00:00:00Z'
    _G.overrides['/stories/301'] = { status = 200, body = vim.json.encode(s) }
  ]])
  child.api.nvim_buf_set_lines(0, 11, 12, false, { '# local edit' })
  child.cmd('edit!')
  child.lua('_G.wait_loaded()')
  eq(count('/stories/301'), 2)
  eq(lines()[12], '# Renamed')
  eq(child.bo.modified, false)
  eq(child.lua_get('story.snapshot().updated_at'), '2026-02-04T00:00:00Z')
  -- Extmarks were replaced, not added to.
  eq(#child.lua_get('vim.api.nvim_buf_get_extmarks(0, story.tasks_ns(), 0, -1, {})'), 3)
end

T['buffer']['a comment anchor puts the cursor on the comment'] = function()
  edit('https://app.shortcut.com/acme/story/301/render-me#activity-322')
  child.lua(
    [[vim.wait(1000, function() return vim.api.nvim_buf_get_name(0) == 'shortcut://story/301' end)]]
  )
  child.lua('_G.wait_loaded()')
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/301')
  eq(child.api.nvim_win_get_cursor(0), { 33, 0 })

  -- In the already-open buffer too.
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  edit('https://app.shortcut.com/acme/story/301#activity-325')
  child.lua('vim.wait(50)')
  eq(child.api.nvim_win_get_cursor(0), { 39, 0 })
  eq(count('/stories/301'), 1)
  eq(messages(), {})

  -- An unknown comment warns and leaves the cursor alone.
  edit('https://app.shortcut.com/acme/story/301#activity-999')
  child.lua('vim.wait(50)')
  eq(child.api.nvim_win_get_cursor(0), { 39, 0 })
  eq(messages()[1].msg, 'shortcut.nvim: comment 999 not found on sc-301')
end

T['buffer']['a comment anchor given while loading is applied once loaded'] = function()
  child.lua([[
    local routes = _G.routes
    _G.routes = function(req)
      if req.url:find('/stories/301', 1, true) then
        return { status = 200, fixture = 'story_render', hold = true }
      end
      return routes(req)
    end
  ]])
  child.cmd('edit shortcut://story/301')
  child.cmd('edit ' .. child.fn.fnameescape('https://app.shortcut.com/acme/story/301#activity-324'))
  child.lua('vim.wait(50); _G.held[1](); _G.wait_loaded()')
  eq(child.api.nvim_win_get_cursor(0), { 36, 0 })
  eq(messages(), {})
end

T['buffer']['a missing story shows an error'] = function()
  edit('shortcut://story/404')
  local msg = 'story sc-404 not found (it may have been deleted, or be in another workspace)'
  eq(lines(), { 'Failed to load sc-404:', '', msg })
  eq(child.bo.modifiable, false)
  eq(messages(), {
    { msg = 'shortcut.nvim: failed to load sc-404: ' .. msg, level = vim.log.levels.ERROR },
  })
  eq(child.lua_get('story.snapshot()'), vim.NIL)
end

T['buffer']['other errors are shown without stack traces'] = function()
  child.lua([[_G.overrides['/stories/301'] = { status = 500, body = '{}' }]])
  edit('shortcut://story/301')
  eq(lines(), { 'Failed to load sc-301:', '', 'GET /stories/301: HTTP 500: server error' })
end

T['buffer']['a missing token is explained'] = function()
  child.lua('vim.env.SHORTCUT_API_TOKEN = nil')
  edit('shortcut://story/301')
  eq(lines()[1], 'Failed to load sc-301:')
  eq(lines()[3], 'no Shortcut API token found. Do one of:')
  eq(child.lua_get('#_G.requests'), 0)
end

T['buffer']['renders with IDs when the lookup lists are unavailable'] = function()
  child.lua([[_G.overrides['/members'] = { status = 500, body = '{}' }]])
  edit('shortcut://story/301')
  eq(lines()[5], 'owners: [unknown-' .. ALEX .. ', unknown-' .. JDOE .. ']')
  local msgs = messages()
  eq(#msgs, 1)
  eq(msgs[1].level, vim.log.levels.WARN)
  eq(
    msgs[1].msg,
    'shortcut.nvim: lookup lists unavailable, showing IDs instead of names: GET /members: HTTP 500: server error'
  )
end

T['buffer']['renders without the epic name when the epic cannot be fetched'] = function()
  child.lua([[_G.overrides['/epics/201'] = { status = 404, body = '{}' }]])
  edit('shortcut://story/301')
  eq(lines()[6], 'epic: 201 (name unavailable)')
  eq(messages(), {})
end

T['buffer'][':w says editing is not available yet and keeps the changes'] = function()
  edit('shortcut://story/301')
  child.api.nvim_buf_set_lines(0, 11, 12, false, { '# edited' })
  child.cmd('write')
  eq(child.bo.modified, true)
  eq(messages(), {
    {
      msg = 'shortcut.nvim: failed to save sc-301: editing stories is not available yet; the changes were not saved',
      level = vim.log.levels.ERROR,
    },
  })
  eq(count('/stories/301'), 1)
end

T['buffer']['closing the buffer while loading cancels the requests'] = function()
  child.lua([[
    -- Hold the story response until released.
    local routes = _G.routes
    _G.routes = function(req)
      if req.url:find('/stories/301', 1, true) and not _G.release then
        return { status = 200, fixture = 'story_render', hold = true }
      end
      return routes(req)
    end
  ]])
  child.cmd('edit shortcut://story/301')
  local buf = child.api.nvim_get_current_buf()
  eq(child.lua_get('#_G.held'), 1)
  child.cmd('enew | bwipeout ' .. buf)
  eq(child.lua_get('_G.cancelled') > 0, true)
  -- A late answer has no effect.
  child.lua('_G.held[1](); vim.wait(50)')
  eq(messages(), {})
  eq(child.lua_get('story.snapshot(...)', { buf }), vim.NIL)
end

T['buffer']['the story module is loaded on first use only'] = function()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  eq(child.lua_get([[package.loaded['shortcut.buffer.story'] == nil]]), true)
end

return T

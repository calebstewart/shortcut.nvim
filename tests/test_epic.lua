local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local TOKEN = 'test-token-0000-1111-2222-3333wxyz'
local GONE = '00000000-0000-4000-8000-000000000999'
local TEAM_GONE = '00000000-0000-4000-8000-000000000299'

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua([[
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        _G.epic = require('shortcut.buffer.epic')
        _G.fm = require('shortcut.buffer.frontmatter')
        function _G.read_fixture(name)
          local f = assert(io.open(('tests/fixtures/%s.json'):format(name)))
          local s = f:read('*a')
          f:close()
          return s
        end
        function _G.decode(name)
          return vim.json.decode(_G.read_fixture(name), { luanil = { object = true, array = true } })
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
        local epic_states = index(refs.slim('epic_workflow', decode('epic_workflow')).epic_states)
        local members = index(refs.slim('members', decode('members')))
        local labels = index(refs.slim('labels', decode('labels')))
        local groups = index(refs.slim('groups', decode('groups')))
        _G.refs = {
          epic_state = function(id) return epic_states[id] end,
          state = function(id) return states[id] end,
          member = function(id) return members[id] end,
          label = function(id) return labels[id] end,
          group = function(id) return groups[id] end,
        }
      ]])
    end,
    post_once = child.stop,
  },
})

--- Render the `epic_render` fixtures, modified by `patch` (Lua code run with `e` as the epic
--- and `s` as its stories).
---@param patch? string
---@param refs_code? string Lua expression for the refs (default `_G.refs`).
local function render(patch, refs_code)
  return child.lua(
    ([[
    local patch = ...
    local e, s = decode('epic_render'), decode('epic_render_stories')
    if patch ~= nil and patch ~= vim.NIL then loadstring('local e, s = ...; ' .. patch)(e, s) end
    local lines, meta = epic.render(e, s, %s)
    return { lines = lines, meta = meta }
  ]]):format(refs_code or '_G.refs'),
    { patch }
  )
end

local HEADER = {
  '---',
  'id: 202',
  'state: In Progress',
  'owners: [jdoe, Alex.Smith]',
  'teams: [Platform Team, Design Team]',
  'labels: [Frontend, bug]',
  'planned_start: 2026-10-01',
  'deadline: 2026-12-15',
  'stories: 6 (2 done, 2 started, 2 unstarted)',
  'url: https://app.shortcut.com/example-workspace/epic/202',
  '---',
}

local BODY = {
  '# Render Epic',
  '',
  'Epic intro.',
  '',
  'More detail.',
  '',
  '<!-- shortcut:stories -->',
  '## Stories',
  '',
  '### Backlog',
  '- sc-403 Write spec · unowned · 0pt',
  '',
  '### To Do',
  '- sc-404 Pick colours · unowned · 2pt',
  '',
  '### In Progress',
  '- sc-402 Design mockups · Alex.Smith, jdoe',
  '- sc-401 Backend work · jdoe · 3pt',
  '',
  '### Done',
  '- sc-407 Finished API · Alex.Smith · 5pt',
  '',
  '### Shipped',
  '- sc-405 Ship it · jdoe · 1pt',
}

local FULL = vim.list_extend(vim.deepcopy(HEADER), BODY)

T['render()'] = new_set()

T['render()']['groups stories by state across workflows'] = function()
  local r = render()
  eq(r.lines, FULL)
  eq(r.meta, {
    header = { first = 1, last = 11 },
    title = 12,
    description = { first = 14, last = 16 },
    stories_marker = 18,
    stories_section = { first = 18, last = 35 },
    groups = {
      { name = 'Backlog', line = 21, stories = { 403 } },
      { name = 'To Do', line = 24, stories = { 404 } },
      { name = 'In Progress', line = 27, stories = { 402, 401 } },
      { name = 'Done', line = 31, stories = { 407 } },
      { name = 'Shipped', line = 34, stories = { 405 } },
    },
    stories = {
      { id = 403, line = 22 },
      { id = 404, line = 25 },
      { id = 402, line = 28 },
      { id = 401, line = 29 },
      { id = 407, line = 32 },
      { id = 405, line = 35 },
    },
    counts = {
      total = 6,
      backlog = 0,
      unstarted = 2,
      started = 2,
      done = 2,
      unknown = 0,
      other = {},
    },
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
    id = 202,
    state = 'In Progress',
    owners = { 'jdoe', 'Alex.Smith' },
    teams = { 'Platform Team', 'Design Team' },
    labels = { 'Frontend', 'bug' },
    planned_start = '2026-10-01',
    deadline = '2026-12-15',
    stories = '6 (2 done, 2 started, 2 unstarted)',
    url = 'https://app.shortcut.com/example-workspace/epic/202',
  })
end

T['render()']['groups are ordered by state type, then position; stories by position'] = function()
  -- Positions within a workflow decide between groups of the same type.
  local r = render([[
    s[3].workflow_state_id = 513 -- Write spec: Shipped
    s[4].workflow_state_id = 503 -- Pick colours: Done
    s[5].position = 100
    s[7].position = 0
  ]])
  eq(vim.list_slice(r.lines, 21, #r.lines), {
    '### In Progress',
    '- sc-402 Design mockups · Alex.Smith, jdoe',
    '- sc-401 Backend work · jdoe · 3pt',
    '',
    '### Done',
    '- sc-407 Finished API · Alex.Smith · 5pt',
    '- sc-404 Pick colours · unowned · 2pt',
    '',
    '### Shipped',
    '- sc-403 Write spec · unowned · 0pt',
    '- sc-405 Ship it · jdoe · 1pt',
  })
  eq(r.lines[9], 'stories: 6 (4 done, 2 started, 0 unstarted)')
end

T['render()']['states with the same name merge, placed by the earliest'] = function()
  -- A started state named like a done state of another workflow: one group, among the started.
  local r = render(
    [[s[1].workflow_state_id = 999]],
    [[vim.tbl_extend('force', _G.refs, {
      state = function(id)
        if id == 999 then return { id = 999, name = 'Shipped', type = 'started', position = 0 } end
        return _G.refs.state(id)
      end,
    })]]
  )
  eq(vim.list_slice(r.lines, 27, #r.lines), {
    '### Shipped',
    '- sc-405 Ship it · jdoe · 1pt',
    '- sc-401 Backend work · jdoe · 3pt',
    '',
    '### In Progress',
    '- sc-402 Design mockups · Alex.Smith, jdoe',
    '',
    '### Done',
    '- sc-407 Finished API · Alex.Smith · 5pt',
  })
end

T['render()']['backlog states come first and are counted apart'] = function()
  local r = render(
    [[s[7].workflow_state_id = 509]],
    [[vim.tbl_extend('force', _G.refs, {
      state = function(id)
        if id == 509 then return { id = 509, name = 'Icebox', type = 'backlog', position = 9 } end
        return _G.refs.state(id)
      end,
    })]]
  )
  eq(r.lines[9], 'stories: 6 (1 done, 2 started, 2 unstarted, 1 backlog)')
  eq(vim.list_slice(r.lines, 21, 23), {
    '### Icebox',
    '- sc-407 Finished API · Alex.Smith · 5pt',
    '',
  })
  eq(r.meta.counts, {
    total = 6,
    backlog = 1,
    unstarted = 2,
    started = 2,
    done = 1,
    unknown = 0,
    other = {},
  })
end

T['render()']['states of unrecognised types are counted by type, grouped by name'] = function()
  local r = render(
    [[s[7].workflow_state_id = 508; s[5].workflow_state_id = 507; s[1].workflow_state_id = 998]],
    [[vim.tbl_extend('force', _G.refs, {
      state = function(id)
        if id == 508 then return { id = 508, name = 'Parked', type = 'paused', position = 1 } end
        if id == 507 then return { id = 507, name = 'Untyped', type = '', position = 0 } end
        return _G.refs.state(id)
      end,
    })]]
  )
  eq(r.lines[9], 'stories: 6 (0 done, 1 started, 2 unstarted, 1 paused, 2 unknown)')
  eq(r.meta.counts.other, { paused = 1 })
  eq(r.meta.counts.unknown, 2)
  -- Grouped under their real names, after the known types.
  eq(
    vim.tbl_map(function(g)
      return g.name
    end, r.meta.groups),
    { 'Backlog', 'To Do', 'In Progress', 'Untyped', 'Parked', 'unknown-998' }
  )
end

T['render()']['an empty epic'] = function()
  local r = render([[
    for i = #s, 1, -1 do s[i] = nil end
    e.owner_ids = {}
    e.group_ids = {}
    e.label_ids = {}
    e.labels = {}
    e.planned_start_date = vim.NIL
    e.deadline = vim.NIL
    e.description = ''
  ]])
  eq(r.lines, {
    '---',
    'id: 202',
    'state: In Progress',
    'owners: []',
    'teams: []',
    'labels: []',
    'planned_start:',
    'deadline:',
    'stories: 0',
    'url: https://app.shortcut.com/example-workspace/epic/202',
    '---',
    '# Render Epic',
    '',
    '<!-- shortcut:stories -->',
    '## Stories',
    '',
    '*No stories.*',
  })
  eq(r.meta.description, { first = 14, last = 13 })
  eq(r.meta.groups, {})
  eq(r.meta.stories, {})
  eq(r.meta.counts, {
    total = 0,
    backlog = 0,
    unstarted = 0,
    started = 0,
    done = 0,
    unknown = 0,
    other = {},
  })
  -- Without a story list at all.
  local lines = child.lua_get([[epic.render(decode('epic_render'), nil, _G.refs)]])
  eq(lines[9], 'stories: 0')
end

T['render()']['archived stories are hidden and not counted'] = function()
  local r = render()
  for _, line in ipairs(r.lines) do
    eq(line:find('sc-406', 1, true), nil)
  end
  -- Only archived stories: as if empty.
  r = render([[for i = #s, 1, -1 do s[i].archived = true end]])
  eq(r.lines[9], 'stories: 0')
  eq(r.lines[#r.lines], '*No stories.*')
end

T['render()']['unowned and unestimated stories'] = function()
  local r = render([[
    s[1].owner_ids = vim.NIL
    s[1].estimate = vim.NIL
    s[2].owner_ids = {}
  ]])
  eq(r.lines[28], '- sc-402 Design mockups · unowned')
  eq(r.lines[29], '- sc-401 Backend work · unowned')
  -- An estimate of 0 is shown.
  eq(r.lines[22], '- sc-403 Write spec · unowned · 0pt')
end

T['render()']['unknown IDs are shown as unknown-<id> and counted apart'] = function()
  local r = render(
    ([[
    e.owner_ids = { '%s' }
    e.group_ids = { '%s' }
    e.label_ids = { 699 }
    e.labels = {}
    e.epic_state_id = 599
    s[1].owner_ids = { '%s' }
    s[1].workflow_state_id = 998
  ]]):format(GONE, TEAM_GONE, GONE),
    [[vim.tbl_extend('force', _G.refs, {
      epic_state = function() return nil end,
      group = function() return nil end,
      label = function() return nil end,
      member = function(id) if id ~= ']]
      .. GONE
      .. [[' then return _G.refs.member(id) end end,
    })]]
  )
  eq(vim.list_slice(r.lines, 1, 11), {
    '---',
    'id: 202',
    'state: unknown-599',
    'owners: [unknown-' .. GONE .. ']',
    'teams: [unknown-' .. TEAM_GONE .. ']',
    'labels: [unknown-699]',
    'planned_start: 2026-10-01',
    'deadline: 2026-12-15',
    'stories: 6 (2 done, 1 started, 2 unstarted, 1 unknown)',
    'url: https://app.shortcut.com/example-workspace/epic/202',
    '---',
  })
  -- Unknown states come last.
  eq(vim.list_slice(r.lines, #r.lines - 1, #r.lines), {
    '### unknown-998',
    '- sc-401 Backend work · unknown-' .. GONE .. ' · 3pt',
  })

  -- Without any lookups.
  r = render(nil, '{}')
  eq(r.lines[3], 'state: unknown-522')
  eq(r.lines[6], 'labels: [Frontend, unknown-601]')
  eq(r.lines[9], 'stories: 6 (0 done, 0 started, 0 unstarted, 6 unknown)')
  eq(
    vim.tbl_map(function(g)
      return g.name
    end, r.meta.groups),
    {
      'unknown-501',
      'unknown-502',
      'unknown-503',
      'unknown-511',
      'unknown-512',
      'unknown-513',
    }
  )
  -- Rendering is stable.
  eq(render(nil, '{}').lines, r.lines)
end

T['render()']['server strings with newlines stay on one line'] = function()
  local r = render(
    [[
    e.name = 'epic\r\nname'
    e.labels = { { id = 602, name = 'two\nlines' } }
    e.planned_start_date = 'not\na date'
    s[1].name = 'story\nname'
  ]],
    [[vim.tbl_extend('force', _G.refs, {
      member = function() return { mention_name = 'mention\nname' } end,
      state = function(id)
        local st = _G.refs.state(id)
        return st and vim.tbl_extend('force', st, { name = st.name .. '\nx' })
      end,
    })]]
  )
  for i, line in ipairs(r.lines) do
    eq({ i, line:find('\n') }, { i, nil })
  end
  eq(r.lines[4], 'owners: [mention name, mention name]')
  eq(r.lines[6], 'labels: ["two\\nlines", bug]')
  eq(r.lines[7], 'planned_start: not a date')
  eq(r.lines[12], '# epic name')
  eq(r.lines[27], '### In Progress x')
  eq(r.lines[29], '- sc-401 story name · mention name · 3pt')
  child.lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, ...)', { r.lines })
end

T['render()']['is pure: works in a fast event without touching buffers'] = function()
  local out = child.lua([[
    local bufs = vim.api.nvim_list_bufs()
    local result
    local timer = vim.uv.new_timer()
    timer:start(1, 0, function()
      timer:close()
      local ok, lines = pcall(epic.render, decode('epic_render'), decode('epic_render_stories'), _G.refs)
      result = { ok = ok, n = ok and #lines or lines, fast = vim.in_fast_event() }
    end)
    vim.wait(1000, function() return result ~= nil end)
    return { result = result, same_bufs = vim.deep_equal(bufs, vim.api.nvim_list_bufs()) }
  ]])
  eq(out, { result = { ok = true, n = #FULL, fast = true }, same_bufs = true })
end

T['id_at()'] = function()
  local function id_at(line, col)
    return child.lua_get('epic.id_at(...)', { line, col })
  end
  eq(id_at('- sc-401 Backend work · jdoe', 0), 401)
  eq(id_at('See sc-12 and sc-34.', 14), 34)
  eq(id_at('See sc-12 and sc-34.', 2), 12)
  eq(id_at('See sc-12 and sc-34.', 6), 12)
  eq(id_at('xsc-12 sc-12abc nosc-1', 0), vim.NIL)
  eq(id_at('(sc-7)', 0), 7)
  eq(id_at('sc-0', 0), vim.NIL)
  eq(id_at('no id here', 0), vim.NIL)
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
          ['/epic-workflow'] = 'epic_workflow',
          ['/members'] = 'members',
          ['/labels'] = 'labels',
          ['/groups'] = 'groups',
          ['/iterations'] = 'iterations',
          ['/epics/202'] = 'epic_render',
          ['/epics/202/stories'] = 'epic_render_stories',
          ['/stories/301'] = 'story_render',
          ['/stories/401'] = 'story_render',
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

--- Wait until the current buffer is `name` and loaded.
local function wait_for(name)
  child.lua(
    [[
    local name = ...
    vim.wait(2000, function() return vim.api.nvim_buf_get_name(0) == name end, 5)
    _G.wait_loaded()
  ]],
    { name }
  )
end

T['buffer']['shows the rendered epic, with a snapshot'] = function()
  edit('shortcut://epic/202')
  eq(lines(), FULL)
  eq(child.bo.filetype, 'markdown')
  eq(child.bo.modified, false)
  eq(child.bo.modifiable, true)
  eq(child.api.nvim_win_get_cursor(0), { 1, 0 })
  eq(child.fn.undotree().seq_last, 0)
  eq(messages(), {})
  for _, path in ipairs({
    '/epics/202',
    '/epics/202/stories',
    '/workflows',
    '/epic-workflow',
    '/members',
    '/labels',
    '/groups',
  }) do
    eq({ path, count(path) }, { path, 1 })
  end
  local snap = child.lua([[
    local s = epic.snapshot()
    return {
      id = s.epic.id,
      stories = #s.stories,
      updated_at = s.updated_at,
      lines = s.lines,
      groups = #s.meta.groups,
      has_refs = type(s.refs.state) == 'function',
    }
  ]])
  eq(snap, {
    id = 202,
    stories = 7,
    updated_at = '2026-02-05T08:00:00Z',
    lines = FULL,
    groups = 5,
    has_refs = true,
  })
end

T['buffer']['opens through every supported name'] = function()
  edit('https://app.shortcut.com/acme/epic/202/render-epic')
  wait_for('shortcut://epic/202')
  eq(lines(), FULL)
  -- sc-<id>: no such story, so an epic.
  child.cmd('enew')
  edit('sc-202')
  wait_for('shortcut://epic/202')
  eq(lines(), FULL)
  child.cmd('Shortcut epic 202')
  wait_for('shortcut://epic/202')
  eq(lines(), FULL)
  eq(messages(), {})
end

T['buffer']['<CR> on a story line opens the story'] = function()
  edit('shortcut://epic/202')
  local epic_buf = child.api.nvim_get_current_buf()
  child.api.nvim_win_set_cursor(0, { 29, 20 })
  child.type_keys('<CR>')
  wait_for('shortcut://story/401')
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/401')
  eq(count('/stories/401'), 1)
  -- The epic is the alternate buffer.
  eq(child.fn.bufnr('#'), epic_buf)
  eq(messages(), {})
end

T['buffer']['<CR> on another sc-<id> looks it up; elsewhere it moves down'] = function()
  child.lua([[
    local e = vim.json.decode(_G.read_fixture('epic_render'))
    e.description = 'Depends on sc-301.'
    _G.overrides['/epics/202'] = { status = 200, body = vim.json.encode(e) }
  ]])
  edit('shortcut://epic/202')
  eq(lines()[14], 'Depends on sc-301.')
  -- Not a sc-<id> line: the usual <CR>.
  child.api.nvim_win_set_cursor(0, { 12, 0 })
  child.type_keys('<CR>')
  eq(child.api.nvim_win_get_cursor(0), { 13, 0 })
  child.type_keys('2<CR>')
  eq(child.api.nvim_win_get_cursor(0), { 15, 0 })

  child.api.nvim_win_set_cursor(0, { 14, 0 })
  child.type_keys('<CR>')
  wait_for('shortcut://story/301')
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/301')
  eq(messages(), {})
end

T['buffer']['<CR> on lines without an ID runs the <CR> mapping it replaced'] = function()
  -- A global mapping.
  child.lua([[
    _G.global_hits = 0
    vim.keymap.set('n', '<CR>', function() _G.global_hits = _G.global_hits + 1 end)
  ]])
  edit('shortcut://epic/202')
  child.api.nvim_win_set_cursor(0, { 12, 0 })
  child.type_keys('<CR>')
  eq(child.lua_get('_G.global_hits'), 1)
  eq(child.api.nvim_win_get_cursor(0), { 12, 0 })
  -- Story lines still open the story.
  child.api.nvim_win_set_cursor(0, { 29, 0 })
  child.type_keys('<CR>')
  wait_for('shortcut://story/401')
  eq(child.lua_get('_G.global_hits'), 1)

  -- A buffer-local mapping from a markdown plugin (string rhs, with a count) wins over it, and
  -- is kept across :e!.
  child.lua([[
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'markdown',
      command = 'nnoremap <buffer> <CR> :<C-U>let g:md_hits = get(g:, "md_hits", 0) + v:count1<CR>',
    })
  ]])
  child.cmd('bwipeout! shortcut://epic/202')
  edit('shortcut://epic/202')
  eq(lines(), FULL)
  child.cmd('edit!')
  child.lua('_G.wait_loaded()')
  child.api.nvim_win_set_cursor(0, { 12, 0 })
  child.type_keys('3<CR>')
  eq(child.lua_get('vim.g.md_hits'), 3)
  eq(child.lua_get('_G.global_hits'), 1)
  eq(child.api.nvim_win_get_cursor(0), { 12, 0 })
  eq(
    child.lua_get([[vim.fn.maparg('<CR>', 'n', false, true).desc]]),
    'shortcut.nvim: open the sc-<id> on this line'
  )
end

T['buffer'][':e! picks up a markdown <CR> mapping set up since the buffer was opened'] = function()
  edit('shortcut://epic/202')
  -- E.g. a markdown plugin loaded lazily after the epic was opened: its FileType handler only
  -- runs for this buffer when :e! sets the filetype again.
  child.lua([[
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'markdown',
      command = 'nnoremap <buffer> <CR> :<C-U>let g:md_hits = get(g:, "md_hits", 0) + v:count1<CR>',
    })
  ]])
  -- Twice: on the second reload our own mapping is in place until FileType replaces it, and
  -- must not be taken for the one to replay.
  for _ = 1, 2 do
    child.cmd('edit!')
    child.lua('_G.wait_loaded()')
  end
  eq(
    child.lua_get([[vim.fn.maparg('<CR>', 'n', false, true).desc]]),
    'shortcut.nvim: open the sc-<id> on this line'
  )
  child.api.nvim_win_set_cursor(0, { 12, 0 })
  child.type_keys('2<CR>')
  eq(child.lua_get('vim.g.md_hits'), 2)
  eq(child.api.nvim_win_get_cursor(0), { 12, 0 })
  -- Story lines still open the story.
  child.api.nvim_win_set_cursor(0, { 29, 0 })
  child.type_keys('<CR>')
  wait_for('shortcut://story/401')
  eq(child.lua_get('vim.g.md_hits'), 2)
end

--- Count calls to the epic `<CR>` handler, failing after a few so that a loop ends.
local function count_cr_calls()
  child.lua([[
    _G.cr_calls = 0
    local orig = epic.open_at_cursor
    epic.open_at_cursor = function()
      _G.cr_calls = _G.cr_calls + 1
      if _G.cr_calls > 20 then error('looping') end
      return orig()
    end
  ]])
end

T['buffer']['<CR> replay: a remapping rhs starting with <CR> does not loop'] = function()
  count_cr_calls()
  child.cmd('nmap <CR> <CR>zz')
  edit('shortcut://epic/202')
  child.api.nvim_win_set_cursor(0, { 12, 0 })
  child.type_keys('<CR>')
  child.lua('vim.wait(20)')
  eq(child.lua_get('_G.cr_calls'), 1)
  eq(child.api.nvim_win_get_cursor(0), { 13, 0 })
  -- Nor does one with <CR> later on (Neovim itself would stop with E223).
  child.cmd('nmap <CR> j<CR>')
  child.api.nvim_win_set_cursor(0, { 12, 0 })
  child.type_keys('<CR>')
  child.lua('vim.wait(20)')
  eq(child.lua_get('_G.cr_calls'), 2)
  eq(child.api.nvim_win_get_cursor(0), { 14, 0 })
  -- Special keys whose code contains a `\r` byte are not split.
  child.cmd('nnoremap <S-F8> 3j')
  child.cmd('nmap <CR> <S-F8>')
  child.api.nvim_win_set_cursor(0, { 12, 0 })
  child.type_keys('<CR>')
  child.lua('vim.wait(20)')
  eq(child.lua_get('_G.cr_calls'), 3)
  eq(child.api.nvim_win_get_cursor(0), { 15, 0 })
  eq(messages(), {})
end

T['buffer']['<CR> replay runs before keys typed after it, with the count'] = function()
  child.cmd('nnoremap <CR> 2j')
  edit('shortcut://epic/202')
  child.api.nvim_win_set_cursor(0, { 12, 0 })
  -- As in a macro: `x` runs after the move.
  child.cmd('execute "normal \\<CR>x"')
  eq(child.api.nvim_win_get_cursor(0), { 14, 0 })
  eq(lines()[14], 'pic intro.')
  eq(lines()[12], '# Render Epic')
  child.cmd('undo')

  -- Expr mappings get the count too.
  child.lua([[vim.keymap.set('n', '<CR>', function() return 'j' end, { expr = true })]])
  child.api.nvim_win_set_cursor(0, { 12, 0 })
  child.type_keys('3<CR>')
  eq(child.api.nvim_win_get_cursor(0), { 15, 0 })
  child.cmd([[nnoremap <expr> <CR> 'k']])
  child.type_keys('2<CR>')
  eq(child.api.nvim_win_get_cursor(0), { 13, 0 })
  eq(messages(), {})
end

T['buffer']['<CR> replay keeps the register typed before it'] = function()
  child.cmd('nnoremap <CR> p')
  edit('shortcut://epic/202')
  child.fn.setreg('"', 'U', 'c')
  child.fn.setreg('a', 'A', 'c')
  local function paste(keys)
    child.api.nvim_win_set_cursor(0, { 12, 0 })
    child.type_keys(keys)
    local line = lines()[12]
    child.cmd('silent undo')
    return line
  end
  eq(paste('<CR>'), '#U Render Epic')
  eq(paste('"a<CR>'), '#A Render Epic')
  eq(paste('"a2<CR>'), '#AA Render Epic')
  eq(paste('2"a<CR>'), '#AA Render Epic')
  -- The expression register: its result is pasted, without a second prompt.
  eq(paste({ '"=', '"X"', '<CR>', '<CR>' }), '#X Render Epic')
  eq(paste({ '"=', '"Y"', '<CR>', '2<CR>' }), '#YY Render Epic')
  eq(child.fn.mode(), 'n')
  -- Nor are the mapping's keys typed into an expression prompt.
  child.cmd('nmap <CR> :let g:z = 1<CR>')
  child.type_keys('"=', '"Z"', '<CR>', '<CR>')
  eq(child.fn.mode(), 'n')
  eq(child.g.z, 1)
  eq(lines()[12], '# Render Epic')
  child.cmd('nnoremap <CR> p')

  -- With 'clipboard', the default register is the clipboard one: it is not passed on, so the
  -- paste still comes from the clipboard, and an explicit register still wins.
  child.lua([[
    vim.g.clipboard = {
      name = 'test',
      copy = { ['+'] = function() end, ['*'] = function() end },
      paste = { ['+'] = function() return { 'P' } end, ['*'] = function() return { 'S' } end },
    }
  ]])
  child.o.clipboard = 'unnamedplus'
  child.type_keys('<Esc>') -- v:register follows 'clipboard' after the next command.
  eq(paste('<CR>'), '#P Render Epic')
  eq(paste('"a<CR>'), '#A Render Epic')
  eq(paste('"*<CR>'), '#S Render Epic')
  eq(messages(), {})
end

T['buffer']['gf on a story line opens the story'] = function()
  edit('shortcut://epic/202')
  child.api.nvim_win_set_cursor(0, { 29, 4 })
  child.type_keys('gf')
  wait_for('shortcut://story/401')
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/401')
end

T['buffer']['modelines in epic content are never applied'] = function()
  child.lua([[
    local e = vim.json.decode(_G.read_fixture('epic_render'))
    e.description = 'vim: set ts=3 sw=3 tw=13 ft=lua :'
    _G.overrides['/epics/202'] = { status = 200, body = vim.json.encode(e) }
    local s = vim.json.decode(_G.read_fixture('epic_render_stories'))
    s[5].name = 'vim: set ts=3 sw=3 tw=13 ft=lua :'
    _G.overrides['/epics/202/stories'] = { status = 200, body = vim.json.encode(s) }
  ]])
  edit('shortcut://epic/202')
  eq(lines()[14], 'vim: set ts=3 sw=3 tw=13 ft=lua :')
  eq(lines()[#lines()], '- sc-405 vim: set ts=3 sw=3 tw=13 ft=lua : · jdoe · 1pt')
  local before = child.lua_get('{ vim.bo.ts, vim.bo.sw, vim.bo.tw }')
  eq(child.bo.modeline, false)
  child.lua([[
    vim.api.nvim_create_autocmd('User', { pattern = 'SomePluginEvent', callback = function() end })
    vim.api.nvim_exec_autocmds('User', { pattern = 'SomePluginEvent', modeline = true })
    vim.cmd('doautocmd BufEnter')
    vim.cmd('doautocmd BufRead')
  ]])
  eq(child.bo.modeline, false)
  eq(child.bo.filetype, 'markdown')
  eq(child.lua_get('{ vim.bo.ts, vim.bo.sw, vim.bo.tw }'), before)
end

T['buffer'][':e! fetches the epic again'] = function()
  edit('shortcut://epic/202')
  child.lua([[
    local e = vim.json.decode(_G.read_fixture('epic_render'))
    e.name = 'Renamed'
    _G.overrides['/epics/202'] = { status = 200, body = vim.json.encode(e) }
  ]])
  child.api.nvim_buf_set_lines(0, 11, 12, false, { '# local edit' })
  child.cmd('edit!')
  child.lua('_G.wait_loaded()')
  eq(count('/epics/202'), 2)
  eq(count('/epics/202/stories'), 2)
  eq(lines()[12], '# Renamed')
  eq(child.bo.modified, false)
  eq(child.lua_get('epic.snapshot().lines[12]'), '# Renamed')
end

T['buffer']['a missing epic shows an error'] = function()
  edit('shortcut://epic/404')
  local msg = 'epic sc-404 not found (it may have been deleted, or be in another workspace)'
  eq(lines(), { 'Failed to load sc-404:', '', msg })
  eq(child.bo.modifiable, false)
  eq(messages(), {
    { msg = 'shortcut.nvim: failed to load sc-404: ' .. msg, level = vim.log.levels.ERROR },
  })
  eq(child.lua_get('epic.snapshot()'), vim.NIL)
end

T['buffer']['a failed story list is an error, without stack traces'] = function()
  child.lua([[_G.overrides['/epics/202/stories'] = { status = 500, body = '{}' }]])
  edit('shortcut://epic/202')
  eq(lines(), { 'Failed to load sc-202:', '', 'GET /epics/202/stories: HTTP 500: server error' })
  child.lua([[_G.overrides['/epics/202/stories'] = { status = 200, body = '{"not": "a list"}' }]])
  child.cmd('edit!')
  child.lua('_G.wait_loaded()')
  eq(lines(), { 'Failed to load sc-202:', '', 'unexpected response from GET /epics/202/stories' })
end

T['buffer']['renders with IDs when the lookup lists are unavailable'] = function()
  child.lua([[_G.overrides['/groups'] = { status = 500, body = '{}' }]])
  edit('shortcut://epic/202')
  eq(
    lines()[5],
    'teams: [unknown-00000000-0000-4000-8000-000000000201, unknown-00000000-0000-4000-8000-000000000202]'
  )
  local msgs = messages()
  eq(#msgs, 1)
  eq(msgs[1].level, vim.log.levels.WARN)
  eq(
    msgs[1].msg,
    'shortcut.nvim: lookup lists unavailable, showing IDs instead of names: GET /groups: HTTP 500: server error'
  )
end

T['buffer'][':w says editing is not available yet and keeps the changes'] = function()
  edit('shortcut://epic/202')
  child.api.nvim_buf_set_lines(0, 11, 12, false, { '# edited' })
  child.cmd('write')
  eq(child.bo.modified, true)
  eq(messages(), {
    {
      msg = 'shortcut.nvim: failed to save sc-202: editing epics is not available yet; the changes were not saved',
      level = vim.log.levels.ERROR,
    },
  })
  eq(count('/epics/202'), 1)
end

T['buffer']['a link with a comment anchor opens an already-loaded epic'] = function()
  edit('shortcut://epic/202')
  edit('https://app.shortcut.com/acme/epic/202#activity-5')
  child.lua('vim.wait(50)')
  eq(child.api.nvim_buf_get_name(0), 'shortcut://epic/202')
  eq(messages(), {})
end

T['buffer']['closing the buffer while loading cancels the requests'] = function()
  child.lua([[
    local routes = _G.routes
    _G.routes = function(req)
      if req.url:find('/epics/202', 1, true) then
        return { status = 200, fixture = req.url:find('stories') and 'epic_render_stories' or 'epic_render', hold = true }
      end
      return routes(req)
    end
  ]])
  child.cmd('edit shortcut://epic/202')
  local buf = child.api.nvim_get_current_buf()
  eq(child.lua_get('#_G.held'), 2)
  child.cmd('enew | bwipeout ' .. buf)
  eq(child.lua_get('_G.cancelled') >= 2, true)
  child.lua('for _, h in ipairs(_G.held) do h() end; vim.wait(50)')
  eq(messages(), {})
  eq(child.lua_get('epic.snapshot(...)', { buf }), vim.NIL)
end

T['buffer']['the epic module is loaded on first use only'] = function()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  eq(child.lua_get([[package.loaded['shortcut.buffer.epic'] == nil]]), true)
end

return T

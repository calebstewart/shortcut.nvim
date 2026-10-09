-- Creating stories from drafts (`:Shortcut create`), in a child Neovim against a fake Shortcut
-- server (no network).
local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local TOKEN = 'test-token-0000-1111-2222-3333wxyz'
local JDOE = '00000000-0000-4000-8000-000000000101'
local ALEX = '00000000-0000-4000-8000-000000000102'
local PLATFORM = '00000000-0000-4000-8000-000000000201'
local DESIGN = '00000000-0000-4000-8000-000000000202'

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua(
        [[
        vim.env.SHORTCUT_API_TOKEN = ...
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        dofile('tests/fake_transport.lua')
        _G.create = require('shortcut.buffer.story_create')
        _G.story = require('shortcut.buffer.story')

        local function decode(s)
          return vim.json.decode(s, { luanil = { object = true, array = true } })
        end
        local function json(status, data)
          return { status = status, body = data ~= nil and vim.json.encode(data) or '' }
        end
        _G.writes = {}   -- non-GET requests: { method, path, body }
        _G.fail = {}     -- '<METHOD> <path>' -> response, instead of the normal one
        _G.hold = {}     -- '<METHOD> <path>' -> true: the answer waits in _G.held
        _G.created = {}  -- stories created, by ID
        _G.default_workflow = 500
        local next_id = 900
        local lists = {
          ['/workflows'] = 'workflows',
          ['/members'] = 'members',
          ['/labels'] = 'labels',
          ['/iterations'] = 'iterations',
        }
        _G.routes = function(req)
          local path = req.url:gsub('^https://api%.app%.shortcut%.com/api/v3', ''):gsub('%?.*', '')
          local method = req.method
          if method ~= 'GET' then
            table.insert(_G.writes, {
              method = method,
              path = path,
              body = req.body and vim.json.decode(req.body) or nil,
            })
          end
          local key = method .. ' ' .. path
          local res = _G.fail[key]
          if not res and lists[path] then res = { status = 200, fixture = lists[path] } end
          if not res and path == '/member' then
            local m = decode(_G.fixture('member'))
            m.workspace2.default_workflow_id = _G.default_workflow
            res = json(200, m)
          end
          if not res and path == '/groups' then
            local groups = decode(_G.fixture('groups'))
            groups[2].default_workflow_id = 510
            res = json(200, groups)
          end
          local epic = path:match('^/epics/(%d+)$')
          if not res and epic then
            if epic == '999' then
              res = json(404, { message = 'Resource not found.' })
            else
              local e = decode(_G.fixture('epic'))
              e.id = tonumber(epic)
              e.name = 'Epic ' .. epic
              res = json(200, e)
            end
          end
          if not res and key == 'POST /stories' then
            local body = decode(req.body)
            next_id = next_id + 1
            local s = decode(_G.fixture('story_render'))
            s.id = next_id
            s.app_url = 'https://app.shortcut.com/example-workspace/story/' .. next_id
            s.name = body.name
            s.description = body.description or ''
            s.story_type = body.story_type
            s.workflow_state_id = body.workflow_state_id
            s.workflow_id = (body.workflow_state_id or 0) >= 510 and 510 or 500
            s.owner_ids = body.owner_ids or {}
            s.epic_id = body.epic_id
            s.iteration_id = body.iteration_id
            s.estimate = body.estimate
            s.labels, s.label_ids = {}, {}
            s.comments = {}
            s.tasks = {}
            for i, t in ipairs(body.tasks or {}) do
              table.insert(s.tasks, {
                id = next_id * 10 + i,
                description = t.description,
                complete = t.complete == true,
                owner_ids = t.owner_ids or {},
                position = i,
              })
            end
            _G.created[next_id] = s
            res = json(201, s)
          end
          local id = path:match('^/stories/(%d+)$')
          if not res and id and _G.created[tonumber(id)] then
            res = json(200, _G.created[tonumber(id)])
          end
          res = res or json(404, { message = 'Resource not found.' })
          if _G.hold[key] then
            res = vim.deepcopy(res)
            res.hold = true
          end
          return res
        end

        function _G.wait_draft(n)
          vim.wait(2000, function()
            return vim.api.nvim_buf_get_name(0) == 'shortcut://story/new-' .. (n or 1)
          end, 5)
        end
        function _G.wait_story(id)
          vim.wait(2000, function()
            local first = vim.api.nvim_buf_get_lines(0, 0, 2, false)[2] or ''
            return vim.api.nvim_buf_get_name(0) == 'shortcut://story/' .. id
              and first == 'id: ' .. id
          end, 5)
        end
      ]],
        { TOKEN }
      )
    end,
    post_once = child.stop,
  },
})

local function lines()
  return child.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function writes()
  return child.lua_get('_G.writes')
end

local function posts()
  return vim.tbl_filter(function(w)
    return w.method == 'POST' and w.path == '/stories'
  end, writes())
end

local function messages()
  return child.lua_get('_G.messages')
end

local function last_message()
  local m = messages()
  return m[#m]
end

local function diagnostics()
  return child.lua_get([[vim.tbl_map(function(d)
    return { lnum = d.lnum + 1, message = d.message }
  end, vim.diagnostic.get(0, { namespace = story.edit_ns() }))]])
end

--- `:Shortcut create ...`, then wait for the draft.
local function open(args, n)
  child.cmd('Shortcut create' .. (args and (' ' .. args) or ''))
  child.lua('_G.wait_draft(...)', { n or 1 })
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/new-' .. (n or 1))
  child.cmd('stopinsert')
end

--- Replace the draft's lines.
local function fill(new)
  child.api.nvim_buf_set_lines(0, 0, -1, false, new)
end

local INFO, WARN, ERROR = vim.log.levels.INFO, vim.log.levels.WARN, vim.log.levels.ERROR

local TEMPLATE = {
  '---',
  'type: feature',
  'state: Backlog',
  'owners: [jdoe]',
  'epic:',
  'iteration:',
  'estimate:',
  'labels: []',
  '---',
  '# ',
  '',
  '<!-- shortcut:tasks -->',
  '## Tasks',
}

--- A filled-in draft.
local function filled(header)
  local out = { '---' }
  vim.list_extend(out, header or {
    'type: bug',
    'state: In Progress',
    'owners: [jdoe, Alex.Smith]',
    'epic: 678',
    'iteration: Sprint 2',
    'estimate: 3',
    'labels: [Frontend, bug]',
  })
  vim.list_extend(out, {
    '---',
    '# Fix the thing',
    '',
    'Some *details*.',
    '',
    '<!-- shortcut:tasks -->',
    '## Tasks',
    '- [ ] Write a test',
    '- [x] Find the bug · @Alex.Smith @jdoe',
    '- [ ] Escaped \\· @jdoe',
  })
  return out
end

---------------------------------------------------------------------------------------------------
-- Pure parts
---------------------------------------------------------------------------------------------------

T['arguments'] = new_set()

T['arguments']['key=value, lists and aliases'] = function()
  eq(
    child.lua_get([[create.parse_args({
      'epic=678', 'type=bug', 'state=In Progress', 'owner=jdoe, @Alex.Smith', 'labels=',
      'estimate=0', 'iteration=Sprint 2', 'workflow=Design', 'team=platform', 'epic=',
    })]]),
    {
      epic = vim.NIL,
      type = 'bug',
      state = 'In Progress',
      owners = { 'jdoe', 'Alex.Smith' },
      labels = {},
      estimate = 0,
      iteration = 'Sprint 2',
      workflow = 'Design',
      team = 'platform',
    }
  )
end

T['arguments']['invalid ones are errors'] = function()
  for arg, msg in pairs({
    ['nope=1'] = "invalid argument 'nope=1'",
    ['type'] = "invalid argument 'type'",
    ['type=bgu'] = "type: 'bgu' is not a story type",
    ['epic=abc'] = "epic: expected an epic ID, got 'abc'",
    ['epic=0'] = 'epic: expected an epic ID',
    ['estimate=-1'] = 'estimate: expected a non-negative integer',
  }) do
    local err = child.lua_get('select(2, pcall(create.parse_args, { ... }))', { arg })
    eq(type(err) == 'string' and err:find(msg, 1, true) ~= nil, true)
  end
end

T['render()'] = new_set()

T['render()']['the template of the issue'] = function()
  eq(
    child.lua_get([[create.render({
      title = '', description = '', type = 'feature', state = 'Backlog', owners = { 'jdoe' },
      labels = {}, tasks = {},
    })]]),
    TEMPLATE
  )
  eq(
    child.lua_get(
      [[select(2, create.render({ title = 'x', owners = {}, labels = {}, tasks = {} }))]]
    ),
    10
  )
end

T['render()']['every field, tasks with and without owners'] = function()
  local out = child.lua_get([[create.render({
    title = 'Title', description = '\nLine 1\nLine 2\n\n', type = 'bug', state = 'In Progress',
    owners = { 'jdoe' }, epic = 678, iteration = 'Sprint 2', estimate = 3,
    labels = { 'Frontend', 'a: b' },
    tasks = { 'Plain', { description = 'Done', complete = true, owners = { 'jdoe', 'Alex.Smith' } },
      { description = 'Ends in · @word' } },
  })]])
  eq(out, {
    '---',
    'type: bug',
    'state: In Progress',
    'owners: [jdoe]',
    'epic: 678',
    'iteration: Sprint 2',
    'estimate: 3',
    'labels: [Frontend, "a: b"]',
    '---',
    '# Title',
    '',
    'Line 1',
    'Line 2',
    '',
    '<!-- shortcut:tasks -->',
    '## Tasks',
    '- [ ] Plain',
    '- [x] Done · @jdoe @Alex.Smith',
    '- [ ] Ends in \\· @word',
  })
  -- Reads back as written.
  local parsed = child.lua_get('{ require("shortcut.buffer.story_parse").parse(...) }', {
    out,
    { draft = true },
  })
  eq(parsed[2], {})
  eq(parsed[1].tasks[3].description, 'Ends in · @word')
end

T['parse()'] = new_set()

T['parse()']['a draft has no id, url or comments'] = function()
  local function parse(l)
    return child.lua_get(
      '{ require("shortcut.buffer.story_parse").parse(...) }',
      { l, { draft = true } }
    )
  end
  local r = parse(TEMPLATE)
  eq(r[2], { { line = 10, message = 'the title cannot be empty' } })
  eq(r[1].comments_marker, 14)

  local with_id = vim.deepcopy(TEMPLATE)
  table.insert(with_id, 2, 'id: 5')
  eq(parse(with_id)[2][1].message:find("unknown header field 'id'", 1, true) ~= nil, true)

  local no_marker = vim.deepcopy(TEMPLATE)
  table.remove(no_marker, 12)
  eq(parse(no_marker)[2], {
    {
      line = 9,
      message = "the line '<!-- shortcut:tasks -->' is missing (it must come before the tasks); add it back",
    },
  })

  local missing = vim.deepcopy(TEMPLATE)
  table.remove(missing, 7)
  eq(parse(missing)[2][1].message, "missing header field 'estimate'; add it back")
end

T['body'] = new_set()

--- `story_diff.create()` on `l`, with the cache's lookups.
local function body(l, ctx)
  child.lua('_G.loaded = nil; require("shortcut.cache").load(nil, function() _G.loaded = true end)')
  child.lua('vim.wait(2000, function() return _G.loaded end, 5)')
  return child.lua_get(
    [[(function(l, ctx)
      local cur, errors = require('shortcut.buffer.story_parse').parse(l, { draft = true })
      local c, errs = require('shortcut.buffer.story_diff').create(cur, vim.tbl_extend('force', {
        workflow_id = 500,
        lookup = require('shortcut.buffer.story_save').cache_lookup(),
      }, ctx or {}))
      return { body = c.body, epic = c.epic, errors = vim.list_extend(errors, errs) }
    end)(...)]],
    { l, ctx or vim.empty_dict() }
  )
end

T['body']['every field, and tasks with and without owners'] = function()
  eq(body(filled(), { group_id = PLATFORM }), {
    body = {
      name = 'Fix the thing',
      description = 'Some *details*.',
      story_type = 'bug',
      workflow_state_id = 502,
      owner_ids = { JDOE, ALEX },
      epic_id = 678,
      iteration_id = 702,
      estimate = 3,
      labels = { { name = 'Frontend' }, { name = 'bug' } },
      group_id = PLATFORM,
      tasks = {
        { description = 'Write a test', complete = false },
        { description = 'Find the bug', complete = true, owner_ids = { ALEX, JDOE } },
        { description = 'Escaped · @jdoe', complete = false },
      },
    },
    epic = { id = 678, line = 5 },
    errors = {},
  })
end

T['body']['empty fields are left out'] = function()
  local l = filled({
    'type: chore',
    'state: backlog',
    'owners: []',
    'epic:',
    'iteration:',
    'estimate:',
    'labels: []',
  })
  local r = body(vim.list_slice(l, 1, 14))
  eq(r.body, {
    name = 'Fix the thing',
    description = 'Some *details*.',
    story_type = 'chore',
    workflow_state_id = 501,
  })
  eq(r.errors, {})
end

T['body']['names are checked as when editing'] = function()
  local r = body(filled({
    'type: bug',
    'state: Shipped',
    'owners: [former, nobody, unknown-' .. JDOE .. ']',
    'epic: 678',
    'iteration: Sprint 9',
    'estimate: 3',
    'labels: [Frontend, newlabel]',
  }))
  local msgs = vim.tbl_map(function(e)
    return e.line .. ' ' .. e.message
  end, r.errors)
  eq(msgs, {
    "3 state: unknown state 'Shipped' in workflow 'Engineering'",
    "4 owners: member '@former' is disabled in the workspace",
    "4 owners: unknown member 'nobody'",
    "4 owners: unknown member 'unknown-" .. JDOE .. "'",
    "6 iteration: unknown iteration 'Sprint 9' (did you mean 'Sprint 1', 'Sprint 2'?)",
    "8 labels: unknown label 'newlabel'",
  })
  -- A state of the draft's workflow.
  local l = filled()
  l[3] = 'state: Backlog'
  local e = body(l, { workflow_id = 510 }).errors
  eq(#e, 1)
  eq(vim.startswith(e[1].message, "state: unknown state 'Backlog' in workflow 'Design'"), true)
  eq(body(filled(), { workflow_id = 510 }).body.workflow_state_id, 512)
end

---------------------------------------------------------------------------------------------------
-- :Shortcut create
---------------------------------------------------------------------------------------------------

T[':Shortcut create'] = new_set()

T[':Shortcut create']['opens a template, in insert mode on the title line'] = function()
  child.cmd('Shortcut create')
  child.lua('_G.wait_draft(1)')
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/new-1')
  eq(lines(), TEMPLATE)
  eq(child.fn.mode(), 'i')
  eq(child.api.nvim_win_get_cursor(0)[1], 10)
  eq(child.bo.buftype, 'acwrite')
  eq(child.bo.modeline, false)
  eq(child.bo.filetype, 'markdown')
  eq(child.bo.modified, false)
  eq(child.lua_get('vim.b.shortcut'), vim.NIL)
  eq(writes(), {})
end

T[':Shortcut create']['arguments override the defaults'] = function()
  open([[epic=678 type=bug state=In\ Progress owners=jdoe,Alex.Smith labels=Frontend estimate=2]])
  eq(vim.list_slice(lines(), 1, 9), {
    '---',
    'type: bug',
    'state: In Progress',
    'owners: [jdoe, Alex.Smith]',
    'epic: 678',
    'iteration:',
    'estimate: 2',
    'labels: [Frontend]',
    '---',
  })
end

T[':Shortcut create']['create.workflow, or the team default workflow'] = function()
  child.lua([[require('shortcut').setup({ create = { workflow = 'design' } })]])
  open()
  eq(lines()[3], 'state: To Do')
  child.cmd('Shortcut create workflow=Engineering')
  child.lua('_G.wait_draft(2)')
  eq(lines()[3], 'state: Backlog')

  child.lua([[require('shortcut').setup({ create = { team = 'Design Team' } })]])
  child.cmd('Shortcut create')
  child.lua('_G.wait_draft(3)')
  eq(lines()[3], 'state: To Do')
  eq(child.lua_get('create.draft().group_id'), DESIGN)
  eq(child.lua_get('create.draft().workflow_id'), 510)
  -- A team without its own default workflow: the workspace's.
  child.cmd('Shortcut create team=@platform')
  child.lua('_G.wait_draft(4)')
  eq(child.lua_get('create.draft().group_id'), PLATFORM)
  eq(child.lua_get('create.draft().workflow_id'), 500)
end

T[':Shortcut create']['the workspace default workflow'] = function()
  child.lua('_G.default_workflow = 510')
  open()
  eq(lines()[3], 'state: To Do')
  eq(child.lua_get('create.draft().workflow_id'), 510)
  eq(child.lua_get('create.draft().group_id'), vim.NIL)
end

T[':Shortcut create']['create.template customizes the fields'] = function()
  child.lua([[require('shortcut').setup({ create = { template = function(f)
    f.type = 'chore'
    f.labels = { 'Frontend' }
    f.description = '## Why\n'
    f.tasks = { 'Review' }
    f.owners = {}
  end } })]])
  open('type=bug')
  eq(lines(), {
    '---',
    'type: bug',
    'state: Backlog',
    'owners: []',
    'epic:',
    'iteration:',
    'estimate:',
    'labels: [Frontend]',
    '---',
    '# ',
    '',
    '## Why',
    '',
    '<!-- shortcut:tasks -->',
    '## Tasks',
    '- [ ] Review',
  })
  -- A new table works too; a broken function is reported and opens nothing.
  child.lua([[require('shortcut').setup({ create = { template = function(f)
    return { title = 'From scratch', state = f.state }
  end } })]])
  open(nil, 2)
  eq(lines()[4], 'owners: []')
  eq(lines()[10], '# From scratch')
  child.lua([[require('shortcut').setup({ create = { template = function() error('boom') end } })]])
  child.cmd('Shortcut create')
  child.lua('vim.wait(200, function() return #_G.messages > 0 end, 5)')
  eq(last_message().level, ERROR)
  eq(last_message().msg:find('create: create.template: ', 1, true) ~= nil, true)
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/new-2')
end

T[':Shortcut create']['an unknown workflow or team opens nothing'] = function()
  child.cmd('Shortcut create workflow=Nope')
  child.lua('vim.wait(500, function() return #_G.messages > 0 end, 5)')
  eq(last_message(), {
    msg = "shortcut.nvim: create: workflow: unknown workflow 'Nope' (workflows: 'Engineering', 'Design')",
    level = ERROR,
  })
  child.cmd('Shortcut create team=nope')
  child.lua('vim.wait(500, function() return #_G.messages > 1 end, 5)')
  eq(last_message(), {
    msg = "shortcut.nvim: create: team: unknown team 'nope'",
    level = ERROR,
  })
  child.cmd('Shortcut create bogus')
  eq(last_message().msg:find("create: invalid argument 'bogus'", 1, true) ~= nil, true)
  eq(child.api.nvim_buf_get_name(0), '')
end

T[':Shortcut create']['completion'] = function()
  local function complete(line)
    return child.lua_get(
      'require("shortcut.commands").complete(...)',
      { line:match('(%S*)$'), line, #line }
    )
  end
  eq(complete('Shortcut create '), {
    'type=',
    'state=',
    'owners=',
    'epic=',
    'iteration=',
    'estimate=',
    'labels=',
    'workflow=',
    'team=',
  })
  eq(complete('Shortcut create ty'), { 'type=' })
  eq(complete('Shortcut create type='), { 'type=bug', 'type=chore', 'type=feature' })
  -- The lists are fetched in the background for the next try.
  eq(complete('Shortcut create state=In'), {})
  child.lua(
    'vim.wait(2000, function() return require("shortcut.cache").list("labels") ~= nil end, 5)'
  )
  eq(complete('Shortcut create state=In'), { 'state=In\\ Progress' })
  eq(complete('Shortcut create workflow=Design state='), {
    'state=In\\ Progress',
    'state=Shipped',
    'state=To\\ Do',
  })
  eq(complete('Shortcut create labels=bug,f'), { 'labels=bug,Frontend' })
  eq(complete('Shortcut create owners='), { 'owners=Alex.Smith', 'owners=jdoe' })
  eq(complete('Shortcut create iteration=s'), { 'iteration=Sprint\\ 2' })
  eq(complete('Shortcut create workflow='), { 'workflow=Design', 'workflow=Engineering' })
end

---------------------------------------------------------------------------------------------------
-- :w
---------------------------------------------------------------------------------------------------

T[':w'] = new_set()

T[':w']['creates the story, then shows it instead of the draft'] = function()
  open()
  local draft = child.api.nvim_get_current_buf()
  fill(filled())
  child.cmd('write')
  child.lua('_G.wait_story(901)')
  eq(#posts(), 1)
  eq(posts()[1].body, {
    name = 'Fix the thing',
    description = 'Some *details*.',
    story_type = 'bug',
    workflow_state_id = 502,
    owner_ids = { JDOE, ALEX },
    epic_id = 678,
    iteration_id = 702,
    estimate = 3,
    labels = { { name = 'Frontend' }, { name = 'bug' } },
    tasks = {
      { description = 'Write a test', complete = false },
      { description = 'Find the bug', complete = true, owner_ids = { ALEX, JDOE } },
      { description = 'Escaped · @jdoe', complete = false },
    },
  })
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/901')
  eq(lines()[12], '# Fix the thing')
  eq(child.api.nvim_buf_is_valid(draft), false)
  eq(child.bo.modified, false)
  eq(
    last_message(),
    { msg = 'shortcut.nvim: Created sc-901 (:Shortcut yank copies its link)', level = INFO }
  )
  -- The epic was checked first.
  eq(
    child.lua_get([[vim.tbl_contains(vim.tbl_map(function(r) return r.url end, _G.requests),
      'https://api.app.shortcut.com/api/v3/epics/678')]]),
    true
  )
end

T[':w']['the team is assigned'] = function()
  open('team=platform')
  fill(vim.list_slice(
    filled({
      'type: bug',
      'state: Backlog',
      'owners: []',
      'epic:',
      'iteration:',
      'estimate:',
      'labels: []',
    }),
    1,
    14
  ))
  child.cmd('write')
  child.lua('_G.wait_story(901)')
  eq(posts()[1].body.group_id, PLATFORM)
end

T[':w']['two drafts coexist'] = function()
  open()
  fill(filled())
  child.cmd('split')
  open(nil, 2)
  local second = child.api.nvim_get_current_buf()
  fill(vim.list_slice(
    filled({
      'type: bug',
      'state: Backlog',
      'owners: []',
      'epic:',
      'iteration:',
      'estimate:',
      'labels: []',
    }),
    1,
    14
  ))
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Second' })
  child.cmd('write')
  child.lua('_G.wait_story(901)')
  eq(posts()[1].body.name, 'Second')
  eq(child.api.nvim_buf_is_valid(second), false)
  child.cmd('wincmd w')
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/new-1')
  eq(child.bo.modified, true)
  child.cmd('write')
  child.lua('_G.wait_story(902)')
  eq(#posts(), 2)
  eq(posts()[2].body.name, 'Fix the thing')
end

T[':w']['problems are diagnostics, and nothing is sent'] = function()
  open()
  child.api.nvim_buf_set_lines(0, 7, 8, false, { 'labels: [nope]' })
  child.api.nvim_buf_set_lines(
    0,
    12,
    13,
    false,
    { '## Tasks', '- [ ] Pair · @nobody', 'not a task' }
  )
  child.cmd('write')
  eq(writes(), {})
  eq(diagnostics(), {
    { lnum = 8, message = "labels: unknown label 'nope'" },
    { lnum = 10, message = 'the title cannot be empty' },
    { lnum = 14, message = "unknown member 'nobody'" },
    { lnum = 15, message = "not a task: task lines look like '- [ ] description'" },
  })
  eq(last_message(), {
    msg = "shortcut.nvim: could not create the story: line 8: labels: unknown label 'nope' (and 3 more); nothing was sent",
    level = ERROR,
  })
  eq(child.bo.modified, true)
  eq(child.bo.modifiable, true)
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/new-1')
end

T[':w']['an unknown epic is a diagnostic'] = function()
  open('epic=999')
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.cmd('write')
  eq(posts(), {})
  eq(diagnostics(), { { lnum = 5, message = 'epic: no epic 999' } })
end

T[':w']['a failed request keeps the draft'] = function()
  open()
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.lua([[_G.fail['POST /stories'] = { status = 400, body = '{"message":"nope"}' }]])
  child.cmd('write')
  eq(#posts(), 1)
  eq(last_message(), {
    msg = 'shortcut.nvim: could not create the story: POST /stories: HTTP 400: nope; nothing was created',
    level = ERROR,
  })
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/new-1')
  eq(child.bo.modified, true)
  eq(child.bo.modifiable, true)
  -- `:wq` doesn't quit either.
  child.cmd('split')
  child.cmd('wq')
  eq(#child.api.nvim_list_wins(), 2)
  eq(child.bo.modified, true)
  eq(#posts(), 2)
  -- Once it works, it is created once.
  child.lua([[_G.fail['POST /stories'] = nil]])
  child.cmd('write')
  child.lua('_G.wait_story(901)')
  eq(#posts(), 3)
end

T[':w'][':wq creates it once, and closes the window'] = function()
  open()
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.cmd('split')
  child.cmd('wq')
  child.lua('vim.wait(500, function() return _G.created[901] ~= nil end, 5); vim.wait(50)')
  eq(#posts(), 1)
  eq(#child.api.nvim_list_wins(), 1)
  eq(child.fn.bufexists('shortcut://story/new-1'), 0)
  eq(last_message().msg, 'shortcut.nvim: Created sc-901 (:Shortcut yank copies its link)')
end

T[':w']['writing elsewhere is refused and sends nothing'] = function()
  open()
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  local file = child.fn.tempname() .. '.md'
  for _, cmd in ipairs({
    'write ' .. file,
    'write! ' .. file,
    'saveas ' .. file,
    '1,3write ' .. file,
    'write >> ' .. file,
    'write shortcut://story/301',
    'wq ' .. file,
  }) do
    child.lua('_G.messages = {}')
    -- A message, not a Lua error (which would come with a stack trace).
    expect.no_error(child.cmd, cmd)
    child.lua('vim.wait(20)')
    eq(#child.lua_get('_G.messages'), 1)
    eq(last_message().level, ERROR)
    eq(vim.startswith(last_message().msg, 'shortcut.nvim: cannot write the draft to '), true)
    eq(child.api.nvim_buf_get_name(0), 'shortcut://story/new-1')
    eq(child.bo.modified, true)
  end
  eq(child.o.cpoptions:find('+', 1, true), nil)
  eq(writes(), {})
  eq(child.fn.filereadable(file), 0)
  eq(#child.api.nvim_list_wins(), 1)
end

T[':w']['typed :wq file is refused without a stack trace and keeps the window'] = function()
  open()
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.cmd('split')
  local file = child.fn.tempname() .. '.md'
  -- Typed, as a user would: an error in the write handler would not stop this `:wq`.
  child.type_keys(':wq ' .. file .. '<CR>')
  child.lua('vim.wait(20)')
  eq(#child.api.nvim_list_wins(), 2)
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/new-1')
  eq(child.bo.modified, true)
  eq(child.fn.filereadable(file), 0)
  eq(writes(), {})
  eq(#messages(), 1)
  eq(vim.startswith(last_message().msg, 'shortcut.nvim: cannot write the draft to '), true)
  eq(child.cmd_capture('messages'), '')
end

T[':w'][':wall from another window is refused'] = function()
  open()
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.cmd('split | enew')
  child.cmd('wall')
  eq(writes(), {})
  eq(last_message(), {
    msg = 'shortcut.nvim: shortcut://story/new-1 was not created: only :w in its window creates the story',
    level = WARN,
  })
  eq(child.fn.getbufvar('shortcut://story/new-1', '&modified'), 1)
end

T[':w']['a second write while it is being created sends nothing'] = function()
  open()
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.lua([[create.WRITE_WAIT = 50; _G.hold['POST /stories'] = true]])
  child.cmd('write')
  eq(last_message(), {
    msg = 'shortcut.nvim: the story is still being created; its buffer opens once it is',
    level = WARN,
  })
  eq(child.lua_get('create.is_creating()'), true)
  eq(child.bo.modifiable, false)
  eq(child.bo.modified, true)
  child.cmd('write')
  eq(last_message(), {
    msg = 'shortcut.nvim: the story is already being created: nothing more was sent',
    level = WARN,
  })
  eq(#posts(), 1)
  child.lua('_G.held[1]()')
  child.lua('_G.wait_story(901)')
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/901')
  eq(child.fn.bufexists('shortcut://story/new-1'), 0)
  eq(#posts(), 1)
end

T[':w']['an answer that may have created it requires :w! to send again'] = function()
  local cases = {
    {
      res = { error = 'request timed out', timed_out = true },
      why = 'POST /stories: request timed out',
    },
    { res = { status = 500, body = '{"message":"oops"}' }, why = 'POST /stories: HTTP 500: oops' },
    {
      res = { status = 201, body = 'not json' },
      why = 'POST /stories: HTTP 201: the response is not valid JSON',
    },
    { res = { status = 201, body = '{}' }, why = 'POST /stories answered without the new story' },
  }
  for i, case in ipairs(cases) do
    child.lua('_G.writes = {}')
    open(nil, i)
    child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
    child.lua([[_G.fail['POST /stories'] = ...]], { case.res })
    child.cmd('write')
    eq(#posts(), 1)
    eq(last_message(), {
      msg = 'shortcut.nvim: the story may have been created ('
        .. case.why
        .. '): check Shortcut before sending it again. The draft is kept; :w refuses to send it '
        .. 'again, :w! sends it anyway',
      level = ERROR,
    })
    eq(child.bo.modified, true)
    eq(child.bo.modifiable, true)
    -- :w and :wq send nothing more, and don't close it.
    child.lua([[_G.fail['POST /stories'] = nil]])
    child.cmd('write')
    eq(#posts(), 1)
    eq(last_message(), {
      msg = 'shortcut.nvim: not sent: an earlier attempt may have created the story already. '
        .. 'Check Shortcut; :w! sends it again (possibly creating it twice)',
      level = ERROR,
    })
    child.cmd('split')
    child.cmd('wq')
    eq(#child.api.nvim_list_wins(), 2)
    eq(#posts(), 1)
    child.cmd('only')
    -- :w! does.
    child.cmd('write!')
    child.lua('_G.wait_story(...)', { 900 + i })
    eq(#posts(), 2)
    eq(child.api.nvim_buf_get_name(0), 'shortcut://story/' .. (900 + i))
  end
end

T[':w']['every resend after an uncertain attempt needs its own :w!'] = function()
  open()
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.lua([[_G.fail['POST /stories'] = { status = 502, body = '' }]])
  child.cmd('write')
  eq(#posts(), 1)
  child.lua([[_G.fail['POST /stories'] = nil]])
  local function refused()
    child.cmd('write')
    eq(
      last_message().msg:find('not sent: an earlier attempt may have created', 1, true) ~= nil,
      true
    )
  end

  -- (a) :w! that fails validation sends nothing, and the flag stays.
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# ' })
  child.cmd('write!')
  eq(last_message().msg:find('the title cannot be empty', 1, true) ~= nil, true)
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  refused()
  eq(#posts(), 1)

  -- (b) :w! stopped before the POST: nothing sent, the flag stays.
  child.lua([[create.WRITE_WAIT = 50; _G.hold['GET /epics/678'] = true]])
  child.api.nvim_buf_set_lines(0, 4, 5, false, { 'epic: 678' })
  child.cmd('write!')
  eq(last_message().msg, 'shortcut.nvim: stopped before the story was sent: nothing was sent')
  child.lua(
    'for _, h in ipairs(_G.held) do h() end; _G.held = {}; _G.hold = {}; create.WRITE_WAIT = nil'
  )
  refused()
  eq(#posts(), 1)

  -- (c) :w! refused with a 4xx: says nothing about the first attempt, the flag stays.
  child.lua([[_G.fail['POST /stories'] = { status = 422, body = '{"message":"bad"}' }]])
  child.cmd('write!')
  eq(#posts(), 2)
  eq(last_message().msg:find('HTTP 422: bad; nothing was created', 1, true) ~= nil, true)
  child.lua([[_G.fail['POST /stories'] = nil]])
  refused()
  eq(#posts(), 2)

  -- Only a created story ends it.
  child.cmd('write!')
  child.lua('_G.wait_story(901)')
  eq(#posts(), 3)
end

T[':w']['a definite refusal needs no :w!'] = function()
  open()
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.lua([[_G.fail['POST /stories'] = { status = 422, body = '{"message":"bad"}' }]])
  child.cmd('write')
  eq(last_message().msg:find('HTTP 422: bad; nothing was created', 1, true) ~= nil, true)
  child.lua([[_G.fail['POST /stories'] = nil]])
  child.cmd('write')
  child.lua('_G.wait_story(901)')
  eq(#posts(), 2)
end

T[':w'][':e! while it is being created keeps what is sent'] = function()
  open()
  fill(filled())
  child.lua([[create.WRITE_WAIT = 50; _G.hold['POST /stories'] = true
    _G.fail['POST /stories'] = { status = 500, body = '{"message":"oops"}' }]])
  child.cmd('write')
  eq(#posts(), 1)
  child.cmd('edit!')
  eq(lines(), filled())
  eq(child.bo.modified, true)
  eq(child.bo.modifiable, false)
  eq(child.bo.filetype, 'markdown')
  child.lua('_G.held[1](); vim.wait(500, function() return not create.is_creating() end, 5)')
  eq(lines(), filled())
  eq(child.bo.modified, true)
  eq(child.bo.modifiable, true)
  eq(
    last_message().msg:find(
      'the story may have been created (POST /stories: HTTP 500: oops)',
      1,
      true
    ) ~= nil,
    true
  )
  -- Not lost: closing it still asks.
  eq(pcall(child.cmd, 'quit'), false)
end

T[':w']['stopping before the story is sent sends nothing'] = function()
  open('epic=678')
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.lua([[create.WRITE_WAIT = 50; _G.hold['GET /epics/678'] = true]])
  child.cmd('write')
  eq(last_message(), {
    msg = 'shortcut.nvim: stopped before the story was sent: nothing was sent',
    level = WARN,
  })
  eq(child.lua_get('create.is_creating()'), false)
  eq(child.bo.modifiable, true)
  eq(child.bo.modified, true)
  child.lua('for _, h in ipairs(_G.held) do h() end; vim.wait(100)')
  eq(posts(), {})
  -- And it can be written again.
  child.lua([[_G.hold = {}; create.WRITE_WAIT = nil]])
  child.cmd('write')
  child.lua('_G.wait_story(901)')
  eq(#posts(), 1)
end

T[':w']['closing follows the usual rules'] = function()
  open()
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.cmd('split')
  local ok, err = pcall(child.cmd, 'quit')
  eq(ok, true, err)
  eq(pcall(child.cmd, 'set nohidden | bdelete'), false)
  child.cmd('bdelete!')
  eq(child.fn.buflisted('shortcut://story/new-1'), 0)
  eq(writes(), {})
end

T[':w'][':e! goes back to the template'] = function()
  open('type=bug')
  child.api.nvim_buf_set_lines(0, 9, 10, false, { '# Title' })
  child.lua([[_G.ft = 0
    vim.api.nvim_create_autocmd('FileType', { callback = function() _G.ft = _G.ft + 1 end })]])
  child.cmd('edit!')
  -- The filetype is set again, so highlighting attaches to the new text.
  eq(child.lua_get('_G.ft'), 1)
  eq(child.bo.filetype, 'markdown')
  eq(child.bo.modeline, false)
  eq(lines()[2], 'type: bug')
  eq(lines()[10], '# ')
  eq(child.bo.modified, false)
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/new-1')
end

T[':w']['a draft name is only made by :Shortcut create'] = function()
  child.cmd('edit shortcut://story/new-7')
  eq(lines(), { '' })
  eq(last_message(), {
    msg = 'shortcut.nvim: shortcut://story/new-7 is not a draft; :Shortcut create starts one',
    level = ERROR,
  })
  eq(child.bo.buftype, 'nofile')
  child.cmd('Shortcut story shortcut://story/new-7')
  eq(last_message().msg:find('is a draft', 1, true) ~= nil, true)
end

return T

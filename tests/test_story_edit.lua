-- Saving story buffers, in a child Neovim against a fake Shortcut server (no network).
local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local TOKEN = 'test-token-0000-1111-2222-3333wxyz'
local JDOE = '00000000-0000-4000-8000-000000000101'
local ALEX = '00000000-0000-4000-8000-000000000102'

local T = new_set({
  hooks = {
    pre_case = function()
      local old = vim.env.TZ
      vim.env.TZ = 'UTC0'
      child.restart({ '-u', 'tests/minimal_init.lua' })
      vim.env.TZ = old
      child.lua(
        [[
        vim.env.SHORTCUT_API_TOKEN = ...
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        dofile('tests/fake_transport.lua')
        _G.story = require('shortcut.buffer.story')

        local function decode(s)
          return vim.json.decode(s, { luanil = { object = true, array = true } })
        end
        local label_ids = {}
        for _, l in ipairs(decode(_G.fixture('labels'))) do label_ids[l.name] = l.id end

        -- A stateful fake server for story 301.
        _G.server = decode(_G.fixture('story_render'))
        _G.writes = {}   -- non-GET requests: { method, path, body }
        _G.fail = {}     -- '<METHOD> <path>' -> response, instead of the normal one
        _G.confirms = {} -- messages passed to vim.fn.confirm
        _G.answer = 1
        vim.fn.confirm = function(msg, choices, default, kind)
          table.insert(_G.confirms, { msg = msg, choices = choices, default = default })
          return _G.answer
        end
        local version, next_task = 0, 400
        local function touch()
          version = version + 1
          _G.server.updated_at = ('2026-03-01T00:00:%02dZ'):format(version)
        end
        local function json(status, data)
          return { status = status, body = data ~= nil and vim.json.encode(data) or '' }
        end
        local lists = {
          ['/member'] = 'member',
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
          local failure = _G.fail[method .. ' ' .. path]
          if failure then return failure end
          if lists[path] then return { status = 200, fixture = lists[path] } end
          local epic = path:match('^/epics/(%d+)$')
          if epic then
            if epic == '999' then return json(404, { message = 'Resource not found.' }) end
            local e = decode(_G.fixture('epic'))
            e.id = tonumber(epic)
            e.name = 'Epic ' .. epic
            return json(200, e)
          end
          if path == '/stories/301' then
            if method == 'GET' then return json(200, _G.server) end
            -- `null` kept as vim.NIL: it clears the field.
            local body = vim.json.decode(req.body)
            for k, v in pairs(body) do
              if k == 'labels' then
                _G.server.label_ids = {}
                _G.server.labels = {}
                for _, l in ipairs(v) do
                  table.insert(_G.server.label_ids, label_ids[l.name])
                  table.insert(_G.server.labels, { id = label_ids[l.name], name = l.name })
                end
              elseif k == 'name' or k == 'description' or k == 'story_type' or k == 'owner_ids'
                or k == 'workflow_state_id' or k == 'epic_id' or k == 'iteration_id' or k == 'estimate' then
                _G.server[k] = v
              else
                error('unexpected field ' .. k)
              end
            end
            touch()
            return json(200, _G.server)
          end
          if path == '/stories/301/tasks' and method == 'POST' then
            local body = decode(req.body)
            next_task = next_task + 1
            local task = {
              id = next_task,
              description = body.description,
              complete = body.complete == true,
              owner_ids = body.owner_ids or {},
              position = 100 + next_task,
            }
            table.insert(_G.server.tasks, task)
            touch()
            return json(201, task)
          end
          local task_id = path:match('^/stories/301/tasks/(%d+)$')
          if task_id then
            task_id = tonumber(task_id)
            for i, t in ipairs(_G.server.tasks) do
              if t.id == task_id then
                if method == 'DELETE' then
                  table.remove(_G.server.tasks, i)
                  touch()
                  return { status = 204, body = '' }
                end
                for k, v in pairs(decode(req.body)) do t[k] = v end
                touch()
                return json(200, t)
              end
            end
            return json(404, { message = 'Resource not found.' })
          end
          return json(404, { message = 'Resource not found.' })
        end

        function _G.wait_loaded()
          vim.wait(2000, function()
            local first = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ''
            return not first:match('^Loading ')
          end, 5)
        end
        function _G.wait_saved()
          local save = require('shortcut.buffer.story_save')
          vim.wait(20)
          vim.wait(2000, function() return not save.is_saving(0) end, 5)
        end
      ]],
        { TOKEN }
      )
      child.cmd('edit shortcut://story/301')
      child.lua('vim.wait(20); _G.wait_loaded()')
    end,
    post_once = child.stop,
  },
})

local function lines()
  return child.api.nvim_buf_get_lines(0, 0, -1, false)
end

--- Change line `n` (1-based) in place, as editing it would: its task extmark stays.
--- (`nvim_buf_set_lines()` deletes the line and inserts a new one, which invalidates the mark.)
---@param n integer
---@param text string
local function set_line(n, text)
  child.fn.setline(n, text)
end

local function write(bang)
  child.cmd(bang and 'write!' or 'write')
  child.lua('_G.wait_saved()')
end

local function writes()
  return child.lua_get('_G.writes')
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
    return { lnum = d.lnum + 1, message = d.message, severity = d.severity }
  end, vim.diagnostic.get(0, { namespace = story.edit_ns() }))]])
end

local INFO, WARN, ERROR = vim.log.levels.INFO, vim.log.levels.WARN, vim.log.levels.ERROR

T['an untouched buffer sends nothing'] = function()
  write()
  eq(writes(), {})
  eq(messages(), { { msg = 'shortcut.nvim: sc-301: no changes', level = INFO } })
  eq(child.bo.modified, false)
end

T['edits are sent in one PUT, then the story is reloaded'] = function()
  set_line(12, '# New title')
  set_line(4, 'state: Done')
  set_line(8, 'estimate:')
  set_line(9, 'labels: [bug]')
  eq(child.bo.modified, true)
  write()
  eq(writes(), {
    {
      method = 'PUT',
      path = '/stories/301',
      body = {
        name = 'New title',
        workflow_state_id = 503,
        estimate = vim.NIL,
        labels = { { name = 'bug' } },
      },
    },
  })
  eq(lines()[12], '# New title')
  eq(lines()[4], 'state: Done')
  eq(lines()[8], 'estimate:')
  eq(lines()[9], 'labels: [bug]')
  eq(child.bo.modified, false)
  eq(child.bo.modifiable, true)
  eq(child.lua_get('story.snapshot().updated_at'), '2026-03-01T00:00:01Z')
  eq(last_message(), {
    msg = 'shortcut.nvim: sc-301 saved (title, state, estimate, labels)',
    level = INFO,
  })
  -- Saving again: nothing to send.
  write()
  eq(#writes(), 1)
end

T['owners, epic, iteration and type'] = function()
  set_line(3, 'type: chore')
  set_line(5, 'owners: [@jdoe]')
  set_line(6, 'epic: 202')
  set_line(7, 'iteration: Sprint 1')
  write()
  eq(writes(), {
    {
      method = 'PUT',
      path = '/stories/301',
      body = { story_type = 'chore', owner_ids = { JDOE }, epic_id = 202, iteration_id = 701 },
    },
  })
  eq(lines()[6], 'epic: 202 Epic 202')
  eq(lines()[5], 'owners: [jdoe]')
end

T['problems are diagnostics, and nothing is sent'] = function()
  set_line(2, 'id: 999')
  set_line(4, 'state: Shipped')
  set_line(5, 'owners: [jdoe, nobody]')
  set_line(9, 'labels: [brand-new]')
  set_line(23, 'not a task')
  write()
  eq(writes(), {})
  eq(diagnostics(), {
    {
      lnum = 2,
      message = 'id: read-only: it cannot be changed (undo the edit, or :e! to reload)',
      severity = 1,
    },
    {
      lnum = 4,
      message = "state: unknown state 'Shipped' in workflow 'Engineering'",
      severity = 1,
    },
    { lnum = 5, message = "owners: unknown member 'nobody'", severity = 1 },
    { lnum = 9, message = "labels: unknown label 'brand-new'", severity = 1 },
    { lnum = 23, message = "not a task: task lines look like '- [ ] description'", severity = 1 },
  })
  eq(messages(), {
    {
      msg = 'shortcut.nvim: failed to save sc-301: line 2: id: read-only: it cannot be changed (undo the edit, or :e! to reload) (and 4 more); nothing was sent',
      level = ERROR,
    },
  })
  eq(child.bo.modified, true)
  eq(child.bo.modifiable, true)

  -- Fixed: saved, and the diagnostics are gone.
  set_line(2, 'id: 301')
  set_line(4, 'state: done')
  set_line(5, 'owners: [jdoe]')
  set_line(9, 'labels: [Frontend]')
  set_line(23, '- [ ] Open task')
  write()
  eq(#writes(), 1)
  eq(diagnostics(), {})
  eq(child.bo.modified, false)
end

T['a new epic must exist'] = function()
  set_line(6, 'epic: 999 Nope')
  write()
  eq(writes(), {})
  eq(diagnostics(), { { lnum = 6, message = 'epic: no epic 999', severity = 1 } })
end

T['a missing section marker is an error'] = function()
  set_line(20, '')
  write()
  eq(writes(), {})
  local d = diagnostics()
  eq(#d, 1)
  eq(d[1].message:find(':e! reloads', 1, true) ~= nil, true)
end

T['conflicts'] = new_set()

T['conflicts']['a change on the server refuses the save; :w! overwrites'] = function()
  child.lua([[_G.server.updated_at = '2026-02-10T00:00:00Z'; _G.server.estimate = 1]])
  set_line(12, '# Mine')
  write()
  eq(writes(), {})
  eq(child.bo.modified, true)
  eq(messages(), {
    {
      msg = 'shortcut.nvim: failed to save sc-301: sc-301 was changed on Shortcut since it was loaded; nothing was sent. :Shortcut diff shows the differences, :w! overwrites them, :e! reloads (discarding your edits)',
      level = ERROR,
    },
  })
  write(true)
  eq(writes(), { { method = 'PUT', path = '/stories/301', body = { name = 'Mine' } } })
  eq(lines()[12], '# Mine')
  -- Only changed fields were sent: the server's estimate stays.
  eq(lines()[8], 'estimate: 1')
  eq(child.bo.modified, false)
end

T['conflicts'][':Shortcut diff shows the server version side by side'] = function()
  child.lua([[_G.server.updated_at = '2026-02-10T00:00:00Z'; _G.server.name = 'Theirs']])
  set_line(12, '# Mine')
  local story_win = child.api.nvim_get_current_win()
  child.cmd('Shortcut diff')
  child.lua([[vim.wait(1000, function() return #vim.api.nvim_tabpage_list_wins(0) == 2 end)]])
  eq(#child.api.nvim_tabpage_list_wins(0), 2)
  eq(child.api.nvim_buf_get_name(0), 'shortcut-server://story/301')
  eq(child.api.nvim_buf_get_lines(0, 11, 12, false), { '# Theirs' })
  eq(child.bo.buftype, 'nofile')
  eq(child.bo.modifiable, false)
  eq(child.wo.diff, true)
  eq(child.api.nvim_get_option_value('diff', { win = story_win }), true)
  eq(writes(), {})
  -- Again, from the story's window: the old one is replaced, and both windows stay in diff mode.
  child.api.nvim_set_current_win(story_win)
  child.cmd('Shortcut diff')
  child.lua([[vim.wait(1000, function()
    return vim.api.nvim_buf_get_name(0) == 'shortcut-server://story/301'
  end)]])
  child.lua('vim.wait(50)')
  eq(#child.api.nvim_tabpage_list_wins(0), 2)
  eq(child.wo.diff, true)
  eq(child.api.nvim_get_option_value('diff', { win = story_win }), true)
  eq(#child.lua_get([[vim.tbl_filter(function(b)
    return vim.api.nvim_buf_get_name(b) == 'shortcut-server://story/301'
  end, vim.api.nvim_list_bufs())]]), 1)
  -- Closing it leaves diff mode in the story's window.
  child.cmd('close')
  child.lua('vim.wait(20)')
  eq(child.api.nvim_get_option_value('diff', { win = story_win }), false)
  -- Not in a story buffer.
  child.cmd('enew')
  child.cmd('Shortcut diff')
  eq(last_message(), { msg = 'shortcut.nvim: diff: not a loaded story buffer', level = ERROR })
end

T['tasks'] = new_set()

T['tasks']['toggle, edit and owners'] = function()
  set_line(22, '- [ ] Done task · @jdoe')
  set_line(23, '- [x] Open task, edited · @Alex.Smith')
  set_line(24, '- [ ] Shared task')
  write()
  eq(writes(), {
    { method = 'PUT', path = '/stories/301/tasks/311', body = { complete = false } },
    {
      method = 'PUT',
      path = '/stories/301/tasks/312',
      body = { complete = true, description = 'Open task, edited', owner_ids = { ALEX } },
    },
    { method = 'PUT', path = '/stories/301/tasks/313', body = { owner_ids = {} } },
  })
  eq(vim.list_slice(lines(), 22, 24), {
    '- [ ] Done task · @jdoe',
    '- [x] Open task, edited · @Alex.Smith',
    '- [ ] Shared task',
  })
  eq(child.bo.modified, false)
end

T['tasks']['a description ending in · @word is never read as owners'] = function()
  child.lua([[_G.server.tasks[3].description = 'Email team · @jdoe']])
  child.cmd('edit!')
  child.lua('vim.wait(20); _G.wait_loaded()')
  eq(lines()[23], '- [ ] Email team \\· @jdoe')
  -- Edit "team" in place.
  child.api.nvim_buf_set_text(0, 22, 12, 22, 16, { 'crew' })
  write()
  eq(writes(), {
    {
      method = 'PUT',
      path = '/stories/301/tasks/312',
      body = { description = 'Email crew · @jdoe' },
    },
  })
  eq(lines()[23], '- [ ] Email crew \\· @jdoe')
  -- Appending a mention adds it to the description: jdoe never becomes an owner.
  child.lua('_G.writes = {}')
  set_line(23, lines()[23] .. ' @Alex.Smith')
  write()
  eq(writes(), {
    {
      method = 'PUT',
      path = '/stories/301/tasks/312',
      body = { description = 'Email crew · @jdoe @Alex.Smith' },
    },
  })
  eq(child.lua_get('_G.server.tasks[3].owner_ids'), {})
end

T['tasks']['an unknown owner is a diagnostic on its line'] = function()
  set_line(23, '- [ ] Open task · @nobody')
  write()
  eq(writes(), {})
  eq(diagnostics(), { { lnum = 23, message = "unknown member 'nobody'", severity = 1 } })
end

T['tasks']['new lines create tasks, with owners'] = function()
  child.api.nvim_buf_set_lines(0, 24, 24, false, { '- [ ] Brand new · @jdoe @Alex.Smith' })
  child.api.nvim_buf_set_lines(0, 21, 21, false, { '- [x] At the top' })
  write()
  eq(writes(), {
    {
      method = 'POST',
      path = '/stories/301/tasks',
      body = { description = 'At the top', complete = true },
    },
    {
      method = 'POST',
      path = '/stories/301/tasks',
      body = { description = 'Brand new', complete = false, owner_ids = { JDOE, ALEX } },
    },
  })
  -- New tasks are added at the end.
  eq(vim.list_slice(lines(), 22, 26), {
    '- [x] Done task · @jdoe',
    '- [ ] Open task',
    '- [ ] Shared task · @jdoe @Alex.Smith',
    '- [x] At the top',
    '- [ ] Brand new · @jdoe @Alex.Smith',
  })
  eq(#child.lua_get('story.task_marks(0)'), 5)
end

T['tasks']['deleting asks first: Delete'] = function()
  child.api.nvim_win_set_cursor(0, { 23, 0 })
  child.cmd('normal! dd')
  set_line(12, '# Retitled')
  write()
  eq(child.lua_get('_G.confirms'), {
    {
      msg = 'Delete 1 task(s) from sc-301?\n  - Open task',
      choices = '&Delete\n&Keep tasks\n&Cancel save',
      default = 3,
    },
  })
  eq(writes(), {
    { method = 'PUT', path = '/stories/301', body = { name = 'Retitled' } },
    { method = 'DELETE', path = '/stories/301/tasks/312' },
  })
  eq(
    vim.list_slice(lines(), 22, 23),
    { '- [x] Done task · @jdoe', '- [ ] Shared task · @jdoe @Alex.Smith' }
  )
  eq(child.bo.modified, false)
end

T['tasks']['deleting asks first: Keep tasks'] = function()
  child.lua('_G.answer = 2')
  child.api.nvim_win_set_cursor(0, { 22, 0 })
  child.cmd('normal! 2dd')
  set_line(12, '# Retitled')
  write()
  eq(
    child.lua_get('_G.confirms[1].msg'),
    'Delete 2 task(s) from sc-301?\n  - Done task\n  - Open task'
  )
  eq(writes(), { { method = 'PUT', path = '/stories/301', body = { name = 'Retitled' } } })
  -- The kept tasks are back.
  eq(lines()[22], '- [x] Done task · @jdoe')
  eq(lines()[23], '- [ ] Open task')
  eq(child.bo.modified, false)
  eq(last_message(), { msg = 'shortcut.nvim: sc-301 saved (title); kept 2 tasks', level = INFO })
end

T['tasks']['Keep tasks with nothing else to save sends nothing'] = function()
  child.lua('_G.answer = 2')
  child.api.nvim_win_set_cursor(0, { 23, 0 })
  child.cmd('normal! dd')
  write()
  eq(writes(), {})
  eq(lines()[23], '- [ ] Open task')
  eq(child.bo.modified, false)
  eq(
    last_message(),
    { msg = 'shortcut.nvim: sc-301: nothing else to save; kept 1 task', level = INFO }
  )
end

T['tasks']['deleting asks first: Cancel or <Esc>'] = function()
  for _, answer in ipairs({ 3, 0 }) do
    child.lua('_G.answer = ...', { answer })
    child.api.nvim_win_set_cursor(0, { 23, 0 })
    child.cmd('normal! dd')
    write()
    eq(writes(), {})
    eq(child.bo.modified, true)
    eq(child.bo.modifiable, true)
    eq(
      last_message(),
      { msg = 'shortcut.nvim: sc-301: save cancelled; nothing was sent', level = INFO }
    )
    child.cmd('undo')
  end
  -- :w! does not skip the question.
  child.api.nvim_win_set_cursor(0, { 23, 0 })
  child.cmd('normal! dd')
  write(true)
  eq(#child.lua_get('_G.confirms'), 3)
  eq(writes(), {})
end

T['tasks']['a change on the server while asking refuses the save'] = function()
  child.lua([[
    local confirm = vim.fn.confirm
    vim.fn.confirm = function(...)
      _G.server.updated_at = '2026-02-10T00:00:00Z'
      return confirm(...)
    end
  ]])
  child.api.nvim_win_set_cursor(0, { 23, 0 })
  child.cmd('normal! dd')
  write()
  eq(writes(), {})
  eq(child.bo.modified, true)
  eq(last_message().msg:find('was changed on Shortcut', 1, true) ~= nil, true)
end

T['tasks']['tasks.confirm_delete = false deletes without asking'] = function()
  child.lua([[require('shortcut').setup({ tasks = { confirm_delete = false } })]])
  child.api.nvim_win_set_cursor(0, { 23, 0 })
  child.cmd('normal! dd')
  write()
  eq(child.lua_get('_G.confirms'), {})
  eq(writes(), { { method = 'DELETE', path = '/stories/301/tasks/312' } })
end

T['tasks']['a line replaced or moved by deleting it keeps its task'] = function()
  -- As checkbox-toggling plugins do: the line is replaced, which invalidates its mark.
  child.api.nvim_buf_set_lines(0, 22, 23, false, { '- [x] Open task' })
  eq(#child.lua_get('story.task_marks(0)'), 2)
  write()
  eq(child.lua_get('_G.confirms'), {})
  eq(writes(), { { method = 'PUT', path = '/stories/301/tasks/312', body = { complete = true } } })
  eq(lines()[23], '- [x] Open task')
  eq(#child.lua_get('story.task_marks(0)'), 3)

  -- ddp: a move, which is not saved (no question, nothing sent).
  child.lua('_G.writes = {}')
  child.api.nvim_win_set_cursor(0, { 22, 0 })
  child.cmd('normal! ddp')
  eq(lines()[23], '- [x] Done task · @jdoe')
  write()
  eq(child.lua_get('_G.confirms'), {})
  eq(writes(), {})
  eq(last_message(), { msg = 'shortcut.nvim: sc-301: no changes', level = INFO })

  -- ...and edits on the moved line are updates of the same task.
  set_line(23, '- [ ] Done task · @jdoe')
  write()
  eq(child.lua_get('_G.confirms'), {})
  eq(writes(), { { method = 'PUT', path = '/stories/301/tasks/311', body = { complete = false } } })
  eq(child.lua_get('#_G.server.tasks'), 3)
end

T['tasks']['a replaced line with other text is a new task'] = function()
  child.lua([[require('shortcut').setup({ tasks = { confirm_delete = false } })]])
  child.api.nvim_buf_set_lines(0, 22, 23, false, { '- [ ] Something else' })
  write()
  eq(writes(), {
    {
      method = 'POST',
      path = '/stories/301/tasks',
      body = { description = 'Something else', complete = false },
    },
    { method = 'DELETE', path = '/stories/301/tasks/312' },
  })
end

T['tasks']['owners are left alone when hidden'] = function()
  child.lua([[require('shortcut').setup({ tasks = { show_owners = false } })]])
  child.cmd('edit!')
  child.lua('_G.wait_loaded()')
  eq(lines()[24], '- [ ] Shared task')
  set_line(24, '- [x] Shared task')
  write()
  eq(writes(), { { method = 'PUT', path = '/stories/301/tasks/313', body = { complete = true } } })
end

T['failures'] = new_set()

T['failures']['a failed story update sends nothing else'] = function()
  child.lua([[_G.fail['PUT /stories/301'] = { status = 400, body = '{"message": "Bad"}' }]])
  set_line(12, '# x')
  set_line(23, '- [x] Open task')
  write()
  eq(#writes(), 1)
  eq(child.bo.modified, true)
  eq(last_message(), {
    msg = 'shortcut.nvim: failed to save sc-301: PUT /stories/301: HTTP 400: Bad; nothing was saved',
    level = ERROR,
  })
end

T['failures']['failed task calls are reported; :w sends only those again'] = function()
  child.lua([[_G.fail['POST /stories/301/tasks'] = { status = 400, body = '{"message": "Nope"}' }]])
  child.api.nvim_buf_set_lines(0, 24, 24, false, { '- [ ] Will fail' })
  set_line(12, '# Saved title')
  set_line(22, '- [ ] Done task · @jdoe')
  write()
  eq(#writes(), 3)
  eq(child.bo.modified, true)
  eq(last_message(), {
    msg = 'shortcut.nvim: failed to save sc-301: some changes could not be saved.\n'
      .. 'Saved: title, 1 task updated.\n'
      .. 'Failed:\n'
      .. "- add task 'Will fail' (line 25): POST /stories/301/tasks: HTTP 400: Nope\n"
      .. 'Your edits are still in the buffer: :w sends only what failed again, :e! reloads '
      .. '(discarding them).',
    level = ERROR,
  })
  -- The edits are still there.
  eq(lines()[25], '- [ ] Will fail')

  child.lua([[_G.fail = {}; _G.writes = {}]])
  write()
  eq(writes(), {
    {
      method = 'POST',
      path = '/stories/301/tasks',
      body = { description = 'Will fail', complete = false },
    },
  })
  eq(child.bo.modified, false)
  eq(lines()[25], '- [ ] Will fail')
end

T['failures']['a task created before a failure is not created twice'] = function()
  child.lua([[_G.fail['PUT /stories/301/tasks/312'] = { status = 500, body = '{}' }]])
  child.api.nvim_buf_set_lines(0, 24, 24, false, { '- [ ] Created once' })
  set_line(23, '- [x] Open task')
  write()
  eq(#writes(), 2)
  eq(child.bo.modified, true)
  child.lua([[_G.fail = {}; _G.writes = {}]])
  write()
  eq(writes(), { { method = 'PUT', path = '/stories/301/tasks/312', body = { complete = true } } })
  eq(child.lua_get('#_G.server.tasks'), 4)
end

--- Make the first `PUT` of task 312 fail, running `meanwhile` (server-side code) first.
---@param meanwhile string
local function fail_task_update(meanwhile)
  child.lua(
    [[
    local routes, meanwhile = _G.routes, loadstring(...)
    _G.routes = function(req)
      local path = req.url:gsub('^https://api%.app%.shortcut%.com/api/v3', ''):gsub('%?.*', '')
      if req.method == 'PUT' and path == '/stories/301/tasks/312' and not _G.task_failed then
        _G.task_failed = true
        table.insert(_G.writes, { method = req.method, path = path, body = vim.json.decode(req.body) })
        meanwhile()
        return { status = 500, body = '{}' }
      end
      return routes(req)
    end
  ]],
    { meanwhile }
  )
end

T['failures']["someone else's change during a partly failed save is never reverted silently"] = function()
  fail_task_update([[
    _G.server.estimate = 8
    _G.server.updated_at = '2026-09-09T00:00:00Z'
  ]])
  set_line(12, '# Mine')
  set_line(23, '- [x] Open task')
  write()
  eq(#writes(), 2)
  eq(child.bo.modified, true)
  local msg = last_message().msg
  eq(msg:find('Saved: title.\nFailed:\n- update task', 1, true) ~= nil, true)
  eq(msg:find('also changed on Shortcut by someone else meanwhile', 1, true) ~= nil, true)
  -- The buffer still says 5; :w does not send it back, it reports a conflict.
  eq(lines()[8], 'estimate: 5')
  child.lua('_G.writes = {}')
  write()
  eq(writes(), {})
  eq(last_message().msg:find('was changed on Shortcut since it was loaded', 1, true) ~= nil, true)
  -- :w! sends what failed, but not the title again, and not the old estimate.
  write(true)
  eq(writes(), { { method = 'PUT', path = '/stories/301/tasks/312', body = { complete = true } } })
  eq(child.lua_get('_G.server.estimate'), 8)
  eq(lines()[8], 'estimate: 8')
  eq(child.bo.modified, false)
end

T['failures']['a change on the server to a field just saved is a conflict too'] = function()
  fail_task_update([[
    _G.server.name = 'Theirs'
    _G.server.updated_at = '2026-09-09T00:00:00Z'
  ]])
  set_line(12, '# Mine')
  set_line(23, '- [x] Open task')
  write()
  eq(last_message().msg:find('also changed on Shortcut by someone else', 1, true) ~= nil, true)
  child.lua('_G.writes = {}')
  write()
  eq(writes(), {})
  -- :w! overwrites theirs with the buffer's, as for any conflict.
  write(true)
  eq(writes(), {
    { method = 'PUT', path = '/stories/301', body = { name = 'Mine' } },
    { method = 'PUT', path = '/stories/301/tasks/312', body = { complete = true } },
  })
end

T['failures']["after a partial failure, :w! never sends back a task field it didn't edit"] = function()
  child.lua([[
    local routes = _G.routes
    _G.routes = function(req)
      local res = routes(req)
      if req.method == 'PUT' and req.url:match('/tasks/312$') then
        -- A teammate edits the task's description right after the toggle.
        _G.server.tasks[3].description = 'Theirs'
        _G.server.updated_at = '2026-09-09T00:00:00Z'
      end
      return res
    end
    _G.fail['POST /stories/301/tasks'] = { status = 500, body = '{}' }
  ]])
  set_line(23, '- [x] Open task')
  child.api.nvim_buf_set_lines(0, 24, 24, false, { '- [ ] New one' })
  write()
  eq(#writes(), 2)
  eq(last_message().msg:find('also changed on Shortcut by someone else', 1, true) ~= nil, true)
  child.lua([[_G.fail = {}; _G.writes = {}]])
  write()
  eq(writes(), {})
  write(true)
  eq(writes(), {
    {
      method = 'POST',
      path = '/stories/301/tasks',
      body = { description = 'New one', complete = false },
    },
  })
  eq(child.lua_get('_G.server.tasks[3].description'), 'Theirs')
end

--- Make the next `GET /stories/301` after a write fail, once.
local function fail_reload()
  child.lua([[
    local routes = _G.routes
    _G.routes = function(req)
      local path = req.url:gsub('^https://api%.app%.shortcut%.com/api/v3', ''):gsub('%?.*', '')
      if req.method ~= 'GET' then
        _G.wrote = true
      elseif path == '/stories/301' and _G.wrote and not _G.reload_failed then
        _G.reload_failed = true
        return { status = 500, body = '{"message": "Down"}' }
      end
      return routes(req)
    end
  ]])
end

T['failures']['a failed reload refuses further saves until :e!'] = function()
  fail_reload()
  child.api.nvim_buf_set_lines(0, 24, 24, false, { '- [ ] Brand new' })
  write()
  eq(writes(), {
    {
      method = 'POST',
      path = '/stories/301/tasks',
      body = { description = 'Brand new', complete = false },
    },
  })
  eq(last_message().level, WARN)
  eq(
    last_message().msg:find('sc-301 saved (1 task added), but reloading it failed', 1, true) ~= nil,
    true
  )
  -- The buffer does not show what was loaded.
  eq(child.bo.modified, true)
  eq(child.bo.modifiable, true)
  -- Neither :w nor :w! sends anything: the task would be created twice.
  child.lua('_G.writes = {}')
  for _, bang in ipairs({ false, true }) do
    write(bang)
    eq(writes(), {})
    eq(last_message(), {
      msg = 'shortcut.nvim: failed to save sc-301: sc-301 was saved, but could not be reloaded '
        .. 'afterwards, so the buffer is out of date; :e! reloads it (saving again now could send '
        .. 'the same changes twice)',
      level = ERROR,
    })
  end
  eq(child.lua_get('#_G.server.tasks'), 4)
  -- :e! makes it savable again.
  child.cmd('edit!')
  child.lua('vim.wait(20); _G.wait_loaded()')
  eq(lines()[25], '- [ ] Brand new')
  write()
  eq(writes(), {})
  eq(last_message(), { msg = 'shortcut.nvim: sc-301: no changes', level = INFO })
end

T['failures']['a failed reload after a partial failure refuses further saves too'] = function()
  fail_reload()
  child.lua([[_G.fail['PUT /stories/301/tasks/312'] = { status = 500, body = '{}' }]])
  child.api.nvim_buf_set_lines(0, 24, 24, false, { '- [ ] Brand new' })
  set_line(23, '- [x] Open task')
  write()
  eq(#writes(), 2)
  eq(child.bo.modified, true)
  eq(last_message().msg:find('Reloading the story failed too', 1, true) ~= nil, true)
  child.lua([[_G.fail = {}; _G.writes = {}]])
  write(true)
  eq(writes(), {})
  eq(last_message().msg:find('could not be reloaded afterwards', 1, true) ~= nil, true)
  eq(child.lua_get('#_G.server.tasks'), 4)
end

T['the buffer is read-only while saving, and saves do not overlap'] = function()
  child.lua([[
    local routes = _G.routes
    _G.routes = function(req)
      if req.method == 'PUT' and not _G.release then
        local res = routes(req)
        res.hold = true
        return res
      end
      return routes(req)
    end
  ]])
  set_line(12, '# Slow')
  child.cmd('write')
  child.lua([[vim.wait(1000, function() return #_G.held == 1 end)]])
  eq(child.bo.modifiable, false)
  child.cmd('write')
  eq(last_message(), {
    msg = 'shortcut.nvim: failed to save sc-301: a save is already in progress',
    level = ERROR,
  })
  child.lua('_G.release = true; _G.held[1](); _G.wait_saved()')
  eq(child.bo.modifiable, true)
  eq(child.bo.modified, false)
  eq(#writes(), 1)
end

T['the cursor stays on the same line after the reload'] = function()
  child.api.nvim_win_set_cursor(0, { 24, 4 })
  -- A new task above it; it is added at the end, so the cursor's task moves up.
  child.api.nvim_buf_set_lines(0, 21, 21, false, { '- [ ] New first' })
  eq(child.api.nvim_win_get_cursor(0), { 25, 4 })
  write()
  eq(lines()[24], '- [ ] Shared task · @jdoe @Alex.Smith')
  eq(child.api.nvim_win_get_cursor(0), { 24, 4 })
  -- In the description, relative to the title.
  child.api.nvim_buf_set_lines(0, 13, 14, false, { 'Intro', 'in two lines.' })
  child.api.nvim_win_set_cursor(0, { 15, 0 })
  write()
  eq(child.api.nvim_win_get_cursor(0), { 15, 0 })
  eq(lines()[15], 'in two lines.')
end

return T

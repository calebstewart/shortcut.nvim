local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local TOKEN = 'test-token-0000-1111-2222-3333wxyz'

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua(
        [[
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        vim.env.SHORTCUT_API_TOKEN = ...
        dofile(vim.fn.getcwd() .. '/tests/fake_transport.lua')

        -- Never open anything for real.
        _G.opened = {}
        vim.ui.open = function(url) table.insert(_G.opened, url); return {}, nil end

        -- The working directory is not a git repository unless a test makes it one.
        _G.dir = vim.fn.tempname()
        vim.fn.mkdir(_G.dir, 'p')
        vim.cmd.cd(vim.fn.fnameescape(_G.dir))

        _G.counts = {}
        -- `_G.overrides['<METHOD> <path>']` replaces a response.
        _G.overrides = {}
        local fixtures = {
          ['GET /member'] = 'member',
          ['GET /workflows'] = 'workflows',
          ['GET /epic-workflow'] = 'epic_workflow',
          ['GET /members'] = 'members',
          ['GET /labels'] = 'labels',
          ['GET /groups'] = 'groups',
          ['GET /iterations'] = 'iterations',
          ['GET /stories/301'] = 'story_render',
          ['GET /epics/201'] = 'epic',
          ['PUT /stories/301'] = 'story_render',
        }
        _G.routes = function(req)
          local path = req.url:gsub('^https://api%.app%.shortcut%.com/api/v3', ''):gsub('%?.*', '')
          local key = req.method .. ' ' .. path
          _G.counts[key] = (_G.counts[key] or 0) + 1
          if _G.overrides[key] then return _G.overrides[key] end
          if key == 'POST /stories/301/comments' then return { status = 201, fixture = 'comment' } end
          if fixtures[key] then return { status = 200, fixture = fixtures[key] } end
          return { status = 404, body = '{"message": "Resource not found."}' }
        end

        --- Requests other than GETs: { method, path, body }.
        function _G.writes()
          local out = {}
          for _, r in ipairs(_G.requests) do
            if r.method ~= 'GET' then
              local path = r.url:gsub('^https://api%.app%.shortcut%.com/api/v3', '')
              table.insert(out, { method = r.method, path = path, body = r.body and vim.json.decode(r.body) })
            end
          end
          return out
        end

        function _G.wait_loaded()
          vim.wait(2000, function()
            local first = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ''
            return not first:match('^Loading ')
          end, 5)
        end

        --- Wait until `n` messages have been shown.
        function _G.wait_messages(n)
          vim.wait(3000, function() return #_G.messages >= n end, 5)
        end

        --- Make the working directory a repository on `branch`.
        function _G.git_branch(branch)
          local function git(...)
            local res = vim.system({ 'git', ... }, { text = true }):wait()
            assert(res.code == 0, res.stderr)
          end
          git('init', '-q')
          git('-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q',
            '--allow-empty', '-m', 'x')
          git('checkout', '-q', '-b', branch)
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

local function wait_messages(n)
  child.lua('_G.wait_messages(...)', { n })
  return messages()
end

local function writes()
  return child.lua_get('_G.writes()')
end

local function count(key)
  return child.lua_get('_G.counts[...] or 0', { key })
end

local function open_story()
  child.cmd('edit shortcut://story/301')
  child.lua('vim.wait(20); _G.wait_loaded()')
end

local function needs_git()
  if child.fn.executable('git') == 0 then
    MiniTest.skip('git is not installed')
  end
end

---------------------------------------------------------------------------------------------------
-- comment
---------------------------------------------------------------------------------------------------

T['comment'] = new_set()

--- Open the comment float and wait for its title.
local function open_comment(arg)
  child.cmd('Shortcut comment' .. (arg and (' ' .. arg) or ''))
  child.lua([[vim.wait(2000, function()
    local c = vim.api.nvim_win_get_config(0)
    return c.title and c.title[1] and c.title[1][1]:find(':') ~= nil
  end, 5)]])
end

local function float_title()
  local title = child.lua_get('vim.api.nvim_win_get_config(0).title')
  return title and title[1] and title[1][1]
end

T['comment']['opens a floating Markdown buffer'] = function()
  open_comment('301')
  eq(child.lua_get('vim.api.nvim_win_get_config(0).relative'), 'editor')
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/301/comment')
  eq(child.bo.buftype, 'acwrite')
  eq(child.bo.filetype, 'markdown')
  eq(child.bo.modeline, false)
  eq(child.bo.modified, false)
  eq(float_title(), ' Comment on sc-301: Render me ')
  eq(child.api.nvim_get_mode().mode, 'i')
  eq(messages(), {})
end

T['comment'][':w posts the text and closes the float'] = function()
  open_comment('301')
  local buf = child.api.nvim_get_current_buf()
  child.cmd('stopinsert')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { '', 'Hello **world**.', '', '- a list', '', '' })
  child.cmd('write')
  wait_messages(1)
  eq(writes(), {
    {
      method = 'POST',
      path = '/stories/301/comments',
      body = { text = 'Hello **world**.\n\n- a list' },
    },
  })
  eq(messages(), { { msg = 'shortcut.nvim: comment posted on sc-301', level = 2 } })
  eq(child.lua_get('vim.api.nvim_buf_is_valid(...)', { buf }), false)
  eq(child.lua_get('vim.api.nvim_win_get_config(0).relative'), '')
end

T['comment'][':w never goes through the story loader or saver'] = function()
  child.lua([[
    _G.story_calls = {}
    require('shortcut.buffer.handlers').register('story', {
      load = function(buf, id, opts, done)
        table.insert(_G.story_calls, 'load ' .. id)
        done(nil, { '# story' })
      end,
      save = function(buf, id, opts, done)
        table.insert(_G.story_calls, 'save ' .. id)
        done()
      end,
    })
  ]])
  open_comment('301')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'text' })
  child.cmd('write')
  wait_messages(1)
  eq(child.lua_get('_G.story_calls'), {})
  eq(#writes(), 1)
  eq(messages(), { { msg = 'shortcut.nvim: comment posted on sc-301', level = 2 } })
end

T['comment']['writing it anywhere else posts nothing and writes no file'] = function()
  open_comment('301')
  child.cmd('stopinsert')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft', 'two' })
  local file = child.lua_get('_G.dir') .. '/x.md'
  for _, cmd in ipairs({
    'write ' .. file,
    'write! ' .. file,
    'saveas ' .. file,
    'write shortcut://story/5',
    'write >> ' .. file,
    '1write ' .. file,
    '1,1write!',
    'write !cat > /dev/null',
    -- The write fails, so the quit doesn't go ahead and lose the draft.
    'wq ' .. file,
    'xit ' .. file,
    '1,1wq ' .. file,
  }) do
    child.lua('_G.messages = {}')
    -- A message, not a Lua error (which would come with a stack trace).
    expect.no_error(child.cmd, cmd)
    child.lua('vim.wait(50)')
    eq({ cmd = cmd, writes = writes() }, { cmd = cmd, writes = {} })
    eq(child.lua_get('vim.uv.fs_stat(...) == nil', { file }), true)
    eq(child.api.nvim_buf_get_name(0), 'shortcut://story/301/comment')
    eq(child.lua_get('vim.api.nvim_win_get_config(0).relative'), 'editor')
    eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'draft', 'two' })
    eq(child.bo.modified, true)
    if vim.startswith(cmd, 'write !') then
      eq(messages(), {})
    else
      local msgs = messages()
      eq(
        { cmd = cmd, n = #msgs, level = msgs[1] and msgs[1].level },
        { cmd = cmd, n = 1, level = 4 }
      )
      eq(vim.startswith(msgs[1].msg, 'shortcut.nvim: cannot write the comment to '), true)
    end
    -- 'cpoptions' is as it was.
    eq(child.o.cpoptions, child.lua_get('vim.go.cpoptions'))
    eq(child.o.cpoptions:find('+', 1, true), nil)
  end
  -- And `:w` still posts.
  child.cmd('write')
  wait_messages(1)
  eq(#writes(), 1)
end

T['comment']['typed :wq file shows the refusal without a stack trace and keeps the float'] = function()
  -- With Neovim's own vim.notify.
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua(
    [[
    vim.env.SHORTCUT_API_TOKEN = ...
    dofile(vim.fn.getcwd() .. '/tests/fake_transport.lua')
    _G.routes = function() return { status = 404, body = '{}' } end
    require('shortcut.buffer.comment').open(301, { lines = { 'draft' } })
  ]],
    { TOKEN }
  )
  child.cmd('stopinsert')
  local file = child.fn.tempname()
  -- Typed, as a user would: an error in the write handler would not stop this `:wq`.
  -- `type_keys()` raises when typing showed an error message: only the refusal, not a Lua error.
  local ok, err = pcall(child.type_keys, ':wq ' .. file .. '<CR>')
  if not ok then
    eq(vim.startswith(tostring(err), 'shortcut.nvim: cannot write the comment to '), true)
    eq(tostring(err):find('traceback', 1, true), nil)
  end
  -- Not `child.lua('vim.wait()')`: the message must be shown from the main loop, as it is to a
  -- user, not inside an API call (where an error message is raised as an error).
  local shown = ''
  for _ = 1, 200 do
    shown = child.cmd_capture('messages')
    if shown ~= '' then
      break
    end
    vim.uv.sleep(5)
  end
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/301/comment')
  eq(child.lua_get('vim.api.nvim_win_get_config(0).relative'), 'editor')
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'draft' })
  eq(child.fn.filereadable(file), 0)
  eq(shown:find('cannot write the comment to', 1, true) ~= nil, true)
  eq(shown:find('traceback', 1, true), nil)
  eq(shown:find('Autocommands', 1, true), nil)
end

T['comment'][':w!, :x and :update each post once'] = function()
  for _, cmd in ipairs({ 'write!', 'xit', 'update' }) do
    child.lua('_G.requests = {}; _G.messages = {}')
    open_comment('301')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { cmd })
    child.cmd(cmd)
    wait_messages(1)
    child.lua('vim.wait(50)')
    eq(writes(), { { method = 'POST', path = '/stories/301/comments', body = { text = cmd } } })
    eq(child.lua_get('vim.api.nvim_win_get_config(0).relative'), '')
  end
end

T['comment'][':wall, :wqa and :xa from another window post nothing'] = function()
  open_comment('301')
  child.cmd('stopinsert')
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'half a' })
  child.cmd('wincmd p')
  for _, cmd in ipairs({ 'wall', 'wqa', 'xa' }) do
    child.lua('_G.messages = {}')
    pcall(child.cmd, cmd)
    child.lua('vim.wait(50)')
    -- Still running: the draft is still modified, so Neovim did not exit.
    eq({ cmd = cmd, writes = writes() }, { cmd = cmd, writes = {} })
    eq(child.api.nvim_buf_get_option(buf, 'modified'), true)
    eq(child.api.nvim_buf_get_lines(buf, 0, -1, false), { 'half a' })
    eq(messages(), {
      {
        msg = 'shortcut.nvim: the comment on sc-301 was not posted: only :w in its window posts it',
        level = 3,
      },
    })
  end
  -- In the float itself, `:wall` is `:w`.
  child.lua('_G.messages = {}')
  child.cmd('Shortcut comment 301')
  eq(child.api.nvim_get_current_buf(), buf)
  child.cmd('wall')
  wait_messages(1)
  eq(writes(), { { method = 'POST', path = '/stories/301/comments', body = { text = 'half a' } } })
  eq(child.api.nvim_buf_is_valid(buf), false)
end

T['comment'][':wqa in the float that fails does not exit and keeps the text'] = function()
  child.lua([[_G.overrides['POST /stories/301/comments'] = { status = 500 }]])
  open_comment('301')
  child.cmd('stopinsert')
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep me' })
  pcall(child.cmd, 'wqa')
  -- Waited for the answer within the command.
  eq(#writes(), 1)
  eq(child.api.nvim_get_current_buf(), buf)
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'keep me' })
  eq(child.bo.modified, true)
  eq(child.bo.modifiable, true)
  expect.no_error(function()
    assert(messages()[1].msg:find('failed to post the comment on sc-301', 1, true))
  end)
end

T['comment'][':wqa in the float that takes too long does not exit'] = function()
  child.lua([[
    require('shortcut.buffer.comment').QUIT_WAIT = 50
    _G.overrides['POST /stories/301/comments'] = { status = 201, fixture = 'comment', hold = true }
  ]])
  open_comment('301')
  child.cmd('stopinsert')
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'slow' })
  pcall(child.cmd, 'wqa')
  eq(#writes(), 1)
  eq(child.api.nvim_get_current_buf(), buf)
  eq(child.bo.modified, true)
  eq(messages(), {
    { msg = 'shortcut.nvim: the comment on sc-301 is still being posted: not exiting', level = 3 },
  })
  -- Once posted, the float closes; nothing is sent again.
  child.lua('_G.held[1]()')
  wait_messages(2)
  eq(messages()[2], { msg = 'shortcut.nvim: comment posted on sc-301', level = 2 })
  eq(child.api.nvim_buf_is_valid(buf), false)
  eq(#writes(), 1)
end

T['comment'][':wqa in the float posts before Neovim exits'] = function()
  local out = vim.fn.tempname()
  open_comment('301')
  child.cmd('stopinsert')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'bye' })
  child.lua(
    [[
    local out = ...
    vim.api.nvim_create_autocmd('VimLeavePre', { callback = function()
      vim.fn.writefile({ vim.json.encode({ writes = _G.writes(), messages = _G.messages }) }, out)
    end })
  ]],
    { out }
  )
  pcall(child.cmd, 'wqa')
  vim.wait(2000, function()
    return vim.fn.filereadable(out) == 1
  end, 10)
  local res = vim.json.decode(vim.fn.readfile(out)[1])
  vim.fn.delete(out)
  eq(res.writes, { { method = 'POST', path = '/stories/301/comments', body = { text = 'bye' } } })
  -- The answer arrived before exiting; the closing itself was left for later.
  eq(res.messages, {})
end

T['comment']['exiting waits for the post, and saves the draft if it fails'] = function()
  -- Success: nothing saved.
  open_comment('301')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'fine' })
  child.cmd('write')
  child.lua([[require('shortcut.buffer.comment').on_exit()]])
  eq(#writes(), 1)
  eq(child.lua_get([[vim.fn.glob(require('shortcut.buffer.comment').unsent_dir() .. '/*')]]), '')

  -- Failure while exiting: no float reopened, the draft is saved.
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua(
    [[
    vim.env.SHORTCUT_API_TOKEN = ...
    dofile(vim.fn.getcwd() .. '/tests/fake_transport.lua')
    _G.responses = { { status = 500 } }
    _G.stderr = {}
    io.stderr = { write = function(_, s) table.insert(_G.stderr, s) end }
    local comment = require('shortcut.buffer.comment')
    comment.open(301, { title = 'x' })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'not lost' })
    vim.cmd('wq')
    comment.on_exit()
  ]],
    { TOKEN }
  )
  local files = child.lua_get(
    [[vim.fn.glob(require('shortcut.buffer.comment').unsent_dir() .. '/comment-sc-301-*.md', false, true)]]
  )
  eq(#files, 1)
  eq(child.fn.readfile(files[1]), { 'not lost' })
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 1)
  expect.no_error(function()
    assert(
      child
        .lua_get('_G.stderr[1]')
        :find('the comment on sc-301 was not posted; it was saved to', 1, true)
    )
  end)
end

T['comment']['an unanswered post at exit may have been posted; drafts never overwrite'] = function()
  child.lua([[
    _G.stderr = {}
    io.stderr = { write = function(_, s) table.insert(_G.stderr, s) end }
    local comment = require('shortcut.buffer.comment')
    comment.EXIT_WAIT = 50
    _G.overrides['POST /stories/301/comments'] = { status = 201, fixture = 'comment', hold = true }
  ]])
  -- Two posts of the same story in flight (within the same second).
  for _, text in ipairs({ 'one', 'two' }) do
    child.lua(
      [[
      require('shortcut.buffer.comment').open(301, { title = 'x' })
      vim.cmd('stopinsert')
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { ... })
      vim.cmd('write')
    ]],
      { text }
    )
    child.cmd('quit')
  end
  child.lua([[require('shortcut.buffer.comment').on_exit()]])
  eq(#writes(), 2)
  local files = child.lua_get(
    [[vim.fn.glob(require('shortcut.buffer.comment').unsent_dir() .. '/comment-sc-301-*.md', false, true)]]
  )
  eq(#files, 2)
  local texts = { child.fn.readfile(files[1])[1], child.fn.readfile(files[2])[1] }
  table.sort(texts)
  eq(texts, { 'one', 'two' })
  local stderr = child.lua_get('_G.stderr')
  eq(#stderr, 2)
  for _, line in ipairs(stderr) do
    expect.no_error(function()
      assert(
        line:find(
          'the comment on sc-301 was not confirmed as posted (it may still have been); it was saved to',
          1,
          true
        ),
        line
      )
    end)
  end
end

T['comment']['focus left with :noautocmd: a :wall typed elsewhere posts nothing'] = function()
  open_comment('301')
  child.cmd('stopinsert')
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'half a' })
  child.type_keys(':noautocmd wincmd p<CR>')
  eq(child.api.nvim_get_current_buf() ~= buf, true)
  child.lua('_G.messages = {}')
  child.type_keys(':wall<CR>')
  child.lua('vim.wait(50)')
  eq(writes(), {})
  eq(child.api.nvim_buf_get_option(buf, 'modified'), true)
  eq(messages(), {
    {
      msg = 'shortcut.nvim: the comment on sc-301 was not posted: only :w in its window posts it',
      level = 3,
    },
  })
  -- Typed in the float, it posts.
  child.cmd('Shortcut comment 301')
  child.type_keys(':wall<CR>')
  wait_messages(2)
  eq(writes(), { { method = 'POST', path = '/stories/301/comments', body = { text = 'half a' } } })
end

T['comment']['an empty comment is rejected'] = function()
  open_comment('301')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { '', '   ', '' })
  child.cmd('write')
  child.lua('vim.wait(50)')
  eq(writes(), {})
  eq(messages(), {
    { msg = 'shortcut.nvim: the comment is empty: nothing was posted to sc-301', level = 4 },
  })
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/301/comment')
end

T['comment'][':q! discards'] = function()
  open_comment('301')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'never mind' })
  expect.error(function()
    child.cmd('quit')
  end, 'E37')
  child.cmd('quit!')
  eq(
    child.lua_get(
      '#vim.tbl_filter(function(b) return vim.api.nvim_buf_get_name(b):find("comment") end, vim.api.nvim_list_bufs())'
    ),
    0
  )
  eq(writes(), {})
end

T['comment']['a failed post keeps the text'] = function()
  child.lua(
    [[_G.overrides['POST /stories/301/comments'] = { status = 422, body = '{"message": "nope"}' }]]
  )
  open_comment('301')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep me' })
  child.cmd('write')
  wait_messages(1)
  eq(messages(), {
    {
      msg = 'shortcut.nvim: failed to post the comment on sc-301: POST /stories/301/comments: HTTP 422: nope',
      level = 4,
    },
  })
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'keep me' })
  eq(child.bo.modified, true)
  eq(child.bo.modifiable, true)
end

T['comment'][':wq that fails reopens the float with the text'] = function()
  child.lua([[_G.overrides['POST /stories/301/comments'] = { status = 500 }]])
  open_comment('301')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep me too' })
  child.cmd('wq')
  wait_messages(1)
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/301/comment')
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'keep me too' })
  eq(child.bo.modified, true)
  eq(float_title(), ' Comment on sc-301: Render me ')
  expect.no_error(function()
    assert(messages()[1].msg:find('the comment has been reopened', 1, true))
  end)
end

T['comment']['reloads the story buffer, or says it is modified'] = function()
  open_story()
  eq(count('GET /stories/301'), 1)
  -- From the story buffer: no argument needed, and the title comes from the buffer.
  open_comment()
  eq(float_title(), ' Comment on sc-301: Render me ')
  eq(count('GET /stories/301'), 1)
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'first' })
  child.cmd('write')
  wait_messages(1)
  child.lua('_G.wait_loaded()')
  eq(count('GET /stories/301'), 2)
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/301')

  child.api.nvim_buf_set_lines(0, 11, 12, false, { '# local edit' })
  open_comment()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'second' })
  child.cmd('write')
  wait_messages(2)
  eq(count('GET /stories/301'), 2)
  eq(messages()[2], {
    msg = 'shortcut.nvim: comment posted on sc-301; its buffer has unsaved changes, so it was not reloaded',
    level = 3,
  })
  eq(child.api.nvim_buf_get_lines(0, 11, 12, false), { '# local edit' })
end

T['comment']['the title is flattened'] = function()
  child.lua([[
    local s = vim.json.decode(_G.fixture('story_render'))
    s.name = 'Evil\nname\27[31m\226\128\174 ' .. string.rep('x', 200)
    _G.overrides['GET /stories/301'] = { status = 200, body = vim.json.encode(s) }
  ]])
  open_comment('301')
  local title = float_title()
  eq(title:find('[%c]'), nil)
  eq(title:find('\226\128\174', 1, true), nil)
  eq(vim.startswith(title, ' Comment on sc-301: Evil name [31m '), true)
  eq(vim.endswith(title, '… '), true)
end

T['comment']['an unknown story still opens, with a warning'] = function()
  open_comment('999')
  wait_messages(1)
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/999/comment')
  eq(messages(), {
    {
      msg = 'shortcut.nvim: comment: could not fetch sc-999: sc-999 not found (is it an epic?)',
      level = 3,
    },
  })
end

T['comment']['a second :Shortcut comment focuses the open float'] = function()
  open_comment('301')
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft' })
  child.cmd('wincmd p')
  child.cmd('Shortcut comment 301')
  child.lua('vim.wait(50)')
  eq(child.api.nvim_get_current_buf(), buf)
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'draft' })
end

T['comment']['editing the comment name directly is refused'] = function()
  child.cmd('edit shortcut://story/301/comment')
  child.lua('vim.wait(20)')
  expect.no_error(function()
    assert(messages()[1].msg:find('use :Shortcut comment 301', 1, true))
  end)
  eq(count('GET /stories/301'), 0)
  -- The comment command still works afterwards.
  open_comment('301')
  eq(child.bo.buftype, 'acwrite')
end

T['comment']['works from the git branch'] = function()
  needs_git()
  child.lua([[_G.git_branch('someone/sc-301/render-me')]])
  open_comment()
  eq(child.api.nvim_buf_get_name(0), 'shortcut://story/301/comment')
end

---------------------------------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------------------------------

T['state'] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        _G.selects = {}
        _G.choose = nil -- index to choose, or nil to cancel
        vim.ui.select = function(items, opts, on_choice)
          table.insert(_G.selects, {
            prompt = opts.prompt,
            items = vim.tbl_map(opts.format_item, items),
          })
          vim.schedule(function() on_choice(_G.choose and items[_G.choose], _G.choose) end)
        end
      ]])
    end,
  },
})

local function state(args)
  child.cmd('Shortcut state' .. (args and (' ' .. args) or ''))
end

T['state']['offers the states of the story workflow, in order'] = function()
  -- Positions out of list order: the select follows `position`.
  child.lua([[
    local w = vim.json.decode(_G.fixture('workflows'))
    w[1].states[1].position, w[1].states[3].position = 7, -1
    _G.overrides['GET /workflows'] = { status = 200, body = vim.json.encode(w) }
    _G.choose = 3
  ]])
  state('301')
  wait_messages(1)
  eq(child.lua_get('_G.selects'), {
    {
      prompt = 'State of sc-301: Render me',
      items = { 'Done', 'In Progress (current)', 'Backlog' },
    },
  })
  eq(writes(), { { method = 'PUT', path = '/stories/301', body = { workflow_state_id = 501 } } })
  eq(messages(), { { msg = 'shortcut.nvim: sc-301 moved to Backlog', level = 2 } })
end

T['state']['uses the workflow the story is in'] = function()
  child.lua([[
    local s = vim.json.decode(_G.fixture('story_render'))
    s.workflow_id, s.workflow_state_id = 510, 511
    _G.overrides['GET /stories/301'] = { status = 200, body = vim.json.encode(s) }
    _G.choose = 2
  ]])
  state('301')
  wait_messages(1)
  eq(child.lua_get('_G.selects[1].items'), { 'To Do (current)', 'In Progress', 'Shipped' })
  eq(writes(), { { method = 'PUT', path = '/stories/301', body = { workflow_state_id = 512 } } })
end

T['state']['cancelling changes nothing'] = function()
  state('301')
  child.lua('vim.wait(100)')
  eq(#child.lua_get('_G.selects'), 1)
  eq(writes(), {})
  eq(messages(), {})
end

T['state']['a name applies directly'] = function()
  state('sc-301 done')
  wait_messages(1)
  eq(child.lua_get('_G.selects'), {})
  eq(writes(), { { method = 'PUT', path = '/stories/301', body = { workflow_state_id = 503 } } })
  eq(messages(), { { msg = 'shortcut.nvim: sc-301 moved to Done', level = 2 } })
end

T['state']['a name with spaces, from the story buffer'] = function()
  child.lua([[
    local s = vim.json.decode(_G.fixture('story_render'))
    s.workflow_state_id = 501
    _G.overrides['GET /stories/301'] = { status = 200, body = vim.json.encode(s) }
  ]])
  open_story()
  state('In Progress')
  wait_messages(1)
  eq(writes(), { { method = 'PUT', path = '/stories/301', body = { workflow_state_id = 502 } } })
end

T['state']['the current state is not sent again'] = function()
  state([[sc-301 In\ Progress]])
  wait_messages(1)
  eq(writes(), {})
  eq(messages(), { { msg = 'shortcut.nvim: sc-301 is already in In Progress', level = 2 } })
end

T['state']['an unknown name is an error'] = function()
  state('sc-301 Shipped')
  wait_messages(1)
  eq(writes(), {})
  eq(messages(), {
    {
      msg = "shortcut.nvim: state: unknown state 'Shipped' in workflow 'Engineering'",
      level = 4,
    },
  })
end

T['state']['a bare ID followed by words is part of the state name'] = function()
  -- Story 2 exists and has a 'Review' state: it must not be touched.
  child.lua([[
    local s = vim.json.decode(_G.fixture('story_render'))
    s.id = 2
    _G.overrides['GET /stories/2'] = { status = 200, body = vim.json.encode(s) }
    _G.overrides['PUT /stories/2'] = { status = 200, body = vim.json.encode(s) }
    local w = vim.json.decode(_G.fixture('workflows'))
    w[1].states[1].name = 'Review'
    _G.overrides['GET /workflows'] = { status = 200, body = vim.json.encode(w) }
  ]])
  open_story()
  state('2 Review')
  wait_messages(1)
  eq(writes(), {})
  eq(count('GET /stories/2'), 0)
  eq(messages(), {
    {
      msg = "shortcut.nvim: state: unknown state '2 Review' in workflow 'Engineering' (did you mean 'Review'?); to name story 2, write sc-2",
      level = 4,
    },
  })
  -- A bare ID alone is still the target.
  child.lua('_G.choose = nil')
  state('2')
  child.lua([[vim.wait(2000, function() return #_G.selects > 0 end, 5)]])
  eq(child.lua_get('_G.selects[1].prompt'), 'State of sc-2: Render me')
end

T['state']['state_args()'] = function()
  local function split(args)
    return child.lua_get(
      '(function(a) local t, n = require("shortcut.actions").state_args(a); return { arg = t, name = n } end)(...)',
      { args }
    )
  end
  eq(split({}), {})
  eq(split({ '301' }), { arg = '301' })
  eq(split({ 'sc-301', 'In', 'Progress' }), { arg = 'sc-301', name = 'In Progress' })
  eq(split({ '301', 'Done' }), { name = '301 Done' })
  eq(split({ 'https://app.shortcut.com/acme/story/301', 'Done' }), {
    arg = 'https://app.shortcut.com/acme/story/301',
    name = 'Done',
  })
  eq(split({ 'In', 'Progress' }), { name = 'In Progress' })
end

T['state']['a failed update is reported'] = function()
  child.lua([[_G.overrides['PUT /stories/301'] = { status = 422, body = '{"message": "no"}' }]])
  state('https://app.shortcut.com/acme/story/301 Done')
  wait_messages(1)
  eq(messages(), {
    {
      msg = 'shortcut.nvim: state: cannot move sc-301 to Done: PUT /stories/301: HTTP 422: no',
      level = 4,
    },
  })
end

T['state']['reloads the story buffer, or warns that it is stale'] = function()
  open_story()
  state('Done')
  wait_messages(1)
  child.lua('_G.wait_loaded()')
  eq(count('GET /stories/301'), 3) -- load, state, reload
  eq(child.bo.modified, false)

  child.api.nvim_buf_set_lines(0, 11, 12, false, { '# local edit' })
  state('Backlog')
  wait_messages(2)
  eq(count('GET /stories/301'), 4)
  eq(messages()[2], {
    msg = 'shortcut.nvim: sc-301 moved to Backlog; its buffer has unsaved changes, so its header is now stale',
    level = 3,
  })
  eq(child.api.nvim_buf_get_lines(0, 11, 12, false), { '# local edit' })
end

T['state']['completes state names'] = function()
  local function complete(cmdline)
    return child.lua_get('vim.fn.getcompletion(...)', { cmdline, 'cmdline' })
  end
  -- Not loaded yet: starts loading, offers nothing.
  eq(complete('Shortcut state '), {})
  child.lua(
    [[vim.wait(2000, function() return require('shortcut.cache').workflows() ~= nil end, 5)]]
  )
  -- Every workflow's states.
  eq(complete('Shortcut state '), { 'Backlog', 'In\\ Progress', 'Done', 'To\\ Do', 'Shipped' })
  eq(complete('Shortcut state sc-301 s'), { 'Shipped' })
  -- The rest of a name with spaces, typed as is or escaped.
  eq(complete('Shortcut state in p'), { 'Progress' })
  eq(complete('Shortcut state sc-301 In\\ P'), { 'In\\ Progress' })
  -- In a story buffer: its workflow's only.
  open_story()
  eq(complete('Shortcut state '), { 'Backlog', 'In\\ Progress', 'Done' })
end

---------------------------------------------------------------------------------------------------
-- browse / yank
---------------------------------------------------------------------------------------------------

T['browse'] = new_set()

local function opened()
  child.lua([[vim.wait(2000, function() return #_G.opened > 0 or #_G.messages > 0 end, 5)]])
  return child.lua_get('_G.opened')
end

T['browse']['builds the URL from the workspace'] = function()
  child.cmd('Shortcut browse 301')
  eq(opened(), { 'https://app.shortcut.com/acme/story/301' })
  eq(writes(), {})
end

T['browse']["uses a story buffer's app_url"] = function()
  open_story()
  child.cmd('Shortcut browse')
  eq(opened(), { 'https://app.shortcut.com/example-workspace/story/301' })
end

T['browse']['ignores an app_url that is not the story'] = function()
  child.lua([[
    local s = vim.json.decode(_G.fixture('story_render'))
    s.app_url = 'https://evil.example.com/acme/story/301'
    _G.overrides['GET /stories/301'] = { status = 200, body = vim.json.encode(s) }
  ]])
  open_story()
  child.cmd('Shortcut browse')
  eq(opened(), { 'https://app.shortcut.com/acme/story/301' })
end

T['browse']["uses a link's workspace, and works for epics"] = function()
  child.cmd('Shortcut browse https://app.shortcut.com/other/epic/6/slug')
  eq(opened(), { 'https://app.shortcut.com/other/epic/6' })
end

T['browse']['looks up the kind of an sc-<id>'] = function()
  child.cmd('Shortcut browse sc-201')
  eq(opened(), { 'https://app.shortcut.com/acme/epic/201' })
end

T['browse']['works from the git branch'] = function()
  needs_git()
  child.lua([[_G.git_branch('someone/sc-301/render-me')]])
  child.cmd('Shortcut browse')
  eq(opened(), { 'https://app.shortcut.com/acme/story/301' })
end

T['browse']['reports a failure to open'] = function()
  child.lua([[vim.ui.open = function() return nil, 'no opener' end]])
  child.cmd('Shortcut browse 301')
  wait_messages(1)
  eq(messages(), {
    {
      msg = 'shortcut.nvim: browse: cannot open https://app.shortcut.com/acme/story/301: no opener',
      level = 4,
    },
  })
end

T['browse']['explains when there is no story'] = function()
  child.cmd('Shortcut browse')
  wait_messages(1)
  expect.no_error(function()
    assert(messages()[1].msg:find('browse: no story given', 1, true))
  end)
  eq(child.lua_get('_G.opened'), {})
end

T['yank'] = new_set()

--- A fake clipboard provider. With `shared`, `+` and `*` are the same clipboard.
local function fake_clipboard(shared)
  child.lua(
    [[
    local shared = ...
    _G.clip = { ['+'] = { '' }, ['*'] = { '' } }
    _G.copies = { ['+'] = 0, ['*'] = 0 }
    local function reg(r) return shared and '+' or r end
    local function copy(r)
      return function(lines) _G.copies[r] = _G.copies[r] + 1; _G.clip[reg(r)] = lines end
    end
    local function paste(r)
      return function() return { _G.clip[reg(r)], 'v' } end
    end
    vim.g.clipboard = {
      name = 'fake',
      copy = { ['+'] = copy('+'), ['*'] = copy('*') },
      paste = { ['+'] = paste('+'), ['*'] = paste('*') },
    }
  ]],
    { shared }
  )
end

T['yank']['copies to the unnamed register and both selections'] = function()
  fake_clipboard(false)
  child.cmd('Shortcut yank 301')
  wait_messages(1)
  local url = 'https://app.shortcut.com/acme/story/301'
  eq(child.fn.getreg('"'), url)
  eq(child.lua_get('_G.clip'), { ['+'] = { url }, ['*'] = { url } })
  eq(messages(), {
    { msg = ('shortcut.nvim: copied %s to registers "" "+ "*'):format(url), level = 2 },
  })
end

T['yank']['does not copy to * when it is the same clipboard'] = function()
  fake_clipboard(true)
  open_story()
  child.cmd('Shortcut yank')
  wait_messages(1)
  local url = 'https://app.shortcut.com/example-workspace/story/301'
  eq(child.fn.getreg('"'), url)
  eq(child.lua_get('_G.copies'), { ['+'] = 1, ['*'] = 0 })
  eq(messages(), {
    { msg = ('shortcut.nvim: copied %s to registers "" "+'):format(url), level = 2 },
  })
end

T['yank']['without a clipboard, the unnamed register only'] = function()
  child.lua([[vim.g.loaded_clipboard_provider = 1]])
  child.cmd('Shortcut yank https://app.shortcut.com/acme/epic/6')
  wait_messages(1)
  eq(child.fn.getreg('"'), 'https://app.shortcut.com/acme/epic/6')
  eq(messages(), {
    {
      msg = 'shortcut.nvim: copied https://app.shortcut.com/acme/epic/6 to the unnamed register (no clipboard available)',
      level = 2,
    },
  })
end

T['yank']['rejects extra arguments'] = function()
  child.cmd('Shortcut yank 1 2')
  expect.no_error(function()
    assert(messages()[1].msg:find('yank: expected at most one argument', 1, true))
  end)
end

---------------------------------------------------------------------------------------------------
-- refresh
---------------------------------------------------------------------------------------------------

T['refresh'] = new_set()

local function load_cache()
  child.lua([[
    local done = false
    require('shortcut.cache').load(nil, function() done = true end)
    vim.wait(3000, function() return done end, 5)
  ]])
end

local function cache_file_exists()
  return child.lua_get([[vim.uv.fs_stat(require('shortcut.cache').path('acme')) ~= nil]])
end

T['refresh']['clears the memory and disk caches and refetches'] = function()
  load_cache()
  eq(cache_file_exists(), true)
  eq(count('GET /workflows'), 1)
  -- Hold every refetch, so nothing is written back before the checks.
  child.lua([[
    for _, name in ipairs({ 'workflows', 'members', 'labels', 'groups', 'iterations' }) do
      _G.overrides['GET /' .. name] = { status = 200, hold = true, fixture = name }
    end
    _G.overrides['GET /epic-workflow'] = { status = 200, hold = true, fixture = 'epic_workflow' }
  ]])
  child.cmd('Shortcut refresh')
  -- Cleared at once.
  eq(cache_file_exists(), false)
  eq(child.lua_get([[require('shortcut.cache').workflows()]]), vim.NIL)
  child.lua([[
    vim.wait(1000, function() return #_G.held == 6 end, 5)
    for _, release in ipairs(_G.held) do release() end
  ]])
  wait_messages(1)
  eq(messages(), { { msg = 'shortcut.nvim: lookup lists refreshed', level = 2 } })
  eq(count('GET /workflows'), 2)
  eq(count('GET /labels'), 2)
  eq(cache_file_exists(), true)
end

T['refresh']['reports a failed refetch'] = function()
  child.lua([[_G.overrides['GET /labels'] = { status = 500 }]])
  child.cmd('Shortcut refresh')
  wait_messages(1)
  expect.no_error(function()
    assert(messages()[1].msg:find('refresh: cannot fetch the lookup lists: GET /labels', 1, true))
  end)
end

T['refresh']['reloads the current Shortcut buffer unless modified'] = function()
  open_story()
  eq(count('GET /stories/301'), 1)
  child.cmd('Shortcut refresh')
  child.lua('_G.wait_loaded()')
  wait_messages(1)
  eq(count('GET /stories/301'), 2)
  eq(child.bo.modified, false)

  child.api.nvim_buf_set_lines(0, 11, 12, false, { '# local edit' })
  child.cmd('Shortcut refresh')
  wait_messages(3)
  eq(count('GET /stories/301'), 2)
  eq(child.api.nvim_buf_get_lines(0, 11, 12, false), { '# local edit' })
  expect.no_error(function()
    local found = false
    for _, m in ipairs(messages()) do
      found = found or m.msg:find('unsaved changes, so it was not reloaded', 1, true) ~= nil
    end
    assert(found)
  end)
end

return T

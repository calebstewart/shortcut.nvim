local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua([[
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        _G.handlers = require('shortcut.buffer.handlers')
        -- No network: stories and epics render a fixed text; sc-<id> resolution is recorded.
        for _, kind in ipairs({ 'story', 'epic' }) do
          handlers.register(kind, {
            load = function(buf, id, opts, done) done(nil, { '# ' .. kind .. ' ' .. id }) end,
          })
        end
        _G.resolved = {}
        handlers.set_resolver(function(id, done)
          table.insert(_G.resolved, id)
          done(id >= 200 and 'epic' or 'story')
        end)

        -- The working directory is a repository on a story branch, unless a test changes it.
        _G.dir = vim.fn.tempname()
        vim.fn.mkdir(_G.dir, 'p')
        vim.cmd.cd(vim.fn.fnameescape(_G.dir))
        _G.has_git = vim.fn.executable('git') == 1
        if _G.has_git then
          local function git(...)
            local res = vim.system({ 'git', ... }, { text = true }):wait()
            assert(res.code == 0, res.stderr)
          end
          git('init', '-q')
          git('-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q',
            '--allow-empty', '-m', 'x')
          git('checkout', '-q', '-b', 'someone/sc-77/branch-story')
        end

        --- `target.resolve()`, waited for.
        function _G.resolve(arg, opts)
          local r
          require('shortcut.target').resolve(arg, opts or { command = 'test' }, function(err, t)
            r = { err = err, t = t }
          end)
          vim.wait(5000, function() return r ~= nil end, 5)
          return r
        end
      ]])
    end,
    post_once = child.stop,
  },
})

local function needs_git()
  if not child.lua_get('_G.has_git') then
    MiniTest.skip('git is not installed')
  end
end

local function resolve(arg_code, opts_code)
  return child.lua_get(('resolve(%s, %s)'):format(arg_code or 'nil', opts_code or 'nil'))
end

local function edit(name)
  child.cmd('edit ' .. child.fn.fnameescape(name))
  child.lua('vim.wait(20)')
end

T['order'] = new_set()

T['order']['an explicit argument wins over the buffer and the branch'] = function()
  needs_git()
  edit('shortcut://story/5')
  for _, arg in ipairs({ '12', 'sc-12', 'https://app.shortcut.com/acme/story/12/slug' }) do
    local r = resolve(vim.inspect(arg))
    eq(r.t.kind, 'story')
    eq(r.t.id, 12)
    eq(r.t.source, 'arg')
  end
  eq(resolve([['https://app.shortcut.com/acme/story/12/slug#activity-3']]).t, {
    kind = 'story',
    id = 12,
    source = 'arg',
    workspace = 'acme',
    comment = 3,
  })
end

T['order']['then the current buffer'] = function()
  needs_git()
  edit('shortcut://story/5')
  local r = resolve()
  eq(r.t, { kind = 'story', id = 5, source = 'buffer', buf = child.api.nvim_get_current_buf() })
  -- An empty argument counts as none.
  eq(resolve([['']]).t.id, 5)
end

T['order']['then the git branch'] = function()
  needs_git()
  eq(resolve(), { t = { kind = 'story', id = 77, source = 'branch' } })
  -- The current file's repository, not the working directory's.
  local other = child.lua_get([[(function()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, 'p')
    local function git(...)
      assert(vim.system({ 'git', ... }, { cwd = d, text = true }):wait().code == 0)
    end
    git('init', '-q')
    git('-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q', '--allow-empty', '-m', 'x')
    git('checkout', '-q', '-b', 'sc-88-other')
    vim.fn.writefile({ 'x' }, d .. '/f.txt')
    vim.cmd.edit(d .. '/f.txt')
    return resolve()
  end)()]])
  eq(other.t.id, 88)
end

T['order']['skipping the buffer when asked'] = function()
  needs_git()
  edit('shortcut://story/5')
  eq(resolve(nil, [[{ command = 'story', buffer = false }]]).t.id, 77)
end

T['order']['otherwise an error explaining how to name a story'] = function()
  child.lua([[
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, 'p')
    vim.cmd.cd(d)
  ]])
  local r = resolve(nil, [[{ command = 'comment' }]])
  eq(r.t, nil)
  expect.no_error(function()
    assert(
      r.err:find('no story given, and none found in the current buffer or git branch', 1, true)
    )
    assert(r.err:find('(git: not in a git repository)', 1, true))
    assert(r.err:find('usage: :Shortcut comment [id | sc-<id> | url]', 1, true))
  end)
end

T['order']['a branch naming no story is explained'] = function()
  needs_git()
  child.lua([[vim.system({ 'git', 'checkout', '-q', '-b', 'plain-branch' }):wait()]])
  local r = resolve()
  expect.no_error(function()
    assert(r.err:find("git branch 'plain-branch' names no story", 1, true), r.err)
  end)
end

T['kinds'] = new_set()

T['kinds']['an epic buffer is not a story'] = function()
  needs_git()
  edit('shortcut://epic/9')
  local r = resolve(nil, [[{ command = 'comment' }]])
  eq(r.err, 'sc-9 is an epic; :Shortcut comment works on stories')
  r = resolve(nil, [[{ command = 'browse', kinds = { story = true, epic = true } }]])
  eq(r.t.kind, 'epic')
  eq(r.t.id, 9)
end

T['kinds']['an epic link is not a story'] = function()
  local r = resolve([['https://app.shortcut.com/acme/epic/6']], [[{ command = 'state' }]])
  eq(r.err, 'sc-6 is an epic; :Shortcut state works on stories')
end

T['kinds']['a draft is not a story yet'] = function()
  local r = resolve([['shortcut://story/new-2']], [[{ command = 'comment' }]])
  eq(
    r.err,
    "'shortcut://story/new-2' is a draft: it is not on Shortcut until it is written (:w)\n"
      .. 'usage: :Shortcut comment [id | sc-<id> | url]'
  )
end

T['kinds']['a bare ID is a story, unless epics are accepted'] = function()
  eq(resolve([['250']]).t.kind, 'story')
  eq(child.lua_get('_G.resolved'), {})
  local opts = [[{ command = 'yank', kinds = { story = true, epic = true } }]]
  eq(resolve([['sc-250']], opts).t.kind, 'epic')
  eq(resolve([['12']], opts).t.kind, 'story')
  eq(child.lua_get('_G.resolved'), { 250, 12 })
end

T['kinds']['an unknown ID or failed lookup is reported'] = function()
  child.lua([[handlers.set_resolver(function(id, done)
    if id == 1 then done(nil) else done(nil, 'boom') end
  end)]])
  local opts = [[{ command = 'yank', kinds = { story = true, epic = true } }]]
  eq(resolve([['1']], opts).err, 'sc-1 not found')
  eq(resolve([['2']], opts).err, 'could not look up sc-2: boom')
end

T['kinds']['the comment buffer stands for its story'] = function()
  child.lua([[
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].shortcut_comment = { id = 31 }
    vim.api.nvim_buf_set_name(buf, 'shortcut://story/31/comment')
    vim.api.nvim_set_current_buf(buf)
  ]])
  eq(resolve().t.id, 31)
  eq(resolve().t.source, 'buffer')
end

T['arguments'] = new_set()

T['arguments']['invalid ones are rejected with usage'] = function()
  local r = resolve([['nope']], [[{ command = 'yank' }]])
  eq(r.err, "invalid story reference 'nope'\nusage: :Shortcut yank [id | sc-<id> | url]")
  eq(resolve([['https://example.com/acme/story/1']]).err:match('^invalid'), 'invalid')
end

return T

local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua([[
        _G.git = require('shortcut.git')

        --- Run git in `dir`; raise on failure.
        function _G.run_git(dir, ...)
          local res = vim.system({ 'git', ... }, { cwd = dir, text = true }):wait()
          assert(res.code == 0, res.stderr)
        end

        --- A new repository with one commit, on `branch` (if given).
        function _G.repo(branch)
          local dir = vim.fn.tempname()
          vim.fn.mkdir(dir, 'p')
          run_git(dir, 'init', '-q')
          run_git(dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q',
            '--allow-empty', '-m', 'x')
          if branch then run_git(dir, 'checkout', '-q', '-b', branch) end
          return dir
        end

        --- `git.branch_story(dir)`, waited for.
        function _G.branch_story(dir)
          local r
          git.branch_story(dir, function(err, id, branch)
            r = { err = err, id = id, branch = branch, fast = vim.in_fast_event() }
          end)
          vim.wait(5000, function() return r ~= nil end, 5)
          return r
        end
      ]])
    end,
    post_once = child.stop,
  },
})

local function has_git()
  if child.fn.executable('git') == 0 then
    MiniTest.skip('git is not installed')
  end
end

T['story_id()'] = new_set({
  parametrize = {
    { 'jdoe/sc-123/some-slug', 123 },
    { 'sc-123-foo', 123 },
    { 'feature/sc-123-foo', 123 },
    { 'sc-123', 123 },
    { 'fix_sc-42', 42 },
    { 'jdoe/sc-1/sc-2', 1 },
    { 'misc-12/sc-34', 34 },
    { 'main', vim.NIL },
    { 'misc-12', vim.NIL },
    { 'sc-', vim.NIL },
    { 'sc-0', vim.NIL },
    { 'sc-99999999999999999999', vim.NIL },
    { 'SC-123', vim.NIL },
  },
})

T['story_id()']['parses branch names'] = function(branch, id)
  eq(child.lua_get('git.story_id(...)', { branch }), id)
end

T['branch_story()'] = new_set()

T['branch_story()']['finds the story of the current branch'] = function()
  has_git()
  for _, case in ipairs({
    { 'jdoe/sc-123/some-slug', 123 },
    { 'sc-124-foo', 124 },
    { 'feature/sc-125-foo', 125 },
  }) do
    local r = child.lua_get('branch_story(repo(...))', { case[1] })
    eq(r, { id = case[2], branch = case[1], fast = false })
  end
end

T['branch_story()']['a branch naming no story'] = function()
  has_git()
  eq(child.lua_get([[branch_story(repo('main-work'))]]), { branch = 'main-work', fast = false })
end

T['branch_story()']['works from a subdirectory'] = function()
  has_git()
  local r = child.lua_get([[(function()
    local dir = repo('jdoe/sc-7/x')
    vim.fn.mkdir(dir .. '/a/b', 'p')
    return branch_story(dir .. '/a/b')
  end)()]])
  eq(r.id, 7)
end

T['branch_story()']['detached HEAD'] = function()
  has_git()
  local r = child.lua_get([[(function()
    local dir = repo('jdoe/sc-7/x')
    run_git(dir, 'checkout', '-q', '--detach')
    return branch_story(dir)
  end)()]])
  eq(r, { err = 'detached HEAD: not on a branch', fast = false })
end

T['branch_story()']['not in a git repository'] = function()
  has_git()
  local r = child.lua_get([[(function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    return branch_story(dir)
  end)()]])
  eq(r, { err = 'not in a git repository', fast = false })
end

T['branch_story()']['a repository without commits'] = function()
  has_git()
  local r = child.lua_get([[(function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    run_git(dir, 'init', '-q')
    return branch_story(dir)
  end)()]])
  eq(r, { err = 'the git repository has no commits yet', fast = false })
end

T['branch_story()']['git not installed'] = function()
  local r = child.lua_get([[(function()
    vim.env.PATH = '/nonexistent'
    return branch_story(vim.fn.getcwd())
  end)()]])
  expect.no_error(function()
    assert(r.err:find('^cannot run git: '), r.err)
  end)
end

T['branch_story()']['does not block: the callback runs later'] = function()
  has_git()
  local r = child.lua_get([[(function()
    local dir = repo('jdoe/sc-7/x')
    local called = false
    git.branch_story(dir, function() called = true end)
    local sync = called
    vim.wait(5000, function() return called end, 5)
    return { sync = sync, later = called }
  end)()]])
  eq(r, { sync = false, later = true })
end

T['dir()'] = new_set()

T['dir()']["is the current file's directory, else the working directory"] = function()
  local r = child.lua_get([[(function()
    local root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root .. '/sub', 'p')
    vim.fn.writefile({ 'x' }, root .. '/sub/file.txt')
    vim.cmd.cd(root)
    local out = {}
    vim.cmd.edit(root .. '/sub/file.txt')
    out.file = vim.fn.resolve(git.dir())
    vim.cmd.enew()
    out.unnamed = vim.fn.resolve(git.dir())
    vim.cmd.file('shortcut://story/5')
    out.url = vim.fn.resolve(git.dir())
    vim.cmd('enew | setlocal buftype=nofile')
    out.scratch = vim.fn.resolve(git.dir())
    return { out = out, root = root }
  end)()]])
  eq(r.out, {
    file = r.root .. '/sub',
    unnamed = r.root,
    url = r.root,
    scratch = r.root,
  })
end

return T

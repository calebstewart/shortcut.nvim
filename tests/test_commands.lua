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
      ]])
    end,
    post_once = child.stop,
  },
})

local function complete(cmdline)
  return child.lua_get('vim.fn.getcompletion(...)', { cmdline, 'cmdline' })
end

local function messages()
  return child.lua_get('_G.messages')
end

--- Register a lazily-loaded subcommand `fake` whose module records how it was called.
local function add_fake_lazy()
  child.lua([[
    _G.calls = {}
    package.preload['test.fake'] = function()
      require('shortcut.commands').register('fake', {
        desc = 'A fake subcommand',
        run = function(args, cmd) table.insert(_G.calls, { args = args, bang = cmd.bang }) end,
        complete = function(arglead, args)
          _G.completed_with = { arglead = arglead, args = args }
          return vim.tbl_filter(function(c) return vim.startswith(c, arglead) end, { 'alpha', 'beta' })
        end,
      })
      return {}
    end
    require('shortcut.commands').lazy.fake = { module = 'test.fake', desc = 'A fake subcommand' }
  ]])
end

T['startup'] = new_set()

T['startup']['defines :Shortcut without loading feature modules'] = function()
  eq(child.fn.exists(':Shortcut'), 2)
  eq(child.lua_get([[package.loaded['shortcut.commands'] == nil]]), true)
  eq(child.lua_get([[package.loaded['shortcut.config'] == nil]]), true)
  eq(child.lua_get([[package.loaded['shortcut'] == nil]]), true)
  eq(child.lua_get([[package.loaded['shortcut.buffer.commands'] == nil]]), true)
end

T['completion'] = new_set()

T['completion']['lists subcommands'] = function()
  eq(complete('Shortcut '), { 'epic', 'help', 'story' })
  add_fake_lazy()
  eq(complete('Shortcut '), { 'epic', 'fake', 'help', 'story' })
  eq(complete('Shortcut h'), { 'help' })
  eq(complete('Shortcut! f'), { 'fake' })
end

T['completion']['does not load lazy modules to list names'] = function()
  add_fake_lazy()
  complete('Shortcut ')
  eq(child.lua_get([[package.loaded['test.fake'] == nil]]), true)
end

T['completion']['delegates to the subcommand'] = function()
  add_fake_lazy()
  eq(complete('Shortcut fake '), { 'alpha', 'beta' })
  eq(child.lua_get('_G.completed_with'), { arglead = '', args = {} })

  eq(complete('Shortcut fake one b'), { 'beta' })
  eq(child.lua_get('_G.completed_with'), { arglead = 'b', args = { 'one' } })
end

T['completion']['returns nothing for unknown subcommands or no completer'] = function()
  eq(complete('Shortcut nope '), {})
  eq(complete('Shortcut help '), {})
end

T['dispatch'] = new_set()

T['dispatch']['runs a lazy subcommand with its arguments and bang'] = function()
  add_fake_lazy()
  child.cmd('Shortcut fake one two')
  child.cmd('Shortcut! fake')
  eq(
    child.lua_get('_G.calls'),
    { { args = { 'one', 'two' }, bang = false }, { args = {}, bang = true } }
  )
  eq(messages(), {})
end

T['dispatch']['shows the subcommand list with no arguments'] = function()
  child.cmd('Shortcut')
  local msgs = messages()
  eq(#msgs, 1)
  eq(msgs[1].level, vim.log.levels.INFO)
  expect.no_error(function()
    assert(msgs[1].msg:find('usage: :Shortcut', 1, true))
    assert(msgs[1].msg:find('help   List available subcommands', 1, true))
  end)
end

T['dispatch']['help lists lazy subcommands with descriptions'] = function()
  add_fake_lazy()
  child.cmd('Shortcut help')
  expect.no_error(function()
    assert(messages()[1].msg:find('fake   A fake subcommand', 1, true))
  end)
end

T['dispatch']['reports unknown subcommands with the valid list'] = function()
  child.cmd('Shortcut nope')
  local msgs = messages()
  eq(#msgs, 1)
  eq(msgs[1].level, vim.log.levels.ERROR)
  expect.no_error(function()
    assert(msgs[1].msg:find("unknown subcommand 'nope'", 1, true))
    assert(msgs[1].msg:find('help', 1, true))
  end)
end

T['dispatch']['reports errors raised by a subcommand'] = function()
  child.lua([[
    require('shortcut.commands').register('boom', {
      desc = 'Explodes',
      run = function() error('kaboom', 0) end,
    })
  ]])
  child.cmd('Shortcut boom')
  eq(messages(), { { msg = 'shortcut.nvim: boom: kaboom', level = vim.log.levels.ERROR } })
end

T['dispatch']['reports a lazy module that fails to register'] = function()
  child.lua([[
    package.preload['test.broken'] = function() return {} end
    require('shortcut.commands').lazy.broken = { module = 'test.broken', desc = 'Broken' }
  ]])
  child.cmd('Shortcut broken')
  local msgs = messages()
  eq(#msgs, 1)
  eq(msgs[1].msg, "shortcut.nvim: module 'test.broken' did not register subcommand 'broken'")
end

T['register()'] = new_set()

T['register()']['validates the spec'] = function()
  expect.error(function()
    child.lua([[require('shortcut.commands').register('bad', { desc = 'x' })]])
  end, 'spec.run')
end

return T

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
        _G.async = require('shortcut.async')
        -- Calls back later with its arguments doubled.
        _G.later = function(a, b, cb) vim.defer_fn(function() cb(a * 2, b * 2) end, 5) end
        _G.now = function(a, cb) cb(a + 1) end
      ]])
    end,
    post_once = child.stop,
  },
})

T['runs callback-based steps sequentially'] = function()
  child.lua([[
    _G.log = {}
    async.run(function()
      local x, y = async.await(later, 1, 2)
      table.insert(_G.log, { x, y })
      local z = async.await(now, x)
      table.insert(_G.log, { z })
      local p, q = async.await(later, z, y)
      table.insert(_G.log, { p, q })
      return 'done', 42
    end, function(err, a, b) _G.result = { err = err, a = a, b = b } end)
    table.insert(_G.log, 'started')
    vim.wait(1000, function() return _G.result ~= nil end)
  ]])
  eq(child.lua_get('_G.log'), { 'started', { 2, 4 }, { 3 }, { 6, 8 } })
  eq(child.lua_get('_G.result'), { a = 'done', b = 42 })
end

T['keeps nil results in place'] = function()
  child.lua([[
    async.run(function()
      local a, b, c = async.await(function(cb) cb(nil, 'x', nil) end)
      _G.out = { a == nil, b, c == nil }
    end)
  ]])
  eq(child.lua_get('_G.out'), { true, 'x', true })
end

T['ignores a second call of the callback'] = function()
  child.lua([[
    _G.count = 0
    async.run(function()
      async.await(function(cb) cb(1); cb(2) end)
      _G.count = _G.count + 1
      async.await(later, 1, 1)
      _G.count = _G.count + 1
    end)
    vim.wait(200)
  ]])
  eq(child.lua_get('_G.count'), 2)
end

T['passes errors to on_done with a traceback'] = function()
  child.lua([[
    async.run(function()
      async.await(later, 1, 1)
      error('kaboom')
    end, function(err) _G.err = err end)
    vim.wait(1000, function() return _G.err ~= nil end)
  ]])
  local err = child.lua_get('_G.err')
  eq(err:find('kaboom', 1, true) ~= nil, true)
  eq(err:find('stack traceback', 1, true) ~= nil, true)
end

T['reports errors without on_done'] = function()
  child.lua([[
    async.run(function() error('kaboom') end)
    vim.wait(1000, function() return #_G.messages > 0 end)
  ]])
  local msgs = child.lua_get('_G.messages')
  eq(#msgs, 1)
  eq(msgs[1].level, vim.log.levels.ERROR)
  eq(msgs[1].msg:find('kaboom', 1, true) ~= nil, true)
end

T['await() outside run() is an error'] = function()
  expect.error(function()
    child.lua([[async.await(now, 1)]])
  end, 'must be called inside async.run')
  expect.error(function()
    child.lua([[coroutine.wrap(function() async.await(now, 1) end)()]])
  end, 'must be called inside async.run')
end

T['works with http.request'] = function()
  child.lua([[
    vim.env.SHORTCUT_API_TOKEN = 'test-token-0000-1111-2222-3333wxyz'
    dofile('tests/fake_transport.lua')
    _G.responses = { { status = 200, body = '{"id": 1}' }, { status = 404, body = '' } }
    local http = require('shortcut.http')
    async.run(function()
      local err1, data = async.await(http.request, { path = '/stories/1' })
      local err2 = async.await(http.request, { path = '/stories/2' })
      _G.out = { err1 = err1, data = data, status2 = err2.status }
    end)
    vim.wait(1000, function() return _G.out ~= nil end)
  ]])
  eq(child.lua_get('_G.out'), { data = { id = 1 }, status2 = 404 })
end

return T

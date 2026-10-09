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
        _G.config = require('shortcut.config')
      ]])
    end,
    post_once = child.stop,
  },
})

local function setup(opts)
  return child.lua('return config.setup(...)', { opts })
end

local function get()
  return child.lua_get('config.get()')
end

local function messages()
  return child.lua_get('_G.messages')
end

T['defaults apply without setup()'] = function()
  eq(get(), {
    cache = { ttl = 86400 },
    sc_ids = true,
    picker = { page_size = 25, max_results = 200 },
    http = { timeout = 30 },
  })
  eq(messages(), {})
end

T['setup() merges nested options over the defaults'] = function()
  eq(setup({ picker = { page_size = 10 }, sc_ids = false, token = 'abc' }), true)
  local cfg = get()
  eq(cfg.picker, { page_size = 10, max_results = 200 })
  eq(cfg.sc_ids, false)
  eq(cfg.token, 'abc')
  eq(cfg.http, { timeout = 30 })
  eq(messages(), {})
end

T['setup() is reachable through the main module'] = function()
  eq(child.lua_get([[require('shortcut').setup({ http = { timeout = 5 } })]]), true)
  eq(get().http.timeout, 5)
end

T['setup() starts from the defaults each time'] = function()
  setup({ picker = { page_size = 10 } })
  setup({ sc_ids = false })
  eq(get().picker.page_size, 25)
  eq(get().sc_ids, false)
end

T['token may be a function'] = function()
  eq(child.lua_get([[config.setup({ token = function() return 'from-fn' end })]]), true)
  eq(child.lua_get('config.get().token()'), 'from-fn')
end

T['invalid types are reported and leave the configuration unchanged'] = function()
  setup({ sc_ids = false })
  eq(setup({ sc_ids = 'yes', picker = { page_size = -1 }, http = 'fast' }), false)

  local msgs = messages()
  eq(#msgs, 1)
  eq(msgs[1].level, vim.log.levels.ERROR)
  expect.no_error(function()
    assert(msgs[1].msg:find('invalid configuration', 1, true))
    assert(msgs[1].msg:find('sc_ids', 1, true))
    assert(msgs[1].msg:find('picker.page_size', 1, true))
    assert(msgs[1].msg:find('http: expected table, got string', 1, true))
  end)
  eq(get().sc_ids, false)
end

T['non-integer numbers are rejected'] = function()
  eq(setup({ cache = { ttl = 1.5 } }), false)
end

T['picker.page_size is at most 250, as the API allows'] = function()
  eq(setup({ picker = { page_size = 250 } }), true)
  eq(setup({ picker = { page_size = 251 } }), false)
  expect.no_error(function()
    assert(messages()[1].msg:find('integer from 1 to 250', 1, true))
  end)
  eq(get().picker.page_size, 250)
end

T['unknown keys warn but still apply the rest'] = function()
  eq(setup({ sc_idz = false, picker = { pagesize = 1 }, http = { timeout = 7 } }), true)
  local msgs = messages()
  eq(#msgs, 2)
  eq(msgs[1].level, vim.log.levels.WARN)
  expect.no_error(function()
    assert(msgs[1].msg:find("unknown option 'picker.pagesize'", 1, true))
    assert(msgs[2].msg:find("unknown option 'sc_idz'", 1, true))
  end)
  eq(get().http.timeout, 7)
end

T['setup() rejects a non-table argument'] = function()
  eq(setup('nope'), false)
  eq(messages()[1].level, vim.log.levels.ERROR)
end

T['setup() with no argument uses the defaults'] = function()
  eq(child.lua_get('config.setup()'), true)
  eq(get().picker.page_size, 25)
end

return T

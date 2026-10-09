local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local TOKEN = 'test-token-0000-1111-2222-3333wxyz'

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua([[dofile('tests/fake_transport.lua')]])
    end,
    post_once = child.stop,
  },
})

--- Run :checkhealth shortcut and return the report.
---@return string
local function checkhealth()
  child.cmd('checkhealth shortcut')
  return table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end

---@param report string
---@param text string
local function has(report, text)
  if not report:find(text, 1, true) then
    error(('%q not found in the report:\n%s'):format(text, report), 2)
  end
end

T['reports a working token'] = function()
  child.lua('vim.env.SHORTCUT_API_TOKEN = ...', { TOKEN })
  child.lua([[_G.responses = { { status = 200, fixture = 'member' } }]])
  local report = checkhealth()
  has(report, 'Neovim 0.')
  has(report, 'curl')
  has(report, 'token ****wxyz from $SHORTCUT_API_TOKEN')
  has(report, 'the token works: @jdoe in workspace acme')
  has(report, 'snacks.nvim not found')
  eq(report:find(TOKEN, 1, true), nil)

  local req = child.lua_get('_G.requests[1]')
  eq(req.url, 'https://api.app.shortcut.com/api/v3/member')
  eq(req.timeout, 10)
end

T['reports a token that does not work'] = function()
  child.lua('vim.env.SHORTCUT_API_TOKEN = ...', { TOKEN })
  child.lua([[_G.responses = { { status = 401, body = '{"message": "Unauthorized"}' } }]])
  local report = checkhealth()
  has(report, 'the token does not work: GET /member: HTTP 401')
  has(report, ':Shortcut login')
  eq(report:find(TOKEN, 1, true), nil)
  eq(#child.lua_get('_G.requests'), 1) -- no retries
end

T['reports a missing token'] = function()
  local report = checkhealth()
  has(report, 'no usable API token')
  has(report, 'short install')
  eq(#child.lua_get('_G.requests'), 0)
end

T['names the short config file as the source'] = function()
  local dir = child.lua_get('vim.fn.tempname()')
  child.lua(
    [[
    local dir, token = ...
    vim.env.XDG_CONFIG_HOME = dir
    vim.fn.mkdir(dir .. '/shortcut-cli', 'p')
    vim.fn.writefile({ vim.json.encode({ token = token, mentionName = 'jdoe', urlSlug = 'acme' }) },
      dir .. '/shortcut-cli/config.json')
    _G.responses = { { status = 200, fixture = 'member' } }
  ]],
    { dir, TOKEN }
  )
  local report = checkhealth()
  has(report, 'from the `short` CLI config ')
  has(report, '/shortcut-cli/config.json')
  has(report, 'saved identity: @jdoe in workspace acme')
end

T['finds snacks.nvim on the runtimepath'] = function()
  local dir = child.lua_get('vim.fn.tempname()')
  child.lua(
    [[
    local dir = ...
    vim.fn.mkdir(dir .. '/lua/snacks', 'p')
    vim.fn.writefile({ 'return {}' }, dir .. '/lua/snacks/init.lua')
    vim.opt.runtimepath:append(dir)
  ]],
    { dir }
  )
  has(checkhealth(), 'snacks.nvim is installed')
end

return T

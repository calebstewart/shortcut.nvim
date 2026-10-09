local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local NEW_TOKEN = 'new-token-0000-1111-2222-3333abcd'
local OLD_TOKEN = 'old-token-4444-5555-6666-7777efgh'

-- A temporary XDG_CONFIG_HOME per case (minimal_init already gives a temporary HOME).
local dir

local T = new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, 'p')
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua(
        [[
        local dir, token = ...
        vim.env.XDG_CONFIG_HOME = dir
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        _G.input = token
        vim.fn.inputsecret = function(prompt) _G.prompt = prompt; return _G.input end
        _G.confirms = {}
        _G.confirm_answer = 1
        vim.fn.confirm = function(msg) table.insert(_G.confirms, msg); return _G.confirm_answer end
        dofile('tests/fake_transport.lua')
        -- Answer GET /member according to the token used.
        _G.members = {}
        _G.routes = function(req)
          for _, h in ipairs(req.headers) do
            local t = h:match('^Shortcut%-Token: (.*)$')
            if t then
              local fixture = _G.members[t]
              if fixture then return { status = 200, fixture = fixture } end
              return { status = 401, body = '{"message": "Unauthorized"}' }
            end
          end
        end
      ]],
        { dir, NEW_TOKEN }
      )
    end,
    post_case = function()
      vim.fn.delete(dir, 'rf')
    end,
    post_once = child.stop,
  },
})

local function config_file()
  return dir .. '/shortcut-cli/config.json'
end

---@param data table
local function write_config(data)
  vim.fn.mkdir(dir .. '/shortcut-cli', 'p')
  vim.fn.writefile({ vim.json.encode(data) }, config_file())
end

---@return table?
local function read_config()
  if vim.fn.filereadable(config_file()) == 0 then
    return nil
  end
  return vim.json.decode(table.concat(vim.fn.readfile(config_file()), '\n'))
end

--- Run :Shortcut login and wait for its final message.
local function login()
  child.cmd('Shortcut login')
  child.lua([[
    vim.wait(2000, function()
      for _, m in ipairs(_G.messages) do
        if m.msg:find('Logged in', 1, true) or m.msg:find('login', 1, true) then return true end
      end
      return false
    end)
    vim.wait(20)
  ]])
end

local function messages()
  return child.lua_get('_G.messages')
end

--- No message ever contains a token.
local function assert_no_token_in_messages()
  for _, m in ipairs(messages()) do
    eq(m.msg:find(NEW_TOKEN, 1, true), nil)
    eq(m.msg:find(OLD_TOKEN, 1, true), nil)
  end
end

T['saves a valid token, keeping other keys'] = function()
  write_config({ workspaces = { acme = 'x' }, other = true })
  child.lua('_G.members[...] = "member"', { NEW_TOKEN })
  login()
  eq(read_config(), {
    token = NEW_TOKEN,
    mentionName = 'jdoe',
    urlSlug = 'acme',
    workspaces = { acme = 'x' },
    other = true,
  })
  eq(messages(), {
    { msg = 'shortcut.nvim: Logged in as @jdoe (acme)', level = vim.log.levels.INFO },
  })
  eq(child.lua_get('_G.prompt'), 'Shortcut API token: ')
  -- The new token is now the one in use.
  eq(child.lua_get([[require('shortcut.auth').resolve().token]]), NEW_TOKEN)
  eq(child.lua_get([[require('shortcut.auth').resolve().url_slug]]), 'acme')
  eq(child.lua_get('_G.confirms'), {})
end

T['creates the config when there is none'] = function()
  child.lua('_G.members[...] = "member"', { NEW_TOKEN })
  login()
  eq(read_config(), { token = NEW_TOKEN, mentionName = 'jdoe', urlSlug = 'acme' })
end

T['an invalid token writes nothing'] = function()
  write_config({ token = OLD_TOKEN, urlSlug = 'acme' })
  login()
  eq(read_config(), { token = OLD_TOKEN, urlSlug = 'acme' })
  local msgs = messages()
  eq(#msgs, 1)
  eq(msgs[1].level, vim.log.levels.ERROR)
  eq(msgs[1].msg:find('login failed: GET /member: HTTP 401', 1, true) ~= nil, true)
  eq(msgs[1].msg:find('Nothing was saved', 1, true) ~= nil, true)
  assert_no_token_in_messages()
end

T['an invalid token creates no file'] = function()
  login()
  eq(read_config(), nil)
end

T['a network failure writes nothing'] = function()
  child.lua([[_G.routes = function() return { error = 'Could not resolve host' } end]])
  login()
  eq(read_config(), nil)
  eq(messages()[1].msg:find('Could not resolve host', 1, true) ~= nil, true)
end

T['empty input cancels'] = function()
  child.lua('_G.input = "  "')
  login()
  eq(#child.lua_get('_G.requests'), 0)
  eq(messages(), { { msg = 'shortcut.nvim: login cancelled', level = vim.log.levels.WARN } })
end

T['other workspace'] = new_set()

T['other workspace']['asks before replacing the token; declining keeps it'] = function()
  write_config({ token = OLD_TOKEN, mentionName = 'old', urlSlug = 'other' })
  child.lua('_G.members[...] = "member"; _G.confirm_answer = 2', { NEW_TOKEN })
  login()
  eq(read_config(), { token = OLD_TOKEN, mentionName = 'old', urlSlug = 'other' })
  local confirms = child.lua_get('_G.confirms')
  eq(#confirms, 1)
  eq(confirms[1]:find("workspace 'other'; this one is for 'acme'", 1, true) ~= nil, true)
  eq(messages()[1].msg, 'shortcut.nvim: login cancelled; the saved token was kept')
end

T['other workspace']['replaces the token when confirmed'] = function()
  write_config({ token = OLD_TOKEN, mentionName = 'old', urlSlug = 'other' })
  child.lua('_G.members[...] = "member"', { NEW_TOKEN })
  login()
  eq(read_config(), { token = NEW_TOKEN, mentionName = 'jdoe', urlSlug = 'acme' })
  eq(#child.lua_get('_G.confirms'), 1)
end

T['other workspace']['asks the API when the saved slug is unknown'] = function()
  write_config({ token = OLD_TOKEN })
  child.lua(
    '_G.members[select(1, ...)] = "member"; _G.members[select(2, ...)] = "member_other"; _G.confirm_answer = 2',
    { NEW_TOKEN, OLD_TOKEN }
  )
  login()
  eq(read_config(), { token = OLD_TOKEN })
  eq(#child.lua_get('_G.confirms'), 1)
  assert_no_token_in_messages()
end

T['other workspace']['does not ask for the same workspace'] = function()
  write_config({ token = OLD_TOKEN, urlSlug = 'ACME' })
  child.lua('_G.members[...] = "member"', { NEW_TOKEN })
  login()
  eq(child.lua_get('_G.confirms'), {})
  eq(read_config().token, NEW_TOKEN)
end

T['other workspace']['does not ask when the saved token is invalid'] = function()
  write_config({ token = OLD_TOKEN })
  child.lua('_G.members[...] = "member"', { NEW_TOKEN })
  login()
  eq(child.lua_get('_G.confirms'), {})
  eq(read_config().token, NEW_TOKEN)
end

T['warns when an environment token takes precedence'] = function()
  child.lua('vim.env.SHORTCUT_API_TOKEN = "env-token-aaaa-bbbb-cccc-dddd"')
  child.lua('_G.members[...] = "member"', { NEW_TOKEN })
  login()
  eq(read_config().token, NEW_TOKEN)
  local msgs = messages()
  eq(#msgs, 2)
  eq(msgs[2].level, vim.log.levels.WARN)
  eq(msgs[2].msg:find('$SHORTCUT_API_TOKEN', 1, true) ~= nil, true)
end

T['refuses to overwrite a malformed config'] = function()
  vim.fn.mkdir(dir .. '/shortcut-cli', 'p')
  vim.fn.writefile({ '{ not json' }, config_file())
  child.lua('_G.members[...] = "member"', { NEW_TOKEN })
  login()
  eq(vim.fn.readfile(config_file()), { '{ not json' })
  eq(messages()[1].level, vim.log.levels.ERROR)
end

return T

local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

-- Every case gets a fresh temporary HOME, and the child Neovim's environment is scrubbed, so
-- that tests never see (let alone touch) the real `short` config or a real token.
local home

local TOKEN = 'file-token-0000-1111-2222-3333abcd'
local ENV_TOKEN = 'env-token-4444-5555-6666-7777efgh'

local T = new_set({
  hooks = {
    pre_case = function()
      home = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(home, 'p')
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua(
        [[
        local home = ...
        vim.env.HOME = home
        for _, name in ipairs({
          'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'SHORTCUT_API_TOKEN', 'CLUBHOUSE_API_TOKEN',
        }) do
          vim.env[name] = nil
        end
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        _G.auth = require('shortcut.auth')
        _G.config = require('shortcut.config')
      ]],
        { home }
      )
    end,
    post_case = function()
      vim.fn.delete(home, 'rf')
    end,
    post_once = child.stop,
  },
})

--- The default CLI config file inside the temporary HOME.
local function default_file()
  return home .. '/.config/shortcut-cli/config.json'
end

---@param path string
---@param content string|table A table is encoded as JSON.
local function write(path, content)
  if type(content) == 'table' then
    content = vim.json.encode(content)
  end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'w'))
  f:write(content)
  f:close()
end

---@param path string
---@return table
local function read_json(path)
  local f = assert(io.open(path, 'r'))
  local data = f:read('*a')
  f:close()
  return vim.json.decode(data)
end

local function setenv(name, value)
  child.lua('vim.env[...] = select(2, ...)', { name, value })
end

local function setup(opts)
  eq(child.lua('return config.setup(...)', { opts }), true)
end

--- `auth.resolve()` in the child, as `{ ok = result, err = err }`.
local function resolve()
  return child.lua('local ok, err = auth.resolve(); return { ok = ok, err = err }')
end

local function messages()
  return child.lua_get('_G.messages')
end

---@param haystack string
---@param needle string
local function contains(haystack, needle)
  if not haystack:find(needle, 1, true) then
    error(('expected %q to contain %q'):format(haystack, needle), 2)
  end
end

---@param haystack string
---@param needle string
local function not_contains(haystack, needle)
  if haystack:find(needle, 1, true) then
    error(('expected %q not to contain %q'):format(haystack, needle), 2)
  end
end

local function full_file()
  write(default_file(), {
    token = TOKEN,
    mentionName = 'someone',
    urlSlug = 'my-workspace',
    workspaces = {},
  })
end

T['cli_config_path()'] = new_set()

T['cli_config_path()']['defaults to ~/.config/shortcut-cli/config.json'] = function()
  eq(child.lua_get('auth.cli_config_path()'), default_file())
end

T['cli_config_path()']['honours XDG_CONFIG_HOME'] = function()
  setenv('XDG_CONFIG_HOME', home .. '/xdg')
  eq(child.lua_get('auth.cli_config_path()'), home .. '/xdg/shortcut-cli/config.json')
end

T['cli_config_path()']['treats an empty XDG_CONFIG_HOME as unset'] = function()
  setenv('XDG_CONFIG_HOME', '')
  eq(child.lua_get('auth.cli_config_path()'), default_file())
end

T['cli_config_path()']['falls back to XDG_DATA_HOME/.config like the CLI'] = function()
  setenv('XDG_DATA_HOME', home .. '/data')
  eq(child.lua_get('auth.cli_config_path()'), home .. '/data/.config/shortcut-cli/config.json')
end

T['cli_config_path()']['is not affected by NVIM_APPNAME'] = function()
  -- The child inherits this process's environment, so NVIM_APPNAME applies from its startup.
  local saved = vim.env.NVIM_APPNAME
  vim.env.NVIM_APPNAME = 'shortcut-nvim-dev'
  local ok, err = pcall(child.restart, { '-u', 'tests/minimal_init.lua' })
  vim.env.NVIM_APPNAME = saved
  assert(ok, err)
  child.lua(
    [[
    vim.env.HOME = ...
    vim.env.XDG_CONFIG_HOME = nil
    vim.env.XDG_DATA_HOME = nil
  ]],
    { home }
  )
  contains(child.lua_get([[vim.fn.stdpath('config')]]), 'shortcut-nvim-dev')
  eq(child.lua_get([[require('shortcut.auth').cli_config_path()]]), default_file())
end

T['cli_config_path()']['uses the cli_config_path option, expanding ~'] = function()
  setup({ cli_config_path = '~/elsewhere/short.json' })
  eq(child.lua_get('auth.cli_config_path()'), home .. '/elsewhere/short.json')
end

T['resolve()'] = new_set()

T['resolve()']['reads token and identity from an existing short config'] = function()
  full_file()
  eq(resolve(), {
    ok = {
      token = TOKEN,
      source = 'cli_config',
      mention_name = 'someone',
      url_slug = 'my-workspace',
    },
  })
  eq(messages(), {})
end

T['resolve()']['reads the cli_config_path override'] = function()
  write(home .. '/custom.json', { token = TOKEN, mentionName = 'me' })
  setup({ cli_config_path = home .. '/custom.json' })
  eq(resolve(), { ok = { token = TOKEN, source = 'cli_config', mention_name = 'me' } })
end

T['resolve()']['reads a legacy ~/.clubhouse-cli config the CLI has not migrated'] = function()
  write(home .. '/.clubhouse-cli/config.json', { token = TOKEN })
  eq(resolve(), { ok = { token = TOKEN, source = 'cli_config' } })
  -- Reading never moves anything.
  eq(vim.uv.fs_stat(home .. '/.clubhouse-cli/config.json') ~= nil, true)
end

T['precedence'] = new_set()

T['precedence']['setup string beats env and file'] = function()
  full_file()
  setenv('SHORTCUT_API_TOKEN', ENV_TOKEN)
  setup({ token = 'setup-token' })
  eq(resolve(), { ok = { token = 'setup-token', source = 'setup' } })
end

T['precedence']['setup function beats env and file'] = function()
  full_file()
  setenv('SHORTCUT_API_TOKEN', ENV_TOKEN)
  child.lua([[config.setup({ token = function() return 'fn-token' end })]])
  eq(resolve(), { ok = { token = 'fn-token', source = 'setup' } })
end

T['precedence']['env beats file'] = function()
  full_file()
  setenv('SHORTCUT_API_TOKEN', ENV_TOKEN)
  eq(resolve(), { ok = { token = ENV_TOKEN, source = 'env' } })
end

T['precedence']['SHORTCUT_API_TOKEN beats CLUBHOUSE_API_TOKEN'] = function()
  setenv('SHORTCUT_API_TOKEN', ENV_TOKEN)
  setenv('CLUBHOUSE_API_TOKEN', 'legacy-env-token')
  eq(resolve(), { ok = { token = ENV_TOKEN, source = 'env' } })
end

T['precedence']['CLUBHOUSE_API_TOKEN is honoured like the CLI does'] = function()
  full_file()
  setenv('CLUBHOUSE_API_TOKEN', 'legacy-env-token')
  eq(resolve(), { ok = { token = 'legacy-env-token', source = 'env' } })
end

T['precedence']['empty setup token and env are treated as unset'] = function()
  full_file()
  setenv('SHORTCUT_API_TOKEN', '')
  setup({ token = '' })
  eq(resolve().ok.source, 'cli_config')
end

T['precedence']['an env token ignores a malformed file'] = function()
  write(default_file(), '{ nope')
  setenv('SHORTCUT_API_TOKEN', ENV_TOKEN)
  eq(resolve(), { ok = { token = ENV_TOKEN, source = 'env' } })
end

T['identity'] = new_set()

T['identity']['comes from the file when its token matches'] = function()
  full_file()
  setenv('SHORTCUT_API_TOKEN', TOKEN)
  eq(resolve(), {
    ok = { token = TOKEN, source = 'env', mention_name = 'someone', url_slug = 'my-workspace' },
  })
end

T['identity']['is left unset when the setup token differs'] = function()
  full_file()
  setup({ token = 'other-workspace-token' })
  local result = resolve().ok
  eq(result.mention_name, nil)
  eq(result.url_slug, nil)
end

T['identity']['is left unset when the env token differs'] = function()
  full_file()
  setenv('SHORTCUT_API_TOKEN', ENV_TOKEN)
  local result = resolve().ok
  eq(result.mention_name, nil)
  eq(result.url_slug, nil)
end

T['errors'] = new_set()

---@param err string
local function expect_fix_hints(err)
  contains(err, 'no Shortcut API token found')
  contains(err, 'short install')
  contains(err, ':Shortcut login')
  contains(err, 'SHORTCUT_API_TOKEN')
  contains(err, 'setup()')
end

T['errors']['missing file explains how to fix it'] = function()
  local r = resolve()
  eq(r.ok, nil)
  expect_fix_hints(r.err)
  contains(r.err, default_file())
end

T['errors']['file without a token explains how to fix it'] = function()
  write(default_file(), { mentionName = 'someone', workspaces = {} })
  local r = resolve()
  eq(r.ok, nil)
  expect_fix_hints(r.err)
end

T['errors']['empty file counts as no token'] = function()
  write(default_file(), '  \n')
  expect_fix_hints(resolve().err)
end

T['errors']['malformed JSON names the path without quoting the file'] = function()
  write(default_file(), '{"token": "' .. TOKEN .. '",')
  local r = resolve()
  eq(r.ok, nil)
  contains(r.err, default_file())
  contains(r.err, 'not a valid JSON object')
  not_contains(r.err, TOKEN)
  eq(messages(), {})
end

T['errors']['a JSON value that is not an object is malformed'] = function()
  write(default_file(), '["' .. TOKEN .. '"]')
  local r = resolve()
  eq(r.ok, nil)
  contains(r.err, 'not a valid JSON object')
end

T['errors']['an unreadable file names the path and how to fix it'] = function()
  if vim.uv.getuid() == 0 then
    MiniTest.skip('root can read any file')
  end
  write(default_file(), { token = TOKEN })
  vim.uv.fs_chmod(default_file(), 0)
  local r = resolve()
  eq(r.ok, nil)
  contains(r.err, 'cannot read ' .. default_file())
  contains(r.err, 'chmod 600')
  contains(r.err, 'SHORTCUT_API_TOKEN')
end

T['errors']['a failing setup function is reported without a traceback'] = function()
  full_file()
  child.lua([[config.setup({ token = function() error('vault is locked') end })]])
  local r = resolve()
  eq(r.ok, nil)
  contains(r.err, 'the `token` function passed to setup() failed')
  contains(r.err, 'vault is locked')
  not_contains(r.err, 'traceback')
  not_contains(r.err, '\n')
end

T['errors']['a setup function returning a non-string is reported'] = function()
  child.lua([[config.setup({ token = function() return nil end })]])
  local r = resolve()
  eq(r.ok, nil)
  contains(r.err, 'returned nil instead of a non-empty string')
end

T['cache'] = new_set()

T['cache']['calls the setup function once per session'] = function()
  child.lua([[
    _G.calls = 0
    config.setup({ token = function() _G.calls = _G.calls + 1; return 'fn-token' end })
  ]])
  resolve()
  resolve()
  eq(child.lua_get('_G.calls'), 1)
  child.lua('auth.reset()')
  resolve()
  eq(child.lua_get('_G.calls'), 2)
end

T['cache']['keeps the result until reset()'] = function()
  full_file()
  eq(resolve().ok.token, TOKEN)
  write(default_file(), { token = 'new-token' })
  eq(resolve().ok.token, TOKEN)
  child.lua('auth.reset()')
  eq(resolve().ok.token, 'new-token')
end

T['cache']['is invalidated by setup()'] = function()
  full_file()
  eq(resolve().ok.source, 'cli_config')
  setup({ token = 'setup-token' })
  eq(resolve().ok.source, 'setup')
end

T['cache']['does not cache errors'] = function()
  expect_fix_hints(resolve().err)
  full_file()
  eq(resolve().ok.token, TOKEN)
end

T['cache']['returns copies'] = function()
  full_file()
  child.lua('auth.resolve().token = "mutated"')
  eq(resolve().ok.token, TOKEN)
end

T['redacted()'] = function()
  eq(child.lua_get('auth.redacted(...)', { TOKEN }), '****abcd')
  eq(child.lua_get('auth.redacted("short")'), '****')
  eq(child.lua_get('auth.redacted()'), '****')
end

T['write_cli_config()'] = new_set()

local function write_cli_config(fields)
  return child.lua(
    'local ok, err = auth.write_cli_config(...); return { ok = ok, err = err }',
    { fields }
  )
end

---@param path string
---@return integer
local function mode(path)
  return bit.band(assert(vim.uv.fs_stat(path)).mode, tonumber('777', 8))
end

T['write_cli_config()']['keeps unknown keys and merges fields'] = function()
  write(
    default_file(),
    '{"token":"old","mentionName":"old-name","workspaces":{"mine":{"owner":"me","empty":{}},'
      .. '"none":{}},"other":[1,2],"flag":null}'
  )
  eq(write_cli_config({ token = TOKEN, mentionName = 'someone', urlSlug = 'ws' }), { ok = true })

  local data = read_json(default_file())
  eq(data.token, TOKEN)
  eq(data.mentionName, 'someone')
  eq(data.urlSlug, 'ws')
  eq(data.workspaces.mine.owner, 'me')
  eq(data.other, { 1, 2 })
  eq(data.flag, vim.NIL)
  -- Empty objects stay objects (and are not turned into arrays).
  local raw = table.concat(vim.fn.readfile(default_file()), '\n')
  contains(raw, '"none":{}')
  contains(raw, '"empty":{}')
end

T['write_cli_config()']['creates missing directories'] = function()
  setenv('XDG_CONFIG_HOME', home .. '/a/b')
  eq(write_cli_config({ token = TOKEN }), { ok = true })
  eq(read_json(home .. '/a/b/shortcut-cli/config.json'), { token = TOKEN })
end

T['write_cli_config()']['writes the cli_config_path override'] = function()
  setup({ cli_config_path = home .. '/x/y.json' })
  eq(write_cli_config({ token = TOKEN }), { ok = true })
  eq(read_json(home .. '/x/y.json'), { token = TOKEN })
end

T['write_cli_config()']['leaves the file with mode 0600'] = function()
  write(default_file(), { token = 'old' })
  vim.uv.fs_chmod(default_file(), tonumber('644', 8))
  eq(write_cli_config({ token = TOKEN }), { ok = true })
  eq(mode(default_file()), tonumber('600', 8))

  vim.fn.delete(home .. '/.config', 'rf')
  eq(write_cli_config({ token = TOKEN }), { ok = true })
  eq(mode(default_file()), tonumber('600', 8))
end

T['write_cli_config()']['leaves no temporary files behind'] = function()
  eq(write_cli_config({ token = TOKEN }), { ok = true })
  eq(vim.fn.readdir(vim.fs.dirname(default_file())), { 'config.json' })
end

T['write_cli_config()']['refuses to overwrite a malformed file'] = function()
  write(default_file(), '{ broken')
  local r = write_cli_config({ token = TOKEN })
  eq(r.ok, nil)
  contains(r.err, default_file())
  not_contains(r.err, TOKEN)
  eq(table.concat(vim.fn.readfile(default_file()), '\n'), '{ broken')
end

T['write_cli_config()']['writes through a symlink'] = function()
  write(home .. '/dotfiles/short.json', { token = 'old', workspaces = { a = { b = 1 } } })
  vim.fn.mkdir(vim.fs.dirname(default_file()), 'p')
  assert(vim.uv.fs_symlink(home .. '/dotfiles/short.json', default_file()))
  eq(write_cli_config({ token = TOKEN }), { ok = true })
  eq(vim.uv.fs_lstat(default_file()).type, 'link')
  eq(read_json(home .. '/dotfiles/short.json'), { token = TOKEN, workspaces = { a = { b = 1 } } })
end

T['write_cli_config()']['migrates a legacy config dir like the CLI'] = function()
  write(home .. '/.clubhouse-cli/config.json', { token = 'old', workspaces = { a = { b = 1 } } })
  eq(write_cli_config({ token = TOKEN }), { ok = true })
  eq(vim.uv.fs_stat(home .. '/.clubhouse-cli'), nil)
  eq(read_json(default_file()), { token = TOKEN, workspaces = { a = { b = 1 } } })
end

T['write_cli_config()']['migrates a legacy config dir onto an empty config dir'] = function()
  write(home .. '/.clubhouse-cli/config.json', { token = 'old', workspaces = { a = { b = 1 } } })
  vim.fn.mkdir(vim.fs.dirname(default_file()), 'p')
  eq(resolve().ok.token, 'old')
  eq(write_cli_config({ token = TOKEN }), { ok = true })
  eq(vim.uv.fs_stat(home .. '/.clubhouse-cli'), nil)
  eq(read_json(default_file()), { token = TOKEN, workspaces = { a = { b = 1 } } })
end

T['write_cli_config()']['refuses to migrate onto a non-empty config dir'] = function()
  write(home .. '/.clubhouse-cli/config.json', { token = 'old' })
  write(vim.fs.dirname(default_file()) .. '/other', 'x')
  local r = write_cli_config({ token = TOKEN })
  eq(r.ok, nil)
  contains(r.err, 'cannot move the legacy short config ' .. home .. '/.clubhouse-cli')
  contains(r.err, 'yourself')
  eq(read_json(home .. '/.clubhouse-cli/config.json'), { token = 'old' })
  eq(vim.uv.fs_stat(default_file()), nil)
end

T['write_cli_config()']['writes {} rather than [] for no fields'] = function()
  eq(write_cli_config({}), { ok = true })
  eq(table.concat(vim.fn.readfile(default_file()), '\n'), '{}')
end

T['write_cli_config()']['resets the cached token'] = function()
  full_file()
  eq(resolve().ok.token, TOKEN)
  eq(write_cli_config({ token = 'fresh-token' }), { ok = true })
  eq(resolve().ok.token, 'fresh-token')
end

T['write_cli_config()']['shows no messages'] = function()
  write_cli_config({ token = TOKEN })
  resolve()
  eq(messages(), {})
end

T['fast context'] = new_set()

T['fast context']['works from a libuv callback'] = function()
  full_file()
  local r = child.lua([[
    local out
    local timer = assert(vim.uv.new_timer())
    timer:start(0, 0, function()
      timer:close()
      local ok, err = pcall(function()
        local path = auth.cli_config_path()
        local first, first_err = auth.resolve()
        local wrote, write_err = auth.write_cli_config({ token = 'fresh-token' })
        local second, second_err = auth.resolve()
        return {
          path = path,
          first = first and first.token or first_err,
          wrote = wrote or write_err,
          second = second and second.token or second_err,
        }
      end)
      out = ok and err or { error = tostring(err) }
    end)
    vim.wait(5000, function() return out ~= nil end)
    return out
  ]])
  eq(r, { path = default_file(), first = TOKEN, wrote = true, second = 'fresh-token' })
end

return T

--- `:checkhealth shortcut`.
local M = {}

--- How long to wait for `GET /member`, in seconds.
M.TOKEN_CHECK_TIMEOUT = 10

local function check_neovim()
  local v = vim.version()
  local version = ('%d.%d.%d'):format(v.major, v.minor, v.patch)
  if vim.fn.has('nvim-0.12') == 1 then
    vim.health.ok(('Neovim %s'):format(version))
  else
    vim.health.error(
      ('Neovim %s is too old'):format(version),
      { 'Upgrade to Neovim 0.12 or later.' }
    )
  end
end

local function check_curl()
  if vim.fn.executable('curl') ~= 1 then
    vim.health.error('curl not found', { 'Install curl and make sure it is on $PATH.' })
    return
  end
  local ok, res = pcall(function()
    return vim.system({ 'curl', '--version' }, { text = true }):wait(5000)
  end)
  local first = ok and res.code == 0 and (res.stdout or ''):match('^[^\n]*') or nil
  local version = first and first:match('^curl (%S+)')
  if version then
    vim.health.ok(('curl %s (%s)'):format(version, vim.fn.exepath('curl')))
  else
    vim.health.warn(
      ('curl found at %s, but `curl --version` failed'):format(vim.fn.exepath('curl'))
    )
  end
end

---@param resolved shortcut.auth.Result
---@return string
local function describe_source(resolved)
  local auth = require('shortcut.auth')
  if resolved.source == 'setup' then
    return 'the `token` option of setup()'
  elseif resolved.source == 'env' then
    local name = auth.env_var(resolved)
    return name and ('$' .. name) or 'the environment'
  end
  return 'the `short` CLI config ' .. auth.cli_config_path()
end

---@param token string
local function check_token_works(token)
  local http = require('shortcut.http')
  local done, err, data = false, nil, nil
  local handle = http.request(
    { path = '/member', token = token, timeout = M.TOKEN_CHECK_TIMEOUT, retry = false },
    function(e, d)
      done, err, data = true, e, d
    end
  )
  vim.wait((M.TOKEN_CHECK_TIMEOUT + 2) * 1000, function()
    return done
  end, 50)
  if not done then
    handle:cancel()
    vim.health.error('GET /member did not answer in time')
    return
  end
  if err then
    local advice = err.status == 401
        and { 'Create a new token and run :Shortcut login, or update your configuration.' }
      or nil
    vim.health.error('the token does not work: ' .. http.format_error(err), advice)
    return
  end
  local identity, parse_err = http.parse_identity(data)
  if not identity then
    vim.health.warn(('the token works, but %s'):format(parse_err))
    return
  end
  vim.health.ok(
    ('the token works: @%s in workspace %s'):format(identity.mention_name, identity.url_slug)
  )
end

local function check_token()
  local auth = require('shortcut.auth')
  local resolved, err = auth.resolve()
  if not resolved then
    vim.health.error('no usable API token', { err })
    return
  end
  vim.health.ok(
    ('token %s from %s'):format(auth.redacted(resolved.token), describe_source(resolved))
  )
  if resolved.mention_name and resolved.url_slug then
    vim.health.info(
      ('saved identity: @%s in workspace %s'):format(resolved.mention_name, resolved.url_slug)
    )
  end
  check_token_works(resolved.token)
end

local function check_snacks()
  local found = package.loaded['snacks'] ~= nil
    or #vim.api.nvim_get_runtime_file('lua/snacks/init.lua', false) > 0
  if found then
    vim.health.ok('snacks.nvim is installed: its picker is used')
  else
    vim.health.warn('snacks.nvim not found: pickers fall back to vim.ui.select', {
      'Install folke/snacks.nvim for live search with previews (optional).',
    })
  end
end

function M.check()
  vim.health.start('shortcut.nvim')
  check_neovim()
  check_curl()

  vim.health.start('API token')
  check_token()

  vim.health.start('Optional dependencies')
  check_snacks()
end

return M

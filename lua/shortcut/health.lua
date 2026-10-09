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
---@return string? url_slug The token's workspace, if the check got that far.
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
  return identity.url_slug
end

---@return string? url_slug The token's workspace, if known.
local function check_token()
  local auth = require('shortcut.auth')
  local resolved, err = auth.resolve()
  if not resolved then
    vim.health.error('no usable API token', { err })
    return nil
  end
  vim.health.ok(
    ('token %s from %s'):format(auth.redacted(resolved.token), describe_source(resolved))
  )
  if resolved.mention_name and resolved.url_slug then
    vim.health.info(
      ('saved identity: @%s in workspace %s'):format(resolved.mention_name, resolved.url_slug)
    )
  end
  return check_token_works(resolved.token) or resolved.url_slug
end

--- `3m`, `5h`, `2d`.
---@param seconds integer
---@return string
local function age(seconds)
  if seconds < 60 then
    return 'just now'
  elseif seconds < 3600 then
    return ('%dm ago'):format(math.floor(seconds / 60))
  elseif seconds < 86400 then
    return ('%dh ago'):format(math.floor(seconds / 3600))
  end
  return ('%dd ago'):format(math.floor(seconds / 86400))
end

---@param current_slug? string
local function check_cache(current_slug)
  local cache = require('shortcut.cache')
  vim.health.info('location: ' .. cache.root())
  local workspaces = cache.disk_info()
  if #workspaces == 0 then
    vim.health.info('nothing cached yet')
    return
  end
  local ttl = require('shortcut.config').get().cache.ttl
  local now = cache._now()
  for _, ws in ipairs(workspaces) do
    local label = ('workspace %s%s'):format(
      ws.slug,
      current_slug and ws.slug == current_slug:lower() and ' (current)' or ''
    )
    if not ws.lists then
      vim.health.warn(('%s: unreadable or corrupt, will be replaced: %s'):format(label, ws.path))
    else
      local lines = {}
      for _, kind in ipairs(cache.KINDS) do
        local list = ws.lists[kind]
        if list then
          local seconds = now - list.fetched_at
          table.insert(
            lines,
            ('%s: %d %s, fetched %s%s'):format(
              kind,
              list.count,
              list.count == 1 and 'entry' or 'entries',
              age(math.max(seconds, 0)),
              (seconds >= ttl or seconds < 0) and ' (expired)' or ''
            )
          )
        else
          table.insert(lines, kind .. ': not cached')
        end
      end
      vim.health.ok(('%s: %s\n%s'):format(label, ws.path, table.concat(lines, '\n')))
    end
  end
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

local function check_git()
  if vim.fn.executable('git') == 1 then
    vim.health.ok(
      ('git (%s): the current story can come from the git branch'):format(vim.fn.exepath('git'))
    )
  else
    vim.health.warn('git not found: the current story cannot come from the git branch', {
      'Install git to use :Shortcut story (and comment, state, ...) without an argument.',
    })
  end
end

local function check_routing()
  local status = require('shortcut.buffer.handlers').status()
  local enabled = require('shortcut.config').get().sc_ids
  if status.sc_ids then
    vim.health.ok('`:e sc-<id>` opens stories and epics (sc_ids = true)')
  elseif enabled then
    vim.health.warn('sc_ids = true, but the sc-<id> handler is not registered', {
      "Call require('shortcut').setup() again, or restart Neovim.",
    })
  else
    vim.health.info('`:e sc-<id>` is turned off (sc_ids = false)')
  end

  if status.net == 'guarded' then
    vim.health.ok("Neovim's built-in https:// handler skips Shortcut story and epic links")
  elseif status.net == 'absent' then
    vim.health.ok("Neovim's built-in https:// handler is not loaded: nothing to skip")
  else
    vim.health.warn(
      "Neovim's built-in https:// handler would download Shortcut links as web pages",
      {
        'It was set up after shortcut.nvim guarded it. Run '
          .. ":lua require('shortcut.buffer.handlers').guard_net_plugin(), and report this.",
      }
    )
  end

  if status.includeexpr == 'global' then
    vim.health.ok("`gf` on sc-<id> works in buffers without their own 'includeexpr'")
  else
    vim.health.info(
      (
        "the global 'includeexpr' is set elsewhere (%s): `gf` on sc-<id> works where it is "
        .. "chained (gitcommit buffers, or require('shortcut').chain_includeexpr() in "
        .. 'after/ftplugin/<filetype>.lua)'
      ):format(vim.go.includeexpr == '' and 'empty' or vim.go.includeexpr)
    )
  end
end

function M.check()
  vim.health.start('shortcut.nvim')
  check_neovim()
  check_curl()

  vim.health.start('API token')
  local slug = check_token()

  vim.health.start('Lookup-list cache')
  check_cache(slug)

  vim.health.start('Opening links and sc-<id>')
  check_routing()

  vim.health.start('Optional dependencies')
  check_snacks()
  check_git()
end

return M

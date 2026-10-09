--- `:Shortcut login`: check an API token and save it to the `short` CLI's config file.
local async = require('shortcut.async')
local auth = require('shortcut.auth')
local commands = require('shortcut.commands')
local http = require('shortcut.http')
local notify = require('shortcut.notify')

local M = {}

--- What supplies the token in use, if not the `short` config.
---@param resolved shortcut.auth.Result
---@return string?
local function overriding_source(resolved)
  if resolved.source == 'setup' then
    return 'the `token` passed to setup()'
  elseif resolved.source == 'env' then
    return ('$%s'):format(auth.env_var(resolved) or 'SHORTCUT_API_TOKEN')
  end
  return nil
end

---@param v any
---@return string?
local function nonempty(v)
  if type(v) == 'string' and vim.trim(v) ~= '' then
    return vim.trim(v)
  end
  return nil
end

--- The workspace the stored token belongs to: from the file, or else by asking the API. Must
--- run inside `async.run()`.
---@param existing table
---@param old_token string
---@return string? slug
---@return boolean rejected `true` if the API rejected the stored token (HTTP 401).
---@return string? why Why the workspace is unknown, if it is.
local function stored_workspace(existing, old_token)
  local slug = nonempty(existing.urlSlug)
  if slug then
    return slug, false
  end
  local err, data =
    async.await(http.request, { path = '/member', token = old_token, retry = false })
  if err then
    return nil, err.status == 401, http.format_error(err)
  end
  local identity, parse_err = http.parse_identity(data)
  return identity and identity.url_slug, false, parse_err
end

---@param msg string
---@return boolean
local function confirm(msg)
  return vim.fn.confirm(msg, '&Replace\n&Cancel', 2) == 1
end

--- Check `token` and, if it works, save it. Must run inside `async.run()`.
---@param token string
local function save(token)
  local err, data = async.await(http.request, { path = '/member', token = token })
  if err then
    notify.error('login failed: ' .. http.format_error(err) .. '\nNothing was saved.')
    return
  end
  local identity, parse_err = http.parse_identity(data)
  if not identity then
    notify.error(('login failed: %s\nNothing was saved.'):format(parse_err))
    return
  end

  local existing, read_err = auth.read_cli_config()
  if read_err then
    notify.error(('login failed: %s\nNothing was saved.'):format(read_err))
    return
  end
  local old_token = existing and nonempty(existing.token)
  if existing and old_token and old_token ~= token then
    local old_slug, rejected, why = stored_workspace(existing, old_token)
    local question
    if old_slug and old_slug:lower() ~= identity.url_slug:lower() then
      question = ("The saved token is for workspace '%s'; this one is for '%s'. Replace it?"):format(
        old_slug,
        identity.url_slug
      )
    elseif not old_slug and not rejected then
      -- Unknown (e.g. offline): it may be another workspace's. Only a token the API rejected
      -- is safe to replace without asking.
      question = ("Cannot tell which workspace the saved token is for (%s). Replace it with this one for '%s'?"):format(
        why or 'unknown error',
        identity.url_slug
      )
    end
    if question and not confirm(question) then
      notify.info('login cancelled; the saved token was kept')
      return
    end
  end

  local ok, write_err = auth.write_cli_config({
    token = token,
    mentionName = identity.mention_name,
    urlSlug = identity.url_slug,
  })
  if not ok then
    notify.error(('login failed: %s'):format(write_err))
    return
  end
  auth.reset()
  notify.info(('Logged in as @%s (%s)'):format(identity.mention_name, identity.url_slug))

  local resolved = auth.resolve()
  local source = resolved and overriding_source(resolved)
  if source then
    notify.warn(
      ('the token was saved to %s, but %s takes precedence over it'):format(
        auth.cli_config_path(),
        source
      )
    )
  end
end

--- Run `:Shortcut login`.
---@return shortcut.async.Task?
function M.login()
  local ok, input = pcall(vim.fn.inputsecret, 'Shortcut API token: ')
  -- Clear the prompt line; the input is not echoed anyway.
  vim.cmd('redraw')
  local token = ok and type(input) == 'string' and vim.trim(input) or ''
  if token == '' then
    notify.warn('login cancelled')
    return
  end
  return async.run(function()
    save(token)
  end)
end

commands.register('login', {
  desc = 'Save an API token to the shared `short` CLI config',
  run = function()
    M.login()
  end,
})

return M

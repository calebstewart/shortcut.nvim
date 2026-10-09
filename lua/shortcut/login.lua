--- `:Shortcut login`: check an API token and save it to the `short` CLI's config file.
local async = require('shortcut.async')
local auth = require('shortcut.auth')
local commands = require('shortcut.commands')
local http = require('shortcut.http')
local notify = require('shortcut.notify')

local M = {}

local SOURCES = {
  setup = 'the `token` passed to setup()',
  env = 'the token in the environment ($SHORTCUT_API_TOKEN)',
}

---@param v any
---@return string?
local function nonempty(v)
  if type(v) == 'string' and vim.trim(v) ~= '' then
    return vim.trim(v)
  end
  return nil
end

--- The workspace the stored token belongs to, if it can be told: from the file, or else by
--- asking the API. Must run inside `async.run()`.
---@param existing table
---@param old_token string
---@return string?
local function stored_workspace(existing, old_token)
  local slug = nonempty(existing.urlSlug)
  if slug then
    return slug
  end
  local err, data =
    async.await(http.request, { path = '/member', token = old_token, retry = false })
  if err then
    return nil
  end
  local identity = http.parse_identity(data)
  return identity and identity.url_slug
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
    local old_slug = stored_workspace(existing, old_token)
    if old_slug and old_slug:lower() ~= identity.url_slug:lower() then
      local choice = vim.fn.confirm(
        ("The saved token is for workspace '%s'; this one is for '%s'. Replace it?"):format(
          old_slug,
          identity.url_slug
        ),
        '&Replace\n&Cancel',
        2
      )
      if choice ~= 1 then
        notify.info('login cancelled; the saved token was kept')
        return
      end
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
  if resolved and SOURCES[resolved.source] then
    notify.warn(
      ('the token was saved to %s, but %s takes precedence over it'):format(
        auth.cli_config_path(),
        SOURCES[resolved.source]
      )
    )
  end
end

--- Run `:Shortcut login`.
function M.login()
  local ok, input = pcall(vim.fn.inputsecret, 'Shortcut API token: ')
  -- Clear the prompt line; the input is not echoed anyway.
  vim.cmd('redraw')
  local token = ok and type(input) == 'string' and vim.trim(input) or ''
  if token == '' then
    notify.warn('login cancelled')
    return
  end
  async.run(function()
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

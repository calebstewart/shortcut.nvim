--- API token resolution, and the config file shared with the `short` CLI (shortcut-cli).
---
--- The token is looked up in this order; the first match wins:
---   1. `token` passed to `setup()` (a string, or a function returning one),
---   2. the `SHORTCUT_API_TOKEN` (or legacy `CLUBHOUSE_API_TOKEN`) environment variable,
---   3. the `short` CLI's config file (`cli_config_path`, or the CLI's own default location).
---
--- The token must never appear in notifications, logs or error messages: use `M.redacted()`.
---
--- The CLI behaviour mirrored here comes from shortcut-cli's `src/lib/configure.ts`
--- (https://github.com/shortcut-cli/shortcut-cli/blob/ea582722a5b37d0ab755050f7354b6555845b6a1/src/lib/configure.ts):
---   - config dir: `$XDG_CONFIG_HOME/shortcut-cli`, else
---     `${XDG_DATA_HOME:-$HOME}/.config/shortcut-cli` (yes, `XDG_DATA_HOME`: that is what the
---     CLI does, and both tools must agree),
---   - config file: `<config dir>/config.json`, keys `token`, `mentionName`, `urlSlug`,
---     `workspaces`; an empty file counts as `{}`,
---   - legacy dirs `<config base>/clubhouse-cli` and `~/.clubhouse-cli`, which the CLI renames to
---     the config dir when it finds them,
---   - token env vars: `SHORTCUT_API_TOKEN`, then `CLUBHOUSE_API_TOKEN`; an empty value is unset.
---
--- The path is never derived from `stdpath()`: `NVIM_APPNAME` must not change where it is.
local config = require('shortcut.config')

local M = {}

--- Environment variables holding the token, in the order the CLI checks them.
M.ENV_VARS = { 'SHORTCUT_API_TOKEN', 'CLUBHOUSE_API_TOKEN' }

---@alias shortcut.auth.Source 'setup'|'env'|'cli_config'

---@class shortcut.auth.Result
---@field token string
---@field source shortcut.auth.Source
---@field mention_name? string Only set when the CLI config's token is the resolved token.
---@field url_slug? string Only set when the CLI config's token is the resolved token.

---@class shortcut.auth.CliPaths
---@field file string The config file to read and write.
---@field legacy_dirs string[] Old config dirs the CLI migrates from (empty for an override).

--- Resolved result, and the configuration table it was resolved with. `setup()` replaces that
--- table, which invalidates the cache.
---@type shortcut.auth.Result?
local cache = nil
---@type shortcut.Config?
local cache_config = nil

---@param p string
---@return string
local function absolute(p)
  return vim.fs.normalize(vim.fs.abspath(p))
end

---@param name string
---@return string?
local function env(name)
  -- Not `vim.env`: it goes through `vim.fn`, which fails in fast (libuv callback) contexts.
  local v = vim.uv.os_getenv(name)
  if v == nil or v == '' then
    return nil
  end
  return v
end

--- Mirrors `getConfigDir()` in shortcut-cli's configure.ts.
---@param suffix string
---@return string
local function cli_config_dir(suffix)
  local base = env('XDG_CONFIG_HOME')
    or vim.fs.joinpath(env('XDG_DATA_HOME') or vim.uv.os_homedir() or '~', '.config')
  return absolute(vim.fs.joinpath(base, suffix))
end

---@return shortcut.auth.CliPaths
local function cli_paths()
  local override = config.get().cli_config_path
  if override then
    return { file = absolute(vim.fs.normalize(override)), legacy_dirs = {} }
  end
  return {
    file = vim.fs.joinpath(cli_config_dir('shortcut-cli'), 'config.json'),
    legacy_dirs = {
      cli_config_dir('clubhouse-cli'),
      absolute(vim.fs.joinpath(vim.uv.os_homedir() or '~', '.clubhouse-cli')),
    },
  }
end

--- The `short` CLI config file: `cli_config_path` if set, otherwise the CLI's default location.
---@return string
function M.cli_config_path()
  return cli_paths().file
end

---@param path string
---@return boolean
local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

---@param path string
---@param err? string
---@return string
local function unreadable(path, err)
  return (
    'cannot read %s: %s. Make sure your user owns it and can read it (e.g. `chmod 600 %s`), '
    .. 'or set $SHORTCUT_API_TOKEN instead.'
  ):format(path, err or 'unknown error', path)
end

--- Read and decode a CLI config file.
---@param path string
---@return table? data `nil` with no error if the file does not exist.
---@return string? err
local function read_json(path)
  local fd, open_err, code = vim.uv.fs_open(path, 'r', 0)
  if not fd then
    if code == 'ENOENT' then
      return nil
    end
    return nil, unreadable(path, open_err)
  end
  local stat = vim.uv.fs_fstat(fd)
  local data, read_err = vim.uv.fs_read(fd, stat and stat.size or 0, 0)
  vim.uv.fs_close(fd)
  if not data then
    return nil, unreadable(path, read_err)
  end

  data = vim.trim(data)
  if data == '' then
    return {}
  end
  -- Do not include the decoder's message: it can quote the file's contents, i.e. the token.
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= 'table' or (vim.islist(decoded) and next(decoded) ~= nil) then
    return nil,
      ('%s is not a valid JSON object. Fix or delete it, then run `short install`.'):format(path)
  end
  return decoded
end

--- Read the CLI config, falling back to a legacy location (read-only) the CLI has not migrated
--- yet.
---@return table? data
---@return string? err
---@return string path The file that was (or would have been) read.
local function read_cli_config()
  local paths = cli_paths()
  if not exists(paths.file) then
    for _, dir in ipairs(paths.legacy_dirs) do
      local legacy = vim.fs.joinpath(dir, 'config.json')
      if exists(legacy) then
        local data, err = read_json(legacy)
        return data, err, legacy
      end
    end
  end
  local data, err = read_json(paths.file)
  return data, err, paths.file
end

--- The contents of the `short` CLI config file (or the legacy file it would be migrated from).
--- Contains the stored token: never display it.
---@return table? data `nil` with no error if there is no file.
---@return string? err
function M.read_cli_config()
  local data, err = read_cli_config()
  return data, err
end

---@param v any
---@return string?
local function nonempty_string(v)
  if type(v) == 'string' and vim.trim(v) ~= '' then
    return vim.trim(v)
  end
  return nil
end

---@param path string
---@return string
local function missing_token_message(path)
  return table.concat({
    'no Shortcut API token found. Do one of:',
    ('- run `short install` (shortcut-cli), which saves it to %s'):format(path),
    '- run :Shortcut login',
    '- set $SHORTCUT_API_TOKEN',
    "- pass `token` to require('shortcut').setup()",
  }, '\n')
end

---@return string? token
---@return string? err
local function token_from_setup()
  local t = config.get().token
  if type(t) == 'function' then
    local ok, result = pcall(t)
    if not ok then
      -- Keep only the first line: no traceback.
      local msg = vim.split(tostring(result), '\n', { plain = true })[1]
      return nil, ('the `token` function passed to setup() failed: %s'):format(msg)
    end
    local token = nonempty_string(result)
    if not token then
      return nil,
        ('the `token` function passed to setup() returned %s instead of a non-empty string'):format(
          type(result) == 'string' and 'an empty string' or type(result)
        )
    end
    return token
  end
  return nonempty_string(t)
end

---@return shortcut.auth.Result? result
---@return string? err
local function do_resolve()
  local token, err = token_from_setup()
  if err then
    return nil, err
  end
  ---@type shortcut.auth.Source?
  local source = token and 'setup' or nil

  if not token then
    for _, name in ipairs(M.ENV_VARS) do
      token = nonempty_string(env(name))
      if token then
        source = 'env'
        break
      end
    end
  end

  local file, file_err, path = read_cli_config()
  if not token then
    if file_err then
      return nil, file_err
    end
    token = file and nonempty_string(file.token)
    if not token then
      return nil, missing_token_message(path)
    end
    source = 'cli_config'
  end
  ---@cast source shortcut.auth.Source

  ---@type shortcut.auth.Result
  local result = { token = token, source = source }
  -- The file's identity belongs to the file's token: a token from setup() or the environment
  -- may be for another workspace. The HTTP client fills these in from `GET /member` otherwise.
  if file and nonempty_string(file.token) == token then
    result.mention_name = nonempty_string(file.mentionName)
    result.url_slug = nonempty_string(file.urlSlug)
  end
  return result
end

--- Find the API token and, when known, the user's identity. The result is cached for the
--- session (until `reset()` or the next `setup()`).
---@return shortcut.auth.Result? result
---@return string? err An actionable message that never contains the token.
function M.resolve()
  local cfg = config.get()
  if not (cache and cache_config == cfg) then
    local result, err = do_resolve()
    if not result then
      return nil, err
    end
    cache, cache_config = result, cfg
  end
  ---@type shortcut.auth.Result
  local copy = vim.deepcopy(cache)
  return copy
end

--- The environment variable a token resolved from the environment came from.
---@param result shortcut.auth.Result
---@return string? name E.g. `SHORTCUT_API_TOKEN`; `nil` unless `result.source` is `'env'`.
function M.env_var(result)
  if result.source ~= 'env' then
    return nil
  end
  for _, name in ipairs(M.ENV_VARS) do
    if nonempty_string(env(name)) == result.token then
      return name
    end
  end
  return nil
end

--- Forget the resolved token, so the next `resolve()` looks it up again.
function M.reset()
  cache, cache_config = nil, nil
end

--- A token safe to display: only its last four characters, e.g. `****abcd`.
---@param token? string
---@return string
function M.redacted(token)
  if type(token) ~= 'string' or #token < 12 then
    return '****'
  end
  return '****' .. token:sub(-4)
end

--- Create `dir` and any missing parents. Uses libuv only, so it works in fast contexts.
---@param dir string
---@param mode integer Mode of `dir` itself; created parents get 0755 (less the umask).
---@return boolean ok
---@return string? err
local function mkdir_p(dir, mode)
  if exists(dir) then
    return true
  end
  local parent = vim.fs.dirname(dir)
  if parent ~= dir then
    local ok, err = mkdir_p(parent, tonumber('755', 8))
    if not ok then
      return false, err
    end
  end
  local ok, err, code = vim.uv.fs_mkdir(dir, mode)
  if not ok and code ~= 'EEXIST' then
    return false, ('cannot create %s: %s'):format(dir, err)
  end
  return true
end

--- Move a legacy CLI config dir into place, as the CLI itself does on startup, when the config
--- file does not exist yet. `resolve()` reads the legacy file in that case, so writing a new file
--- instead would both lose its other keys and make the CLI's own migration (a rename onto the
--- config dir) fail.
---@param paths shortcut.auth.CliPaths
---@return boolean ok
---@return string? err
local function migrate_legacy(paths)
  if exists(paths.file) then
    return true
  end
  local dir = vim.fs.dirname(paths.file)
  for _, legacy in ipairs(paths.legacy_dirs) do
    if exists(legacy) then
      if exists(dir) then
        -- Like the CLI's rename, this only works onto an empty directory.
        local removed, rm_err, code = vim.uv.fs_rmdir(dir)
        if not removed then
          local reason = (code == 'ENOTEMPTY' or code == 'EEXIST')
              and 'it already exists and is not empty'
            or rm_err
            or 'unknown error'
          return false,
            (
              'cannot move the legacy short config %s to %s: %s. '
              .. 'Move %s into %s yourself, then try again.'
            ):format(legacy, dir, reason, vim.fs.joinpath(legacy, 'config.json'), dir)
        end
      else
        local ok, err = mkdir_p(vim.fs.dirname(dir), tonumber('755', 8))
        if not ok then
          return false, err
        end
      end
      local ok, err = vim.uv.fs_rename(legacy, dir)
      if not ok then
        return false, ('cannot move %s to %s: %s'):format(legacy, dir, err)
      end
      return true
    end
  end
  return true
end

---@param path string
---@param data string
---@return boolean ok
---@return string? err
local function write_atomic(path, data)
  local dir = vim.fs.dirname(path)
  local tmp = ('%s/.%s.%d.%d.tmp'):format(
    dir,
    vim.fs.basename(path),
    vim.uv.os_getpid(),
    vim.uv.hrtime()
  )
  local fd, err = vim.uv.fs_open(tmp, 'wx', tonumber('600', 8))
  if not fd then
    return false, ('cannot write %s: %s'):format(tmp, err)
  end
  local written, write_err = vim.uv.fs_write(fd, data, 0)
  ---@type boolean?
  local ok = written == #data
  if ok then
    ok, write_err = vim.uv.fs_fsync(fd)
  end
  if ok then
    -- The mode given to open() is reduced by the umask; make it exactly 0600.
    ok, write_err = vim.uv.fs_fchmod(fd, tonumber('600', 8))
  end
  vim.uv.fs_close(fd)
  if ok then
    ok, write_err = vim.uv.fs_rename(tmp, path)
  end
  if not ok then
    write_err = write_err or 'short write'
    vim.uv.fs_unlink(tmp)
    return false, ('cannot write %s: %s'):format(path, write_err)
  end
  return true
end

--- Merge `fields` into the `short` CLI config file, keeping every other key (notably
--- `workspaces`). Creates the directory if needed, writes atomically (temp file + rename in the
--- same directory) and leaves the file with mode 0600. Used by `:Shortcut login` only.
---@param fields { token?: string, mentionName?: string, urlSlug?: string }|table<string, any>
---@return boolean? ok
---@return string? err Never contains the token.
function M.write_cli_config(fields)
  vim.validate('fields', fields, 'table')
  local paths = cli_paths()
  local ok, err = migrate_legacy(paths)
  if not ok then
    return nil, err
  end

  -- Write through a symlink (e.g. a dotfile manager's) rather than replacing it.
  local path = vim.uv.fs_realpath(paths.file) or paths.file
  local existing, read_err = read_json(path)
  if read_err then
    -- Refuse to overwrite a file we cannot parse: it would lose the user's data.
    return nil, read_err
  end
  local merged = vim.tbl_extend('force', existing or {}, fields)
  if next(merged) == nil then
    merged = vim.empty_dict() -- encode as `{}`, not `[]`
  end

  local dir = vim.fs.dirname(path)
  -- A new config dir only holds secrets: keep it private.
  ok, err = mkdir_p(dir, tonumber('700', 8))
  if not ok then
    return nil, err
  end
  ok, err = write_atomic(path, vim.json.encode(merged))
  if not ok then
    return nil, err
  end
  M.reset()
  return true
end

return M

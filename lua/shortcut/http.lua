--- Asynchronous client for the Shortcut REST API v3.
---
--- Requests run `curl` through `vim.system`. The API token is passed to curl on stdin as a curl
--- config file (`--config -`), together with the request body, so neither ever appears in curl's
--- command line (where `ps` would show it). curl's own `~/.curlrc` is ignored (`-q`).
---
--- Callbacks always run on the main loop, and never after the request was cancelled.
---
--- API facts (https://developer.shortcut.com/api/rest/v3, and its OpenAPI spec
--- https://developer.shortcut.com/api/rest/v3/shortcut.openapi.json):
---   - server `https://api.app.shortcut.com`, paths under `/api/v3`,
---   - authentication: the `Shortcut-Token` header,
---   - at most 200 requests per minute; above that the API answers 429,
---   - `GET /api/v3/member` (getCurrentMemberInfo) returns `MemberInfo`: `id`, `mention_name`,
---     `name`, `role`, `is_owner`, `workspace2` (`BasicWorkspaceInfo`: `url_slug`, `name`, ...)
---     and `organization2`.
---   - error bodies carry a `message` (and, for schema mismatches, `errors`).
local auth = require('shortcut.auth')
local config = require('shortcut.config')

local M = {}

M.BASE_URL = 'https://api.app.shortcut.com/api/v3'

--- Retries after a 429 (any method) or a network error (GET only).
M.MAX_RETRIES = 3

--- Longest wait honoured from a `Retry-After` header, in seconds.
local MAX_RETRY_AFTER = 60

---@alias shortcut.http.Method 'GET'|'POST'|'PUT'|'DELETE'

---@alias shortcut.http.QueryValue string|number|boolean|(string|number|boolean)[]

---@class shortcut.http.Request
---@field method? shortcut.http.Method Defaults to `GET`.
---@field path string Below the API base, e.g. `/member`.
---@field query? table<string, shortcut.http.QueryValue>
---@field body? table|string A table is encoded as JSON.
---@field token? string Use this token instead of the resolved one (`:Shortcut login`).
---@field timeout? integer Seconds; defaults to `config.http.timeout`.
---@field retry? boolean `false` disables retries. Default `true`.

---@alias shortcut.http.ErrorKind
---| 'http' # The API answered with a non-2xx status.
---| 'network' # curl failed (DNS, connection, TLS, timeout...): there is no status.
---| 'auth' # No usable token.
---| 'decode' # A 2xx response whose body is not valid JSON, or not what was expected.
---| 'invalid' # Not sent: the request's arguments are invalid (e.g. an empty search query).

---@class shortcut.http.Error
---@field kind shortcut.http.ErrorKind
---@field status? integer HTTP status; `nil` unless `kind` is `'http'` or `'decode'`.
---@field message string Readable; never contains the token.
---@field details? any Extra detail from the error body (e.g. Shortcut's `errors`).
---@field method string
---@field path string

---@class shortcut.http.Response
---@field status integer
---@field attempts integer Number of requests made, including retries.

--- What a transport is asked to do.
---@class shortcut.http.TransportRequest
---@field method shortcut.http.Method
---@field url string
---@field headers string[] `Name: value` lines. Contain the token: never log them.
---@field body? string
---@field timeout integer Seconds.

--- What a transport reports: either `status` (and `body`), or `error`.
---@class shortcut.http.TransportResult
---@field status? integer
---@field body? string
---@field retry_after? string Value of the `Retry-After` header, if any.
---@field error? string curl's error message when no response was received.
---@field timed_out? boolean

---@alias shortcut.http.Transport fun(req: shortcut.http.TransportRequest, done: fun(res: shortcut.http.TransportResult)): { cancel: fun() }?

---@class shortcut.http.Handle
---@field _cancelled boolean
---@field _cancel_current? fun() Stops whatever is in progress: the curl process or a retry timer.
local Handle = {}
Handle.__index = Handle

--- Stop the request (and any pending retry). The callback will not be called.
function Handle:cancel()
  if self._cancelled then
    return
  end
  self._cancelled = true
  if self._cancel_current then
    pcall(self._cancel_current)
    self._cancel_current = nil
  end
end

---@return boolean
function Handle:is_cancelled()
  return self._cancelled
end

---@return shortcut.http.Handle
local function new_handle()
  return setmetatable({ _cancelled = false }, Handle)
end

---------------------------------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------------------------------

--- Percent-encode everything but RFC 3986 unreserved characters.
---@param s string
---@return string
function M.encode_component(s)
  return (s:gsub('[^%w%-%._~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

---@param v string|number|boolean
---@return string
local function scalar(v)
  if type(v) == 'boolean' then
    return v and 'true' or 'false'
  end
  return tostring(v)
end

--- Encode a query table. Keys are sorted; a list value repeats its key.
---@param query? table<string, shortcut.http.QueryValue>
---@return string # Without the leading `?`; empty if there is nothing to encode.
function M.encode_query(query)
  if not query then
    return ''
  end
  local keys = vim.tbl_keys(query)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = query[k]
    ---@type (string|number|boolean)[]
    local values = type(v) == 'table' and v or { v }
    for _, item in ipairs(values) do
      table.insert(
        parts,
        M.encode_component(tostring(k)) .. '=' .. M.encode_component(scalar(item))
      )
    end
  end
  return table.concat(parts, '&')
end

--- Quote a value for a curl config file: inside double quotes, curl understands `\\`, `\"`,
--- `\t`, `\n`, `\r` and `\v`.
---@param s string
---@return string
local function curl_quote(s)
  local escaped = s:gsub('[\\"\t\n\r\v]', {
    ['\\'] = '\\\\',
    ['"'] = '\\"',
    ['\t'] = '\\t',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\v'] = '\\v',
  })
  return '"' .. escaped .. '"'
end

---------------------------------------------------------------------------------------------------
-- curl transport
---------------------------------------------------------------------------------------------------

--- The curl command line and the config fed to it on stdin. Secrets (headers, body) only go to
--- stdin.
---@param req shortcut.http.TransportRequest
---@param marker string Separates the body from the status line in curl's output.
---@return string[] cmd
---@return string stdin
function M._curl_command(req, marker)
  local cmd = {
    'curl',
    '-q', -- must come first: ignore ~/.curlrc, which could change the output format
    '--silent',
    '--show-error',
    '--config',
    '-',
    '--max-time',
    tostring(req.timeout),
    '--request',
    req.method,
    '--write-out',
    '\n' .. marker .. '%{http_code} %header{retry-after}',
    -- Never expand `{a,b}` or `[1-3]` in the URL into several requests.
    '--globoff',
    '--url',
    req.url,
  }
  local lines = {}
  for _, h in ipairs(req.headers) do
    table.insert(lines, 'header = ' .. curl_quote(h))
  end
  if req.body then
    -- `data-raw`, not `data`: a body starting with `@` must not name a file to upload.
    table.insert(lines, 'data-raw = ' .. curl_quote(req.body))
  end
  return cmd, table.concat(lines, '\n') .. '\n'
end

--- Parse curl's output (`body`, newline, marker, `<status> <retry-after>`).
---@param stdout string
---@param marker string
---@return shortcut.http.TransportResult?
function M._parse_curl_output(stdout, marker)
  local start
  local init = 1
  while true do
    local s = stdout:find('\n' .. marker, init, true)
    if not s then
      break
    end
    start, init = s, s + 1
  end
  if not start then
    return nil
  end
  local body = stdout:sub(1, start - 1)
  local trailer = stdout:sub(start + 1 + #marker)
  local status, retry_after = trailer:match('^(%d+) ?(.-)%s*$')
  status = tonumber(status)
  if not status or status == 0 then
    return nil
  end
  return { status = status, body = body, retry_after = retry_after ~= '' and retry_after or nil }
end

---@param stderr? string
---@param code integer
---@return string
local function curl_error(stderr, code)
  -- curl: (6) Could not resolve host: ...  ->  keep the last meaningful line, without the
  -- prefix. Option errors end with a "curl: try 'curl --help' ..." hint: skip it.
  local msg = ''
  local lines = vim.split(vim.trim(stderr or ''), '\n', { trimempty = true })
  for i = #lines, 1, -1 do
    local line = vim.trim(lines[i])
    if not line:find('^curl: try ') then
      msg = line:gsub('^curl: ', '')
      break
    end
  end
  if msg == '' then
    msg = ('curl exited with code %d'):format(code)
  end
  return msg
end

--- The default transport: curl via `vim.system`.
---@type shortcut.http.Transport
local function curl_transport(req, done)
  local marker = ('__SHORTCUT_NVIM_%08x%08x__'):format(
    math.random(0, 0x7fffffff),
    math.random(0, 0x7fffffff)
  )
  local cmd, stdin = M._curl_command(req, marker)
  local ok, proc = pcall(vim.system, cmd, {
    stdin = stdin,
    text = true,
    -- A backstop: curl's own --max-time should fire first.
    timeout = (req.timeout + 5) * 1000,
  }, function(res)
    if res.code ~= 0 then
      done({
        error = res.code == 124 and 'request timed out' or curl_error(res.stderr, res.code),
        timed_out = res.code == 28 or res.code == 124,
      })
      return
    end
    local parsed = M._parse_curl_output(res.stdout or '', marker)
    done(parsed or { error = curl_error(res.stderr, res.code) .. ' (no HTTP response)' })
  end)
  if not ok then
    -- E.g. curl is not installed.
    done({ error = ('cannot run curl: %s'):format(tostring(proc)) })
    return nil
  end
  return {
    cancel = function()
      proc:kill('sigterm')
    end,
  }
end

---@type shortcut.http.Transport
local transport = curl_transport

--- Replace the transport (for tests). `nil` restores curl.
---@param fn? shortcut.http.Transport
function M._set_transport(fn)
  vim.validate('fn', fn, 'function', true)
  transport = fn or curl_transport
end

---------------------------------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------------------------------

--- Delay before retry number `attempt` (1-based), in milliseconds: `Retry-After` when it is a
--- number of seconds, otherwise exponential backoff (1s, 2s, 4s) plus up to 25% jitter.
---@param attempt integer
---@param retry_after? string
---@return integer
function M._delay(attempt, retry_after)
  local seconds = tonumber(retry_after)
  if seconds and seconds >= 0 then
    return math.floor(math.min(seconds, MAX_RETRY_AFTER) * 1000)
  end
  local base = 1000 * 2 ^ (attempt - 1)
  return math.floor(base + math.random(0, math.floor(base / 4)))
end

---@param body? string
---@return any data
---@return boolean? invalid `true` if `body` is not valid JSON.
local function decode(body)
  if not body or vim.trim(body) == '' then
    return nil
  end
  local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok then
    return nil, true
  end
  return data
end

local REASONS = {
  [400] = 'bad request',
  [401] = 'unauthorized: the API token is invalid or has been revoked',
  [403] = 'forbidden: the API token cannot access this',
  [404] = 'not found',
  [409] = 'conflict',
  [422] = 'unprocessable request',
  [429] = 'rate limited: too many requests',
}

---@param status integer
---@param body? string
---@return string message
---@return any details
local function http_error_message(status, body)
  local data = decode(body)
  local message, details
  if type(data) == 'table' then
    if type(data.message) == 'string' and data.message ~= '' then
      message = data.message
    end
    if data.errors ~= nil then
      details = data.errors
      if not message and type(data.errors) == 'string' then
        message = data.errors
      end
    end
  end
  if status == 401 then
    -- The body for an invalid token is not helpful on its own.
    message = message and (REASONS[401] .. ' (' .. message .. ')') or REASONS[401]
  end
  message = message or REASONS[status] or (status >= 500 and 'server error') or 'request failed'
  return message, details
end

--- A one-line description of an error, e.g. `GET /member: HTTP 404: not found`.
---@param err shortcut.http.Error|string
---@return string
function M.format_error(err)
  if type(err) ~= 'table' then
    return tostring(err)
  end
  local where = ('%s %s'):format(err.method or '?', err.path or '?')
  if err.status then
    return ('%s: HTTP %d: %s'):format(where, err.status, err.message)
  end
  return ('%s: %s'):format(where, err.message)
end

--- Fail a request without sending it: `callback(err)` runs on the main loop (never
--- synchronously), unless the returned handle is cancelled first. For API wrappers that reject
--- invalid arguments the way a failed request would be reported.
---@param method shortcut.http.Method
---@param path string
---@param message string
---@param callback fun(err?: shortcut.http.Error, data?: any, response?: shortcut.http.Response)
---@return shortcut.http.Handle
function M.reject(method, path, message, callback)
  local handle = new_handle()
  ---@type shortcut.http.Error
  local err = { kind = 'invalid', message = message, method = method, path = path }
  vim.schedule(function()
    if not handle._cancelled then
      callback(err)
    end
  end)
  return handle
end

---@param s string
---@return boolean
local function has_control_chars(s)
  return s:find('%c') ~= nil
end

--- Make an API request. `callback(err, data, response)` runs on the main loop: `err` is a
--- `shortcut.http.Error` or `nil`, `data` the decoded JSON (`nil` for 204 / an empty body).
---@param req shortcut.http.Request
---@param callback fun(err?: shortcut.http.Error, data?: any, response?: shortcut.http.Response)
---@return shortcut.http.Handle
function M.request(req, callback)
  vim.validate('req', req, 'table')
  vim.validate('req.path', req.path, function(p)
    return type(p) == 'string' and p:sub(1, 1) == '/'
  end, 'string starting with /')
  vim.validate('req.body', req.body, { 'table', 'string' }, true)
  -- curl's config reader stops at NUL; JSON-encoded tables never contain a raw one. A fixed
  -- message: the body (e.g. a whole description) must not end up in the error.
  local raw = req.body
  if type(raw) == 'string' and raw:find('\0', 1, true) then
    error('request body must not contain NUL bytes', 2)
  end
  vim.validate('callback', callback, 'function')
  local method = (req.method or 'GET'):upper()
  local path = req.path
  local handle = new_handle()

  ---@param err? shortcut.http.Error
  ---@param data? any
  ---@param response? shortcut.http.Response
  local function finish(err, data, response)
    handle._cancel_current = nil
    vim.schedule(function()
      if not handle._cancelled then
        callback(err, data, response)
      end
    end)
  end

  ---@param kind shortcut.http.ErrorKind
  ---@param message string
  ---@param extra? table
  ---@return shortcut.http.Error
  local function make_error(kind, message, extra)
    return vim.tbl_extend(
      'force',
      { kind = kind, message = message, method = method, path = path },
      extra or {}
    )
  end

  local token = req.token
  if token == nil then
    local resolved, auth_err = auth.resolve()
    if not resolved then
      finish(make_error('auth', auth_err or 'no API token'))
      return handle
    end
    token = resolved.token
  end
  token = vim.trim(token)
  if token == '' or has_control_chars(token) then
    finish(make_error('auth', 'the API token is empty or contains invalid characters'))
    return handle
  end

  local body = req.body
  if type(body) == 'table' then
    body = vim.json.encode(body)
  end
  local headers = {
    'Shortcut-Token: ' .. token,
    'Accept: application/json',
  }
  if body then
    table.insert(headers, 'Content-Type: application/json')
  end
  local query = M.encode_query(req.query)
  ---@type shortcut.http.TransportRequest
  local treq = {
    method = method,
    url = M.BASE_URL .. path .. (query ~= '' and ('?' .. query) or ''),
    headers = headers,
    body = body,
    timeout = req.timeout or config.get().http.timeout,
  }
  local retry = req.retry ~= false

  local attempt ---@type fun(n: integer)

  ---@param n integer Retry number (1-based).
  ---@param retry_after? string
  local function schedule_retry(n, retry_after)
    local timer = assert(vim.uv.new_timer())
    handle._cancel_current = function()
      timer:stop()
      timer:close()
    end
    timer:start(M._delay(n, retry_after), 0, function()
      timer:stop()
      timer:close()
      handle._cancel_current = nil
      -- Timer callbacks are fast events: start the next attempt from the main loop.
      vim.schedule(function()
        if not handle._cancelled then
          attempt(n + 1)
        end
      end)
    end)
  end

  ---@param n integer Attempt number (1-based).
  attempt = function(n)
    local settled = false
    local ok, t = pcall(transport, treq, function(res)
      settled = true
      if handle._cancelled then
        return
      end
      local can_retry = retry and n <= M.MAX_RETRIES
      if res.status == nil then
        -- Repeating a GET is harmless; anything else may already have taken effect. A timeout
        -- already waited the full `http.timeout`, so it is not retried either.
        if can_retry and method == 'GET' and not res.timed_out then
          schedule_retry(n, nil)
          return
        end
        finish(make_error('network', res.error or 'request failed'))
        return
      end
      local status = res.status --[[@as integer]]
      if status == 429 and can_retry then
        schedule_retry(n, res.retry_after)
        return
      end
      ---@type shortcut.http.Response
      local response = { status = status, attempts = n }
      if status < 200 or status >= 300 then
        local message, details = http_error_message(status, res.body)
        finish(make_error('http', message, { status = status, details = details }), nil, response)
        return
      end
      if status == 204 then
        finish(nil, nil, response)
        return
      end
      local data, bad = decode(res.body)
      if bad then
        finish(
          make_error('decode', 'the response is not valid JSON', { status = status }),
          nil,
          response
        )
        return
      end
      finish(nil, data, response)
    end)
    if not ok then
      local msg = vim.split(tostring(t), '\n', { plain = true })[1]
      finish(make_error('network', ('transport failed: %s'):format(msg)))
      return
    end
    if t and not settled and not handle._cancelled then
      handle._cancel_current = t.cancel
    end
  end

  attempt(1)
  return handle
end

---------------------------------------------------------------------------------------------------
-- Identity
---------------------------------------------------------------------------------------------------

---@class shortcut.http.Identity
---@field id string Member UUID.
---@field mention_name string
---@field name? string Display name.
---@field url_slug string Workspace URL slug, as in `https://app.shortcut.com/<url_slug>/...`.
---@field workspace_name? string

---@param v any
---@return string?
local function str(v)
  if type(v) == 'string' and v ~= '' then
    return v
  end
  return nil
end

--- Extract the identity from a `GET /member` (`MemberInfo`) response.
---@param data any
---@return shortcut.http.Identity? identity
---@return string? err
function M.parse_identity(data)
  if type(data) ~= 'table' then
    return nil, 'unexpected response from GET /member'
  end
  local workspace = type(data.workspace2) == 'table' and data.workspace2 or {}
  -- `MemberInfo` has `mention_name` at the top level (unlike `Member`, which nests it in
  -- `profile`).
  local mention_name = str(data.mention_name)
  local url_slug = str(workspace.url_slug)
  if not mention_name or not url_slug then
    return nil, 'unexpected response from GET /member (no mention name or workspace slug)'
  end
  return {
    id = str(data.id) or '',
    mention_name = mention_name,
    name = str(data.name),
    url_slug = url_slug,
    workspace_name = str(workspace.name),
  }
end

--- How long a failed `whoami` (other than a rejected token) is remembered, in milliseconds.
M.WHOAMI_ERROR_TTL = 60 * 1000

---@class shortcut.http.WhoamiEntry
---@field identity? shortcut.http.Identity
---@field err? shortcut.http.Error
---@field expires? integer `vim.uv.now()` after which a failure is retried; `nil`: never.

--- `whoami` results per token, and callbacks waiting for a request in flight.
---@type table<string, shortcut.http.WhoamiEntry>
local whoami_cache = {}
---@type table<string, fun(err?: shortcut.http.Error, identity?: shortcut.http.Identity)[]>
local whoami_waiting = {}

--- The member the token belongs to (`GET /member`), cached for the session. A rejected token
--- (401) is remembered for the session too, other failures for `WHOAMI_ERROR_TTL`, so opening
--- links does not keep asking. `callback` runs on the main loop.
---@param callback fun(err?: shortcut.http.Error, identity?: shortcut.http.Identity)
function M.whoami(callback)
  local resolved, auth_err = auth.resolve()
  if not resolved then
    vim.schedule(function()
      callback({
        kind = 'auth',
        message = auth_err or 'no API token',
        method = 'GET',
        path = '/member',
      })
    end)
    return
  end
  local token = resolved.token
  local cached = whoami_cache[token] ---@type shortcut.http.WhoamiEntry?
  if cached and cached.expires and vim.uv.now() >= cached.expires then
    whoami_cache[token], cached = nil, nil
  end
  if cached then
    vim.schedule(function()
      callback(vim.deepcopy(cached.err), vim.deepcopy(cached.identity))
    end)
    return
  end
  if whoami_waiting[token] then
    table.insert(whoami_waiting[token], callback)
    return
  end
  whoami_waiting[token] = { callback }
  M.request({ path = '/member', token = token }, function(err, data)
    local identity, parse_err = nil, nil
    if not err then
      identity, parse_err = M.parse_identity(data)
      if not identity then
        err = { kind = 'decode', message = parse_err, method = 'GET', path = '/member' }
      end
    end
    if identity then
      whoami_cache[token] = { identity = identity }
    elseif err and err.status == 401 then
      whoami_cache[token] = { err = err }
    elseif err then
      whoami_cache[token] = { err = err, expires = vim.uv.now() + M.WHOAMI_ERROR_TTL }
    end
    local waiting = whoami_waiting[token] or {}
    whoami_waiting[token] = nil
    -- One failing callback must not keep the others from being called.
    for _, cb in ipairs(waiting) do
      local ok, cb_err = pcall(cb, vim.deepcopy(err), identity and vim.deepcopy(identity))
      if not ok then
        require('shortcut.notify').error(vim.split(tostring(cb_err), '\n', { plain = true })[1])
      end
    end
  end)
end

---@class shortcut.http.User
---@field mention_name string
---@field url_slug string

--- The user's mention name and workspace slug: from `auth.resolve()` when it knows them (the
--- `short` config's token is in use), otherwise from `whoami()`.
---@param callback fun(err?: shortcut.http.Error, user?: shortcut.http.User)
function M.user(callback)
  local resolved = auth.resolve()
  if resolved and resolved.mention_name and resolved.url_slug then
    local user = { mention_name = resolved.mention_name, url_slug = resolved.url_slug }
    vim.schedule(function()
      callback(nil, user)
    end)
    return
  end
  M.whoami(function(err, identity)
    if err or not identity then
      callback(err)
      return
    end
    callback(nil, {
      mention_name = resolved and resolved.mention_name or identity.mention_name,
      url_slug = resolved and resolved.url_slug or identity.url_slug,
    })
  end)
end

--- Forget cached identities (for tests).
function M._clear_cache()
  whoami_cache = {}
  whoami_waiting = {}
end

return M

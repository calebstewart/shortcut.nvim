local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local TOKEN = 'test-token-0000-1111-2222-3333wxyz'

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua(
        [[
        vim.env.SHORTCUT_API_TOKEN = ...
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        _G.http = require('shortcut.http')
        dofile('tests/fake_transport.lua')
      ]],
        { TOKEN }
      )
    end,
    post_once = child.stop,
  },
})

---@param req table
---@return table
local function request(req)
  return child.lua_get('_G.sync_request(...)', { req })
end

---@param responses table[]
local function respond(responses)
  child.lua('_G.responses = ...', { responses })
end

local function requests()
  return child.lua_get('_G.requests')
end

local function contains(list, value)
  return vim.tbl_contains(list, value)
end

T['request()'] = new_set()

T['request()']['decodes a JSON response'] = function()
  respond({ { status = 200, body = '{"id": 1, "name": "x", "nothing": null, "list": [1, 2]}' } })
  local r = request({ path = '/stories/1' })
  eq(r.err, nil)
  eq(r.data, { id = 1, name = 'x', list = { 1, 2 } })
  eq(r.resp, { status = 200, attempts = 1 })

  local req = requests()[1]
  eq(req.method, 'GET')
  eq(req.url, 'https://api.app.shortcut.com/api/v3/stories/1')
  eq(req.timeout, 30)
  eq(req.body, nil)
  eq(contains(req.headers, 'Shortcut-Token: ' .. TOKEN), true)
  eq(contains(req.headers, 'Accept: application/json'), true)
end

T['request()']['calls back on the main loop, never synchronously'] = function()
  respond({ { status = 200, body = '{}' } })
  eq(request({ path = '/member' }).fast, false)

  -- Even a transport that answers immediately does not call back before request() returns.
  child.lua([[
    require('shortcut.http')._set_transport(function(_, done) done({ status = 200, body = '{}' }) end)
    _G.order = {}
    require('shortcut.http').request({ path = '/x' }, function() table.insert(_G.order, 'callback') end)
    table.insert(_G.order, 'returned')
    vim.wait(1000, function() return #_G.order == 2 end)
  ]])
  eq(child.lua_get('_G.order'), { 'returned', 'callback' })
end

T['request()']['sends a JSON body with the method and timeout'] = function()
  child.lua([[require('shortcut').setup({ http = { timeout = 7 } })]])
  respond({ { status = 200, body = '{"id": 2}' } })
  local r = request({ method = 'put', path = '/stories/2', body = { name = 'new "name"' } })
  eq(r.data, { id = 2 })
  local req = requests()[1]
  eq(req.method, 'PUT')
  eq(vim.json.decode(req.body), { name = 'new "name"' })
  eq(req.timeout, 7)
  eq(contains(req.headers, 'Content-Type: application/json'), true)
end

T['request()']['returns nil for 204 No Content'] = function()
  respond({ { status = 204, body = '' } })
  local r = request({ method = 'DELETE', path = '/stories/3' })
  eq(r.err, nil)
  eq(r.data, nil)
  eq(r.resp.status, 204)
end

T['request()']['normalizes a Shortcut error body'] = function()
  respond({ { status = 400, fixture = 'error_schema_mismatch' } })
  local r = request({ method = 'POST', path = '/stories', body = {} })
  eq(r.err, {
    kind = 'http',
    status = 400,
    message = 'The request included invalid parameters.',
    details = { name = 'missing-required-key' },
    method = 'POST',
    path = '/stories',
  })
  eq(r.data, nil)
  eq(r.resp.status, 400)
  eq(
    child.lua_get('_G.http.format_error(...)', { r.err }),
    'POST /stories: HTTP 400: The request included invalid parameters.'
  )
end

T['request()']['explains an invalid token'] = function()
  respond({ { status = 401, body = '' } })
  local r = request({ path = '/member' })
  eq(r.err.status, 401)
  eq(r.err.message, 'unauthorized: the API token is invalid or has been revoked')
end

T['request()']['falls back to the status for a body that is not JSON'] = function()
  respond({ { status = 502, body = '<html>Bad gateway</html>' } })
  local r = request({ path = '/member' })
  eq(r.err.kind, 'http')
  eq(r.err.message, 'server error')
end

T['request()']['reports a 2xx body that is not JSON'] = function()
  respond({ { status = 200, body = 'not json' } })
  local r = request({ path = '/member' })
  eq(r.err.kind, 'decode')
  eq(r.err.status, 200)
end

T['request()']['reports a network failure without a status'] = function()
  respond({ { error = 'Could not resolve host: api.app.shortcut.com' } })
  local r = request({ method = 'POST', path = '/stories', body = {} })
  eq(r.err, {
    kind = 'network',
    message = 'Could not resolve host: api.app.shortcut.com',
    method = 'POST',
    path = '/stories',
  })
  eq(
    child.lua_get('_G.http.format_error(...)', { r.err }),
    'POST /stories: Could not resolve host: api.app.shortcut.com'
  )
end

T['request()']['reports a missing token without making a request'] = function()
  child.lua('vim.env.SHORTCUT_API_TOKEN = nil')
  local r = request({ path = '/member' })
  eq(r.err.kind, 'auth')
  eq(r.err.message:find('no Shortcut API token found', 1, true) ~= nil, true)
  eq(#requests(), 0)
end

T['request()']['uses an explicit token instead of the resolved one'] = function()
  respond({ { status = 200, body = '{}' } })
  request({ path = '/member', token = 'other-token-aaaa-bbbb-cccc' })
  eq(contains(requests()[1].headers, 'Shortcut-Token: other-token-aaaa-bbbb-cccc'), true)
end

T['request()']['rejects a path without a leading slash'] = function()
  expect.error(function()
    child.lua([[_G.http.request({ path = 'member' }, function() end)]])
  end, 'string starting with /')
end

T['request()']['rejects a string body containing NUL'] = function()
  -- curl's config reader would silently truncate it.
  expect.error(function()
    child.lua(
      [[_G.http.request({ method = 'POST', path = '/x', body = 'before\0after' }, function() end)]]
    )
  end, 'without NUL bytes')
  eq(#requests(), 0)
  -- A table is JSON-encoded, which escapes NUL.
  respond({ { status = 200, body = '{}' } })
  request({ method = 'POST', path = '/x', body = { s = 'a\0b' } })
  eq(requests()[1].body, '{"s":"a\\u0000b"}')
end

T['request()']['rejects a token with control characters'] = function()
  local r = request({ path = '/member', token = 'abc\r\nX-Evil: 1' })
  eq(r.err.kind, 'auth')
  eq(#requests(), 0)
end

T['request()']['reports a transport that raises an error'] = function()
  child.lua([[require('shortcut.http')._set_transport(function() error('boom\nstack') end)]])
  local r = request({ path = '/member' })
  eq(r.err.kind, 'network')
  eq(r.err.message:find('transport failed: ', 1, true) ~= nil, true)
  eq(r.err.message:find('\n', 1, true), nil)
end

T['query'] = new_set()

T['query']['percent-encodes search syntax'] = function()
  respond({ { status = 200, body = '{}' } })
  request({
    path = '/search/stories',
    query = { query = 'owner:me state:"In Progress" 100%', page_size = 25, detail = 'slim' },
  })
  eq(
    requests()[1].url,
    'https://api.app.shortcut.com/api/v3/search/stories'
      .. '?detail=slim&page_size=25&query=owner%3Ame%20state%3A%22In%20Progress%22%20100%25'
  )
end

T['query']['encodes lists, booleans and unicode'] = function()
  eq(
    child.lua_get('_G.http.encode_query(...)', {
      { ids = { 1, 2 }, archived = false, ['a b'] = 'é&=+/?#', safe = 'A-z_0.9~' },
    }),
    'a%20b=%C3%A9%26%3D%2B%2F%3F%23&archived=false&ids=1&ids=2&safe=A-z_0.9~'
  )
  eq(child.lua_get('_G.http.encode_query(nil)'), '')
  eq(child.lua_get('_G.http.encode_query({})'), '')
end

T['retries'] = new_set()

T['retries']['retries a 429 and succeeds'] = function()
  respond({ { status = 429, retry_after = '2' }, { status = 200, body = '{"ok": true}' } })
  child.lua([[
    _G.delays = {}
    _G.http._delay = function(n, retry_after) table.insert(_G.delays, { n, retry_after }) return 0 end
  ]])
  local r = request({ method = 'POST', path = '/stories', body = {} })
  eq(r.err, nil)
  eq(r.data, { ok = true })
  eq(r.resp.attempts, 2)
  eq(#requests(), 2)
  eq(child.lua_get('_G.delays'), { { 1, '2' } })
end

T['retries']['gives up after the maximum number of retries'] = function()
  respond({ { status = 429 }, { status = 429 }, { status = 429 }, { status = 429 } })
  local r = request({ path = '/member' })
  eq(r.err.kind, 'http')
  eq(r.err.status, 429)
  eq(r.resp.attempts, 4)
  eq(#requests(), 4)
end

T['retries']['retries a GET after a network error'] = function()
  respond({ { error = 'Connection reset' }, { status = 200, body = '{}' } })
  local r = request({ path = '/member' })
  eq(r.err, nil)
  eq(#requests(), 2)
end

T['retries']['does not retry other methods after a network error'] = function()
  respond({ { error = 'Connection reset' }, { status = 200, body = '{}' } })
  local r = request({ method = 'PUT', path = '/stories/1', body = {} })
  eq(r.err.kind, 'network')
  eq(#requests(), 1)
end

T['retries']['does not retry a timeout'] = function()
  respond({ { error = 'Operation timed out', timed_out = true } })
  local r = request({ path = '/member' })
  eq(r.err.kind, 'network')
  eq(#requests(), 1)
end

T['retries']['does not retry other HTTP errors'] = function()
  respond({ { status = 500 }, { status = 200, body = '{}' } })
  eq(request({ path = '/member' }).err.status, 500)
  eq(#requests(), 1)
end

T['retries']['can be disabled'] = function()
  respond({ { status = 429 }, { status = 200, body = '{}' } })
  eq(request({ path = '/member', retry = false }).err.status, 429)
  eq(#requests(), 1)
end

T['retries']['backoff is exponential with jitter, honouring Retry-After'] = function()
  child.lua([[package.loaded['shortcut.http'] = nil; _G.http = require('shortcut.http')]])
  local delays = child.lua_get([[(function()
    local d = {}
    for n = 1, 3 do
      local lo, hi = math.huge, 0
      for _ = 1, 200 do
        local v = _G.http._delay(n)
        lo, hi = math.min(lo, v), math.max(hi, v)
      end
      d[n] = { lo, hi }
    end
    return d
  end)()]])
  for n, range in ipairs(delays) do
    local base = 1000 * 2 ^ (n - 1)
    eq(range[1] >= base and range[2] <= base * 1.25, true)
    eq(range[1] < range[2], true) -- jittered
  end
  eq(child.lua_get([[_G.http._delay(1, '7')]]), 7000)
  eq(child.lua_get([[_G.http._delay(3, '0')]]), 0)
  eq(child.lua_get([[_G.http._delay(1, '3600')]]), 60000)
  -- An HTTP-date is not understood: fall back to the backoff.
  eq(child.lua_get([[_G.http._delay(1, 'Wed, 21 Oct 2015 07:28:00 GMT') >= 1000]]), true)
end

T['cancel'] = new_set()

T['cancel']['stops the request and never calls back'] = function()
  respond({ { status = 200, body = '{}' } })
  child.lua([[
    _G.called = false
    local h = _G.http.request({ path = '/member' }, function() _G.called = true end)
    h:cancel()
    h:cancel()
    vim.wait(100)
    _G.was_cancelled = h:is_cancelled()
  ]])
  eq(child.lua_get('_G.called'), false)
  eq(child.lua_get('_G.cancelled'), 1)
  eq(child.lua_get('_G.was_cancelled'), true)
end

T['cancel']['stops a pending retry'] = function()
  respond({ { status = 429 }, { status = 200, body = '{}' } })
  child.lua([[
    _G.http._delay = function() return 200 end
    _G.called = false
    local h = _G.http.request({ path = '/member' }, function() _G.called = true end)
    vim.wait(1000, function() return #_G.requests == 1 end)
    vim.wait(20)
    h:cancel()
    vim.wait(400)
  ]])
  eq(child.lua_get('_G.called'), false)
  eq(#requests(), 1)
end

T['curl'] = new_set({
  hooks = {
    pre_case = function()
      -- Run the real curl transport against a fake `vim.system` that records the command.
      child.lua([[
        require('shortcut.http')._set_transport(nil)
        _G.result = { code = 0, stdout = '{"id": 1}', stderr = '' }
        _G.system_calls = {}
        vim.system = function(cmd, opts, on_exit)
          table.insert(_G.system_calls, { cmd = cmd, opts = { stdin = opts.stdin, timeout = opts.timeout } })
          local marker
          for i, arg in ipairs(cmd) do
            if arg == '--write-out' then marker = cmd[i + 1]:match('^\n(__SHORTCUT_NVIM_%x+__)') end
          end
          local res = vim.deepcopy(_G.result)
          if res.code == 0 then
            res.stdout = res.stdout .. '\n' .. marker .. (_G.trailer or '200 ')
          end
          vim.uv.new_timer():start(1, 0, function() on_exit(res) end)
          return { kill = function() _G.killed = true end }
        end
      ]])
    end,
  },
})

local function system_calls()
  return child.lua_get('_G.system_calls')
end

T['curl']['never puts the token or the body on the command line'] = function()
  local body = { name = 'secret-ish "body"\nline 2 \\ back' }
  local r = request({ method = 'POST', path = '/stories', body = body, query = { a = 'b c' } })
  eq(r.err, nil)
  eq(r.data, { id = 1 })

  local call = system_calls()[1]
  for _, arg in ipairs(call.cmd) do
    eq(arg:find(TOKEN, 1, true), nil)
    eq(arg:find('secret-ish', 1, true), nil)
  end
  eq(call.cmd[1], 'curl')
  eq(call.cmd[2], '-q') -- ignore ~/.curlrc
  eq(vim.tbl_contains(call.cmd, '--globoff'), true) -- no {a,b} / [1-3] URL expansion
  local cmdline = table.concat(call.cmd, ' ')
  eq(cmdline:find('--config -', 1, true) ~= nil, true)
  eq(cmdline:find('--max-time 30', 1, true) ~= nil, true)
  eq(cmdline:find('--request POST', 1, true) ~= nil, true)
  eq(
    cmdline:find('--url https://api.app.shortcut.com/api/v3/stories?a=b%20c', 1, true) ~= nil,
    true
  )

  -- The secrets go to stdin, as a curl config file.
  local stdin = call.opts.stdin
  eq(stdin:find('header = "Shortcut-Token: ' .. TOKEN .. '"', 1, true) ~= nil, true)
  eq(
    stdin:find(
      'data-raw = "{\\"name\\":\\"secret-ish \\\\\\"body\\\\\\"\\\\nline 2 \\\\\\\\ back\\"}"',
      1,
      true
    ) ~= nil,
    true
  )
end

T['curl']['parses the status and Retry-After from the write-out trailer'] = function()
  child.lua([[_G.trailer = '429 5\n']])
  child.lua(
    [[_G.http._delay = function(n, ra) _G.retry_after = ra; _G.trailer = '200 ' return 0 end]]
  )
  child.lua([[_G.result.stdout = '{"x": 1}']])
  local r = request({ path = '/member' })
  eq(r.err, nil)
  eq(r.data, { x = 1 })
  eq(child.lua_get('_G.retry_after'), '5')
end

T['curl']['finds the last marker even if the body contains it'] = function()
  local parsed = child.lua_get([[_G.http._parse_curl_output('a\nMARK200 \nMARK404 ', 'MARK')]])
  eq(parsed, { status = 404, body = 'a\nMARK200 ' })
  eq(child.lua_get([[_G.http._parse_curl_output('no trailer', 'MARK')]]), vim.NIL)
  eq(child.lua_get([[_G.http._parse_curl_output('\nMARK000 ', 'MARK')]]), vim.NIL)
end

T['curl']['reports curl failures from stderr'] = function()
  child.lua(
    [[_G.result = { code = 6, stdout = '', stderr = 'curl: (6) Could not resolve host: api.app.shortcut.com\n' }]]
  )
  local r = request({ path = '/member', retry = false })
  eq(r.err.kind, 'network')
  eq(r.err.status, nil)
  eq(r.err.message, '(6) Could not resolve host: api.app.shortcut.com')
end

T['curl']['marks timeouts'] = function()
  child.lua([[_G.result = { code = 28, stdout = '', stderr = 'curl: (28) Operation timed out' }]])
  local r = request({ path = '/member' })
  eq(r.err.message, '(28) Operation timed out')
  eq(#system_calls(), 1) -- not retried
end

T['curl']['kills curl on cancel'] = function()
  child.lua([[
    local h = _G.http.request({ path = '/member' }, function() end)
    vim.wait(1000, function() return #_G.system_calls == 1 end)
    h:cancel()
  ]])
  eq(child.lua_get('_G.killed'), true)
end

T['curl']['skips the "try curl --help" hint in errors'] = function()
  child.lua(
    [[_G.result = { code = 26, stdout = '', stderr =
    "curl: option --config: error encountered when reading a file\ncurl: try 'curl --help' or 'curl --manual' for more information\n" }]]
  )
  local r = request({ path = '/member', retry = false })
  eq(r.err.message, 'option --config: error encountered when reading a file')
end

T['curl']['reports a missing curl'] = function()
  child.lua([[vim.system = function() error('ENOENT: no such file or directory') end]])
  local r = request({ path = '/member', retry = false })
  eq(r.err.kind, 'network')
  eq(r.err.message:find('cannot run curl', 1, true) ~= nil, true)
end

T['whoami()'] = new_set()

T['whoami()']['parses GET /member'] = function()
  respond({ { status = 200, fixture = 'member' } })
  child.lua([[
    _G.http.whoami(function(err, id) _G.out = { err = err, id = id } end)
    vim.wait(1000, function() return _G.out ~= nil end)
  ]])
  eq(child.lua_get('_G.out'), {
    id = {
      id = '12345678-90ab-cdef-1234-567890abcdef',
      mention_name = 'jdoe',
      name = 'Jane Doe',
      url_slug = 'acme',
      workspace_name = 'Acme Corp',
    },
  })
  eq(requests()[1].url, 'https://api.app.shortcut.com/api/v3/member')
end

T['whoami()']['is cached for the session, per token'] = function()
  child.lua([[
    _G.routes = function() return { status = 200, fixture = 'member' } end
    _G.outs = {}
    local function call() _G.http.whoami(function(err, id) table.insert(_G.outs, id and id.mention_name or err) end) end
    call(); call() -- concurrent: one request
    vim.wait(1000, function() return #_G.outs == 2 end)
    call()
    vim.wait(1000, function() return #_G.outs == 3 end)
  ]])
  eq(child.lua_get('_G.outs'), { 'jdoe', 'jdoe', 'jdoe' })
  eq(#requests(), 1)

  child.lua([[
    vim.env.SHORTCUT_API_TOKEN = 'another-token-9999-8888-7777'
    require('shortcut.auth').reset()
    _G.http.whoami(function(_, id) table.insert(_G.outs, id.mention_name) end)
    vim.wait(1000, function() return #_G.outs == 4 end)
  ]])
  eq(#requests(), 2)
end

T['whoami()']['remembers other failures briefly'] = function()
  respond({ { status = 500 }, { status = 200, fixture = 'member' } })
  child.lua([[
    _G.outs = {}
    _G.call = function()
      local n = #_G.outs
      _G.http.whoami(function(err, id) table.insert(_G.outs, err and err.status or id.url_slug) end)
      vim.wait(1000, function() return #_G.outs > n end)
    end
    call()
    call() -- within the TTL: no new request
  ]])
  eq(child.lua_get('_G.outs'), { 500, 500 })
  eq(#requests(), 1)
  child.lua([[_G.http.WHOAMI_ERROR_TTL = 0; _G.http._clear_cache(); _G.responses = {
    { status = 500 }, { status = 200, fixture = 'member' } }; _G.requests = {}]])
  child.lua([[call(); vim.wait(5); call()]])
  eq(child.lua_get('_G.outs'), { 500, 500, 500, 'acme' })
  eq(#requests(), 2)
end

T['whoami()']['remembers a rejected token for the session'] = function()
  child.lua([[
    _G.http.WHOAMI_ERROR_TTL = 0
    _G.routes = function() return { status = 401 } end
    _G.outs = {}
    for i = 1, 3 do
      _G.http.whoami(function(err) table.insert(_G.outs, err.status) end)
      vim.wait(1000, function() return #_G.outs == i end)
    end
  ]])
  eq(child.lua_get('_G.outs'), { 401, 401, 401 })
  eq(#requests(), 1)
end

T['whoami()']['calls every waiter even if one fails'] = function()
  respond({ { status = 200, fixture = 'member' } })
  child.lua([[
    _G.outs = {}
    _G.http.whoami(function() error('first waiter broke') end)
    _G.http.whoami(function(_, id) table.insert(_G.outs, id.mention_name) end)
    vim.wait(1000, function() return #_G.outs == 1 end)
  ]])
  eq(child.lua_get('_G.outs'), { 'jdoe' })
  local msgs = child.lua_get('_G.messages')
  eq(#msgs, 1)
  eq(msgs[1].msg:find('first waiter broke', 1, true) ~= nil, true)
end

T['whoami()']['rejects a response without the expected fields'] = function()
  respond({ { status = 200, body = '{"id": "x"}' } })
  child.lua([[
    _G.http.whoami(function(err) _G.err = err end)
    vim.wait(1000, function() return _G.err ~= nil end)
  ]])
  eq(child.lua_get('_G.err.kind'), 'decode')
end

T['user()'] = new_set()

T['user()']['uses the short config identity without a request'] = function()
  local dir = child.lua_get('vim.fn.tempname()')
  child.lua(
    [[
    local dir, token = ...
    vim.env.SHORTCUT_API_TOKEN = nil
    vim.env.XDG_CONFIG_HOME = dir
    vim.fn.mkdir(dir .. '/shortcut-cli', 'p')
    vim.fn.writefile({ vim.json.encode({ token = token, mentionName = 'filed', urlSlug = 'fileslug' }) },
      dir .. '/shortcut-cli/config.json')
    _G.http.user(function(err, u) _G.out = { err = err, u = u } end)
    vim.wait(1000, function() return _G.out ~= nil end)
  ]],
    { dir, TOKEN }
  )
  eq(child.lua_get('_G.out'), { u = { mention_name = 'filed', url_slug = 'fileslug' } })
  eq(#requests(), 0)
end

T['user()']['asks the API for an environment token'] = function()
  respond({ { status = 200, fixture = 'member' } })
  child.lua([[
    _G.http.user(function(err, u) _G.out = { err = err, u = u } end)
    vim.wait(1000, function() return _G.out ~= nil end)
  ]])
  eq(child.lua_get('_G.out'), { u = { mention_name = 'jdoe', url_slug = 'acme' } })
end

T['slug source'] = new_set()

T['slug source']['warns when a URL is for another workspace than the token'] = function()
  child.lua([[_G.routes = function() return { status = 200, fixture = 'member' } end]])
  child.cmd('edit https://app.shortcut.com/elsewhere/story/12')
  child.lua([[vim.wait(1000, function() return #_G.messages > 0 end)]])
  local msgs = child.lua_get('_G.messages')
  eq(#msgs, 1)
  eq(msgs[1].msg:find("workspace 'elsewhere' but your token is for 'acme'", 1, true) ~= nil, true)

  child.lua('_G.messages = {}')
  child.cmd('edit https://app.shortcut.com/acme/story/13')
  child.lua('vim.wait(100)')
  eq(child.lua_get('_G.messages'), {})
end

T['slug source']['stays quiet without a token'] = function()
  child.lua('vim.env.SHORTCUT_API_TOKEN = nil')
  child.cmd('edit https://app.shortcut.com/elsewhere/story/12')
  child.lua('vim.wait(100)')
  eq(child.lua_get('_G.messages'), {})
  eq(#requests(), 0)
end

return T

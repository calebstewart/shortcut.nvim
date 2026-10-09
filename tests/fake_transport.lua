-- Loaded in a child Neovim with `dofile()`: replaces the HTTP transport with one serving queued
-- responses, so tests never touch the network.
--
-- Globals it defines:
--   _G.requests   transport requests made, in order
--   _G.responses  queue of transport results to serve; `{ status = n, fixture = 'name' }` serves
--                 tests/fixtures/<name>.json as the body. An empty queue answers 500.
--   _G.routes     optional `fun(req): result?`, consulted before the queue
--   _G.cancelled  number of transport cancellations
--   _G.fixture(name) -> string
--   _G.sync_request(req) -> { err, data, resp, fast }   waits for the callback
local http = require('shortcut.http')

_G.requests = {}
_G.responses = {}
_G.routes = nil
_G.cancelled = 0

-- Relative to this file, so tests may change the working directory.
local fixtures = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'fixtures')

function _G.fixture(name)
  local f = assert(io.open(('%s/%s.json'):format(fixtures, name), 'r'))
  local s = f:read('*a')
  f:close()
  return s
end

http._set_transport(function(req, done)
  table.insert(_G.requests, vim.deepcopy(req))
  local res = (_G.routes and _G.routes(req)) or table.remove(_G.responses, 1) or { status = 500 }
  res = vim.deepcopy(res)
  if res.fixture then
    res.body = _G.fixture(res.fixture)
    res.fixture = nil
  end
  -- Like curl, answer later, from a fast event.
  local timer = assert(vim.uv.new_timer())
  timer:start(1, 0, function()
    timer:close()
    done(res)
  end)
  return {
    cancel = function()
      _G.cancelled = _G.cancelled + 1
    end,
  }
end)
-- No waiting between retries.
---@diagnostic disable-next-line: duplicate-set-field
http._delay = function()
  return 0
end
http._clear_cache()

function _G.sync_request(req)
  local r
  http.request(req, function(err, data, resp)
    r = { err = err, data = data, resp = resp, fast = vim.in_fast_event() }
  end)
  vim.wait(2000, function()
    return r ~= nil
  end, 2)
  return r
end

--- Run callback-based code sequentially in a coroutine.
---
--- ```lua
--- async.run(function()
---   local err, story = async.await(http.request, { path = '/stories/1' })
---   if err then return notify.error(http.format_error(err)) end
---   local err2 = async.await(http.request, { method = 'PUT', path = '/stories/1', body = {...} })
---   ...
--- end)
--- ```
local M = {}

--- Resumes a coroutine started by `run()`, by coroutine.
---@type table<thread, fun(...)>
local steps = setmetatable({}, { __mode = 'k' })

---@param err any
---@param co thread
---@return string
local function describe(err, co)
  return debug.traceback(co, tostring(err))
end

--- Run `fn` in a new coroutine, in which `await()` may be used. `on_done(err, ...)` receives
--- `fn`'s return values, or an error it raised (with a traceback) as `err`. Without `on_done`,
--- an error is reported with `vim.notify`.
---@param fn async fun(): ...
---@param on_done? fun(err?: string, ...)
function M.run(fn, on_done)
  vim.validate('fn', fn, 'function')
  vim.validate('on_done', on_done, 'function', true)
  local co = coroutine.create(fn)

  local function step(...)
    local res = vim.F.pack_len(coroutine.resume(co, ...))
    if not res[1] then
      steps[co] = nil
      local msg = describe(res[2], co)
      if on_done then
        on_done(msg)
      else
        vim.schedule(function()
          require('shortcut.notify').error(msg)
        end)
      end
      return
    end
    if coroutine.status(co) == 'dead' then
      steps[co] = nil
      if on_done then
        on_done(nil, unpack(res, 2, res.n))
      end
    end
  end

  steps[co] = step
  step()
end

--- Call `fn(..., callback)` and wait for `callback` to be called; return the arguments it was
--- called with. Must be called from within `run()`. A second call of `callback` is ignored.
---@param fn fun(...)
---@param ... any Arguments for `fn`, before the callback.
---@return ...
function M.await(fn, ...)
  local co = coroutine.running()
  local step = co and steps[co]
  if not step then
    error('async.await() must be called inside async.run()', 2)
  end

  local args = vim.F.pack_len(...)
  local results ---@type table?
  local waiting = false
  args[args.n + 1] = function(...)
    if results then
      return
    end
    results = vim.F.pack_len(...)
    if waiting then
      step()
    end
  end
  fn(unpack(args, 1, args.n + 1))

  if not results then
    waiting = true
    coroutine.yield()
  end
  ---@cast results table
  return unpack(results, 1, results.n)
end

return M

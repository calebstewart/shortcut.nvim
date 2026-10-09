--- Run callback-based code sequentially in a coroutine.
---
--- ```lua
--- local task = async.run(function()
---   local err, story = async.await(http.request, { path = '/stories/1' })
---   if err then return notify.error(http.format_error(err)) end
---   local err2 = async.await(http.request, { method = 'PUT', path = '/stories/1', body = {...} })
---   ...
--- end)
--- task:cancel() -- also cancels the request being awaited
--- ```
---
--- Callbacks resume the coroutine where they are called: call them on the main loop (as
--- `shortcut.http` does) if the code after `await()` uses the API.
local M = {}

---@class shortcut.async.Task
---@field _co thread
---@field _cancelled boolean
---@field _done boolean
---@field _current? { cancel: fun(self: any) } Handle returned by the function being awaited.
---@field _step fun(...)
local Task = {}
Task.__index = Task

--- Running tasks, by coroutine. An entry is removed when its task finishes or is cancelled.
---@type table<thread, shortcut.async.Task>
local tasks = {}

---@param task shortcut.async.Task
local function forget(task)
  task._done = true
  task._current = nil
  tasks[task._co] = nil
end

--- Stop the task: it is never resumed, the awaited operation is cancelled if `await()` got a
--- handle with a `cancel` method for it, and `on_done` is not called.
function Task:cancel()
  if self._cancelled or self._done then
    return
  end
  self._cancelled = true
  local current = self._current
  if coroutine.running() ~= self._co then
    -- When cancelled from inside, `_step` cleans up once the coroutine yields.
    forget(self)
  end
  if current then
    pcall(current.cancel, current)
  end
end

---@return boolean
function Task:is_cancelled()
  return self._cancelled
end

---@return boolean
function Task:is_done()
  return self._done
end

--- Run `fn` in a new coroutine, in which `await()` may be used. `on_done(err, ...)` receives
--- `fn`'s return values, or the message of an error it raised as `err`. Without `on_done`, an
--- error is reported with `notify.error` (the message only, no traceback).
---@param fn async fun(): ...
---@param on_done? fun(err?: string, ...)
---@return shortcut.async.Task
function M.run(fn, on_done)
  vim.validate('fn', fn, 'function')
  vim.validate('on_done', on_done, 'function', true)
  local co = coroutine.create(fn)
  local task = setmetatable({ _co = co, _cancelled = false, _done = false }, Task)

  task._step = function(...)
    if task._done then
      return
    end
    local res = vim.F.pack_len(coroutine.resume(co, ...))
    if not res[1] then
      forget(task)
      if task._cancelled then
        return
      end
      local msg = tostring(res[2])
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
      forget(task)
      if on_done and not task._cancelled then
        on_done(nil, unpack(res, 2, res.n))
      end
    elseif task._cancelled then
      forget(task)
    end
  end

  tasks[co] = task
  task._step()
  return task
end

--- Call `fn(..., callback)` and wait for `callback` to be called; return the arguments it was
--- called with. Must be called from within `run()`. A second call of `callback` is ignored. If
--- `fn` returns a handle with a `cancel` method (like `shortcut.http.request`), cancelling the
--- task cancels it.
---@param fn fun(...): any
---@param ... any Arguments for `fn`, before the callback.
---@return ...
function M.await(fn, ...)
  local co = coroutine.running()
  local task = co and tasks[co]
  if not task then
    error('async.await() must be called inside async.run()', 2)
  end
  if task._cancelled then
    -- Cancelled from inside the task: stop here, without starting anything new.
    coroutine.yield()
  end

  local args = vim.F.pack_len(...)
  local results ---@type table?
  local waiting = false
  args[args.n + 1] = function(...)
    if results then
      return
    end
    results = vim.F.pack_len(...)
    task._current = nil
    if waiting then
      task._step()
    end
  end
  local handle = fn(unpack(args, 1, args.n + 1))

  if not results then
    if type(handle) == 'table' and type(handle.cancel) == 'function' then
      task._current = handle
    end
    waiting = true
    coroutine.yield()
  end
  ---@cast results table
  return unpack(results, 1, results.n)
end

--- Number of tasks not yet finished or cancelled (for tests).
---@return integer
function M._count()
  return vim.tbl_count(tasks)
end

return M

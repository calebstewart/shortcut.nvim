--- Story and epic search.
---
--- API facts (OpenAPI spec, see `shortcut.api`):
---   - `GET /search/stories` (searchStories) and `GET /search/epics` (searchEpics) take `query`
---     (required, `minLength: 1`; Shortcut's search operators), `page_size` (1 to 250),
---     `detail` (`full`, the default, or `slim`, which leaves out descriptions and comments) and
---     `next`.
---   - They return `{ data, next, total }`. `next` is "the URL path and query string for the
---     next page", i.e. `/api/v3/search/stories?query=...&page_size=...&detail=...&next=<token>`,
---     or `null` on the last page. It carries the original parameters, so it is requested as is:
---     without the `/api/v3` prefix (the HTTP client's base URL ends with it) and without adding
---     a query.
---   - Only the first 1000 results can be paged through; asking for more answers 400
---     (`maximum-results-exceeded`).
local config = require('shortcut.config')
local http = require('shortcut.http')

local M = {}

--- Results the API lets a search page through.
M.MAX_RESULTS = 1000

---@alias shortcut.api.search.Kind 'stories'|'epics'

---@class shortcut.api.search.Opts
---@field page_size? integer Defaults to `config.picker.page_size`.
---@field detail? 'slim'|'full' Defaults to `'slim'`.

---@class shortcut.api.search.Page
---@field data table[]
---@field next? string
---@field total? integer

---@param kind shortcut.api.search.Kind
---@param query string
---@param opts? shortcut.api.search.Opts|shortcut.api.Callback
---@param callback? shortcut.api.Callback
---@return shortcut.http.Handle
local function search(kind, query, opts, callback)
  if type(opts) == 'function' and callback == nil then
    -- `stories(query, callback)`, e.g. `async.await(search.stories, query)`.
    opts, callback = nil, opts
  end
  vim.validate('query', query, 'string')
  vim.validate('opts', opts, 'table', true)
  vim.validate('callback', callback, 'function')
  ---@cast callback shortcut.api.Callback
  opts = opts or {}
  local path = '/search/' .. kind
  query = vim.trim(query)
  if query == '' then
    return http.reject('GET', path, 'the search query is empty', callback)
  end
  return http.request({
    path = path,
    query = {
      query = query,
      page_size = opts.page_size or config.get().picker.page_size,
      detail = opts.detail or 'slim',
    },
  }, callback)
end

--- `GET /search/stories`: the first page of results. `opts` may be left out.
---@param query string
---@param opts? shortcut.api.search.Opts|shortcut.api.Callback
---@param callback? shortcut.api.Callback `data` is a `shortcut.api.search.Page`.
---@return shortcut.http.Handle
function M.stories(query, opts, callback)
  return search('stories', query, opts, callback)
end

--- `GET /search/epics`: the first page of results. `opts` may be left out.
---@param query string
---@param opts? shortcut.api.search.Opts|shortcut.api.Callback
---@param callback? shortcut.api.Callback `data` is a `shortcut.api.search.Page`.
---@return shortcut.http.Handle
function M.epics(query, opts, callback)
  return search('epics', query, opts, callback)
end

--- The request path for a page's `next`: `next` is an absolute path (`/api/v3/...`) on the API
--- server, but request paths are relative to `http.BASE_URL`, which ends with `/api/v3`.
---@param next_page string
---@return string? path `nil` if `next_page` is not a path below the API base.
function M.next_path(next_page)
  if type(next_page) ~= 'string' then
    return nil
  end
  local origin, base = http.BASE_URL:match('^(https?://[^/]+)(/.*)$')
  local path = next_page
  -- Accept a full URL too, as long as it is the API server's.
  if path:sub(1, #origin + 1) == origin .. '/' then
    path = path:sub(#origin + 1)
  end
  if path:sub(1, #base + 1) ~= base .. '/' then
    return nil
  end
  path = path:sub(#base + 1)
  if path:find('%c') then
    return nil
  end
  return path
end

--- Request the page a previous page's `next` points to.
---@param next_page string
---@param callback shortcut.api.Callback
---@return shortcut.http.Handle
function M.next_page(next_page, callback)
  local path = M.next_path(next_page)
  if not path then
    return http.reject('GET', tostring(next_page), 'unexpected next page link', callback)
  end
  -- No `query`: the query string is part of `next` already.
  return http.request({ path = path }, callback)
end

---@class shortcut.api.search.PageInfo
---@field page integer 1-based.
---@field count integer Results delivered so far, including this page's.
---@field total? integer Total matches, as reported by the API.

---@class shortcut.api.search.Summary
---@field count integer Results delivered.
---@field total? integer Total matches, as reported by the API.
---@field truncated boolean `true` if it stopped at `max_results` with more results left.

---@class shortcut.api.search.StreamOpts: shortcut.api.search.Opts
---@field max_results? integer Defaults to `config.picker.max_results`; at most `MAX_RESULTS`.

---@class shortcut.api.search.Stream
---@field _cancelled boolean
---@field _handle? shortcut.http.Handle
local Stream = {}
Stream.__index = Stream

--- Stop: the request in flight is cancelled, and neither `on_page` nor `on_done` is called again.
function Stream:cancel()
  if self._cancelled then
    return
  end
  self._cancelled = true
  if self._handle then
    self._handle:cancel()
    self._handle = nil
  end
end

---@return boolean
function Stream:is_cancelled()
  return self._cancelled
end

--- Search, then follow `next` page after page, calling `on_page(items, info)` for each, until
--- there is no `next` or `max_results` results have been delivered (the last page is cut to
--- fit). Then `on_done(err, summary)`: `err` if a request failed (pages delivered before it
--- stand). Cancel the returned stream to stop early, e.g. when a picker's query changes.
--- Callbacks run on the main loop; `on_page` may cancel the stream.
---@param kind shortcut.api.search.Kind
---@param query string
---@param opts? shortcut.api.search.StreamOpts
---@param on_page fun(items: table[], info: shortcut.api.search.PageInfo)
---@param on_done? fun(err?: shortcut.http.Error, summary: shortcut.api.search.Summary)
---@return shortcut.api.search.Stream
function M.stream(kind, query, opts, on_page, on_done)
  vim.validate('kind', kind, function(k)
    return k == 'stories' or k == 'epics'
  end, "'stories' or 'epics'")
  vim.validate('opts', opts, 'table', true)
  vim.validate('on_page', on_page, 'function')
  vim.validate('on_done', on_done, 'function', true)
  opts = opts or {}
  local max = math.min(opts.max_results or config.get().picker.max_results, M.MAX_RESULTS)
  local stream = setmetatable({ _cancelled = false }, Stream)
  local count, page, total = 0, 0, nil ---@type integer, integer, integer?

  ---@param err? shortcut.http.Error
  ---@param truncated boolean
  local function finish(err, truncated)
    stream._handle = nil
    stream._cancelled = true
    if on_done then
      on_done(err, { count = count, total = total, truncated = truncated })
    end
  end

  local function on_response(err, data)
    stream._handle = nil
    if stream._cancelled then
      return
    end
    if err then
      return finish(err, false)
    end
    if type(data) ~= 'table' or (data.data ~= nil and type(data.data) ~= 'table') then
      return finish({
        kind = 'decode',
        message = 'unexpected search response',
        method = 'GET',
        path = '/search/' .. kind,
      }, false)
    end
    total = tonumber(data.total) or total
    local items = data.data or {}
    local more = type(data.next) == 'string' and data.next ~= ''
    if count + #items > max then
      items = vim.list_slice(items, 1, max - count)
      more = true
    end
    count = count + #items
    page = page + 1
    on_page(items, { page = page, count = count, total = total })
    if stream._cancelled then
      return
    end
    if count >= max and more then
      return finish(nil, true)
    end
    if not more then
      return finish(nil, false)
    end
    stream._handle = M.next_page(data.next, on_response)
  end

  stream._handle = search(kind, query, opts, on_response)
  return stream
end

return M

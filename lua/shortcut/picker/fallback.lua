--- Pickers without snacks.nvim: `vim.ui.input` for the query (if none was given), the first
--- pages of results (up to `config.picker.max_results`), then `vim.ui.select`. No live search
--- and no preview.
local core = require('shortcut.picker')
local notify = require('shortcut.notify')

local M = {}

local told = false

--- Say once per session what is missing without snacks.
local function tell_once()
  if told then
    return
  end
  told = true
  notify.info('live search and previews need snacks.nvim; using vim.ui.input and vim.ui.select')
end

---@param source shortcut.picker.Source
---@param query string
local function search(source, query)
  local items = {}
  core.collect(source.kind, query, function(page)
    vim.list_extend(items, page)
  end, function(err, summary)
    if err then
      notify.error(require('shortcut.http').format_error(err))
      return
    end
    ---@cast summary shortcut.picker.CollectSummary
    if summary.refs_err then
      notify.warn(
        ('lookup lists unavailable, showing IDs instead of names: %s'):format(
          require('shortcut.http').format_error(summary.refs_err)
        )
      )
    end
    if #items == 0 then
      notify.info(('no results for %s'):format(query))
      return
    end
    local prompt = source.title
    if summary.truncated then
      prompt = ('%s (first %d of %s)'):format(prompt, #items, summary.total or 'more')
    end
    vim.ui.select(
      items,
      { prompt = prompt, format_item = core.label, kind = 'shortcut' },
      function(choice)
        if choice then
          core.open(choice)
        end
      end
    )
  end)
end

--- Open a picker for `source`. An empty `query` is asked for.
---@param source shortcut.picker.Source
---@param query string
function M.open(source, query)
  tell_once()
  if query ~= '' then
    return search(source, query)
  end
  vim.ui.input({ prompt = source.title .. ': ', default = source.default_query }, function(input)
    input = input and vim.trim(input) or ''
    if input ~= '' then
      search(source, input)
    end
  end)
end

--- Forget that the notification was shown (for tests).
function M._reset()
  told = false
end

return M

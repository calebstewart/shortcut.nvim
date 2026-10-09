--- Parsing a story buffer back into fields (the inverse of `shortcut.buffer.story`'s render).
---
--- ```lua
--- local parsed, errors = require('shortcut.buffer.story_parse').parse(lines)
--- ```
---
--- - The header is read with `shortcut.buffer.frontmatter`, and each field is checked and
---   normalized (see `shortcut.story_parse.Header`). Unknown and missing keys are errors.
--- - The sections are found by their HTML comment markers (`story.sections()`), not by headings,
---   so a description may contain its own `## Tasks`. A missing marker is an error suggesting
---   `:e!`.
--- - The title is the `# <title>` line right after the header (blank lines may come before it);
---   the description is everything from there to the tasks marker, without leading and trailing
---   blank lines.
--- - The tasks section holds `- [ ] description · @owner @owner` lines, blank lines and its
---   `## Tasks` heading; anything else is an error. Everything below the comments marker is
---   ignored.
---
--- Names are not resolved here (see `shortcut.buffer.story_diff`). Every problem found is
--- returned, with its line, rather than only the first one.
---
--- Pure: no buffer or editor state is used.
local frontmatter = require('shortcut.buffer.frontmatter')
local story = require('shortcut.buffer.story')

local M = {}

M.STORY_TYPES = { 'feature', 'bug', 'chore' }

--- Limits of the API (`UpdateStory`, `CreateTask`/`UpdateTask`), in characters.
M.MAX_NAME = 512
M.MAX_DESCRIPTION = 100000
M.MAX_TASK = 2048

---@class shortcut.story_parse.Error
---@field line integer 1-based.
---@field message string

--- The header, normalized. Empty values are `nil`.
---@class shortcut.story_parse.Header
---@field id? shortcut.frontmatter.Value As written (read-only).
---@field type? string `feature`, `bug` or `chore`.
---@field state? string
---@field owners string[] Mention names, without `@`.
---@field epic? { id: integer, text: string } `text` is the value as written.
---@field iteration? string|integer A name, or an integer (a name or an ID).
---@field estimate? integer
---@field labels string[]
---@field url? shortcut.frontmatter.Value As written (read-only).

---@class shortcut.story_parse.Task
---@field line integer
---@field complete boolean
---@field description string
---@field owners string[] Mention names, without `@`. Always empty when owners are not shown.

---@class shortcut.story_parse.Story
---@field header shortcut.story_parse.Header
---@field key_lines table<string, integer> Line of each header key.
---@field header_end integer Line of the closing `---`.
---@field title string
---@field title_line integer
---@field description string
---@field tasks_marker integer
---@field comments_marker integer
---@field tasks shortcut.story_parse.Task[] In buffer order.

---@class shortcut.story_parse.Opts
---@field show_owners? boolean Task owners are shown (default `true`). When not, the whole text after the checkbox is the description.
---@field fields? string[] Header keys (default `story.FIELDS`).

--- Number of characters of a UTF-8 string.
---@param s string
---@return integer
function M.chars(s)
  local _, n = s:gsub('[^\128-\191]', '')
  return n
end

---@param s string
---@return boolean
local function blank(s)
  return s:match('^%s*$') ~= nil
end

--- Split a task's text into its description (still escaped) and owners: the last ` · `
--- followed only by `@mention`s separates them. See `story.split_owners()`.
M.split_owners = story.split_owners

--- Parse one line of the tasks section.
---@param line string
---@param show_owners boolean
---@return { complete: boolean, description: string, owners: string[] }|false|nil task `false` if the line is allowed but not a task, `nil` if it is not a task line.
---@return string? err Why the line is invalid. A task line with an invalid description is still returned, with the error.
local function task_line(line, show_owners)
  if blank(line) or vim.trim(line):match('^##%s+Tasks$') then
    return false
  end
  local mark, rest = line:match('^%s*[-*+]%s+%[(.)%](.*)$')
  if not mark then
    return nil, "not a task: task lines look like '- [ ] description'"
  end
  if mark ~= ' ' and mark ~= 'x' and mark ~= 'X' then
    return nil, ("invalid checkbox '[%s]': use '[ ]' or '[x]'"):format(mark)
  end
  if rest ~= '' and not rest:match('^%s') then
    return nil, "not a task: expected a space after '[ ]'"
  end
  local description, owners ---@type string, string[]
  if show_owners then
    description, owners = M.split_owners(rest)
    description = story.unescape_task(description)
  else
    description, owners = vim.trim(rest), {}
  end
  local task = { complete = mark ~= ' ', description = description, owners = owners }
  if description == '' then
    return task, 'a task needs a description'
  end
  if M.chars(description) > M.MAX_TASK then
    return task, ('task description too long (at most %d characters)'):format(M.MAX_TASK)
  end
  return task
end

--- A list header value as strings. A single value is a one-item list.
---@param v shortcut.frontmatter.Value?
---@return string[]
local function string_list(v)
  if v == nil then
    return {}
  end
  if type(v) ~= 'table' then
    v = { v }
  end
  local out = {}
  for _, item in ipairs(v) do
    local s = vim.trim(tostring(item)):gsub('^@', '')
    table.insert(out, s)
  end
  return out
end

--- Check and normalize the header fields.
---@param fields table<string, shortcut.frontmatter.Value>
---@param key_lines table<string, integer>
---@param errors shortcut.story_parse.Error[]
---@return shortcut.story_parse.Header
local function header(fields, key_lines, errors)
  local function err(key, msg)
    table.insert(errors, { line = key_lines[key], message = ('%s: %s'):format(key, msg) })
  end
  local listed = {} ---@type table<string, true>
  local function scalar(key)
    local v = fields[key]
    if type(v) == 'table' then
      err(key, 'expected a single value, not a list')
      listed[key] = true
      return nil
    end
    return v
  end

  local h = { owners = string_list(fields.owners), labels = string_list(fields.labels) } ---@type shortcut.story_parse.Header
  h.id = fields.id
  h.url = fields.url

  local t = scalar('type')
  if t ~= nil then
    t = tostring(t)
    if not vim.list_contains(M.STORY_TYPES, t) then
      err(
        'type',
        ("'%s' is not a story type (use %s)"):format(t, table.concat(M.STORY_TYPES, ', '))
      )
    end
    h.type = t
  elseif key_lines.type and not listed.type then
    err('type', ('a story needs a type (%s)'):format(table.concat(M.STORY_TYPES, ', ')))
  end

  local state = scalar('state')
  if state ~= nil then
    h.state = vim.trim(tostring(state))
  elseif key_lines.state and not listed.state then
    err('state', 'a story needs a workflow state')
  end

  local epic = scalar('epic')
  if type(epic) == 'number' then
    if epic < 1 then
      err('epic', 'expected an epic ID')
    else
      h.epic = { id = epic, text = tostring(epic) }
    end
  elseif epic ~= nil then
    epic = tostring(epic)
    local digits = epic:match('^%s*(%d+)%s') or epic:match('^%s*(%d+)$')
    local id = digits and tonumber(digits)
    if not id or id < 1 or id > 2 ^ 53 - 1 then
      err('epic', ("expected '<epic ID> [name]', got '%s'"):format(epic))
    else
      h.epic = { id = id, text = vim.trim(epic) }
    end
  end

  local iteration = scalar('iteration')
  if type(iteration) == 'string' then
    iteration = vim.trim(iteration)
  end
  h.iteration = iteration --[[@as string|integer?]]

  local estimate = scalar('estimate')
  if estimate ~= nil then
    if type(estimate) ~= 'number' or estimate < 0 then
      err('estimate', ("expected a non-negative integer, got '%s'"):format(tostring(estimate)))
    else
      h.estimate = estimate --[[@as integer]]
    end
  end

  for key, list in pairs({ owners = h.owners, labels = h.labels }) do
    for _, item in ipairs(list) do
      if item == '' then
        err(key, 'empty name')
      end
    end
  end
  return h
end

--- Parse the lines of a story buffer.
---
--- Returns the parsed story (`nil` if the header or the section markers could not be read) and
--- every problem found. A story with problems must not be saved, but is returned so that
--- further checks can report their own problems too.
---@param lines string[]
---@param opts? shortcut.story_parse.Opts
---@return shortcut.story_parse.Story? parsed
---@return shortcut.story_parse.Error[] errors Sorted by line.
function M.parse(lines, opts)
  vim.validate('lines', lines, 'table')
  opts = opts or {}
  local show_owners = opts.show_owners ~= false
  local keys = opts.fields or story.FIELDS
  local errors = {} ---@type shortcut.story_parse.Error[]

  local fields, body_start, key_lines = frontmatter.parse(lines)
  if not fields then
    return nil,
      {
        {
          line = key_lines --[[@as integer]],
          message = body_start --[[@as string]],
        },
      }
  end
  ---@cast body_start integer
  ---@cast key_lines table<string, integer>
  local header_end = body_start - 1

  local markers, marker_err = story.sections(lines)
  if not markers then
    return nil,
      {
        {
          line = math.min(#lines, math.max(1, header_end)),
          message = ('%s; :e! reloads the story (discarding your changes)'):format(marker_err),
        },
      }
  end
  if markers.tasks_marker <= header_end then
    return nil,
      { { line = markers.tasks_marker, message = 'the tasks marker is inside the header' } }
  end

  local known = {}
  for _, key in ipairs(keys) do
    known[key] = true
    if not key_lines[key] then
      table.insert(errors, {
        line = header_end,
        message = ("missing header field '%s'; :e! reloads the story"):format(key),
      })
    end
  end
  for key, line in pairs(key_lines) do
    if not known[key] then
      table.insert(errors, {
        line = line,
        message = ("unknown header field '%s' (fields: %s)"):format(key, table.concat(keys, ', ')),
      })
    end
  end

  local parsed = {
    header = header(fields, key_lines, errors),
    key_lines = key_lines,
    header_end = header_end,
    title = '',
    title_line = body_start,
    description = '',
    tasks_marker = markers.tasks_marker,
    comments_marker = markers.comments_marker,
    tasks = {},
  } ---@type shortcut.story_parse.Story

  -- Title: the first non-blank line after the header.
  local title_line ---@type integer?
  for i = body_start, markers.tasks_marker - 1 do
    if not blank(lines[i]) then
      title_line = i
      break
    end
  end
  local title = title_line and lines[title_line]:match('^#%s+(.-)%s*$')
    or title_line and lines[title_line]:match('^#$') and ''
  if not title_line or not title then
    table.insert(errors, {
      line = title_line or math.min(body_start, markers.tasks_marker),
      message = "expected the title ('# <title>') right after the header",
    })
  else
    ---@cast title_line integer
    parsed.title_line = title_line
    parsed.title = title
    if title == '' then
      table.insert(errors, { line = title_line, message = 'the title cannot be empty' })
    elseif M.chars(title) > M.MAX_NAME then
      table.insert(errors, {
        line = title_line,
        message = ('the title is too long (at most %d characters)'):format(M.MAX_NAME),
      })
    end
  end

  -- Description.
  local first, last = (title_line or body_start - 1) + 1, markers.tasks_marker - 1
  while first <= last and blank(lines[first]) do
    first = first + 1
  end
  while last >= first and blank(lines[last]) do
    last = last - 1
  end
  parsed.description = table.concat(vim.list_slice(lines, first, last), '\n')
  if M.chars(parsed.description) > M.MAX_DESCRIPTION then
    table.insert(errors, {
      line = first,
      message = ('the description is too long (at most %d characters)'):format(M.MAX_DESCRIPTION),
    })
  end

  -- Tasks.
  for i = markers.tasks_marker + 1, markers.comments_marker - 1 do
    local task, err = task_line(lines[i], show_owners)
    if task then
      ---@cast task shortcut.story_parse.Task
      task.line = i
      table.insert(parsed.tasks, task)
    end
    if err then
      table.insert(errors, { line = i, message = err })
    end
  end

  table.sort(errors, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.message < b.message
  end)
  return parsed, errors
end

return M

--- Creating stories: `:Shortcut create [key=value...]` opens a draft, and `:w` creates it.
---
--- A draft is a buffer named `shortcut://story/new-<n>` (`buftype=acwrite`, see
--- `shortcut.uri.draft_name()`), in the story buffer format without `id`, `url` and the comments
--- section. It is read with the same parser as story editing (`shortcut.buffer.story_parse`, with
--- `draft = true`), and its names are looked up the same way (`shortcut.buffer.story_diff.create()`).
---
--- The template's defaults, in order (later ones win):
---   1. `type: feature`, `owners: [<the token's member>]`, and `state:` the first `unstarted` state
---      of the workflow (by position; else the workflow's default state, else its first one),
---   2. `config.create.template(fields)`,
---   3. the command's `key=value` arguments.
--- The workflow is `workflow=` or `config.create.workflow`; else the default workflow of the team
--- (`team=` or `config.create.team`, `Group.default_workflow_id`); else the workspace's default
--- workflow (`GET /member`: `workspace2.default_workflow_id`). The team becomes the story's
--- `group_id`.
---
--- Writing:
---   - Only a write of the whole buffer to its own name, in its own window (`:w`, `:x`, `:wq`,
---     `:up`), creates the story. `:w file`, `:saveas`, `:w shortcut://story/<id>`, partial
---     writes, and `:wall`/`:wqa` from another window are refused and send nothing.
---   - Every problem is a diagnostic (namespace `shortcut.edit`, as when editing) and nothing is
---     sent. A new epic must exist (`GET /epics/{id}`).
---   - The write waits for the answer (at most `write_wait()`; `<C-c>` stops waiting): on success
---     the buffer is no longer modified, so `:wq`/`:x` go on to close it; on failure it stays
---     modified, so they don't. The buffer is not modifiable meanwhile, and another write while
---     the story is being created sends nothing. `:e!` meanwhile keeps what is being sent.
---   - Stopping the wait (`<C-c>`) before `POST /stories` is sent cancels the checks before it:
---     nothing is sent. Once it is sent, the story's buffer opens when it is created.
---   - Only a request refused before being sent, or answered with a 4xx, certainly created
---     nothing. Any other failure (no answer, a timeout, a 5xx, a 2xx without the story) may have
---     created the story: the draft is kept, and only `:w!` sends it again.
---   - Once created, every window showing the draft switches to `shortcut://story/<id>` and the
---     draft is wiped.
---
--- API facts (OpenAPI spec, see `shortcut.api`):
---   - `POST /stories` (createStory) takes `CreateStoryParams`: `name` is required, and exactly
---     one of `workflow_state_id` and `project_id` (legacy, Projects are being sunset). Also
---     `story_type`, `description`, `owner_ids`, `epic_id`, `iteration_id`, `estimate`,
---     `group_id`, `labels` (`CreateLabelParams`, `{ name }`: a missing label is created, so
---     only existing ones are sent) and `tasks` (`CreateTaskParams`: `description`, `complete`,
---     `owner_ids`). Answers 201 with the `Story`.
---   - `GET /member` (`MemberInfo`): `workspace2.default_workflow_id` is the workspace's default
---     workflow. `Group.default_workflow_id` (nullable) is the default workflow for stories
---     created in that team.
local async = require('shortcut.async')
local commands = require('shortcut.commands')
local frontmatter = require('shortcut.buffer.frontmatter')
local notify = require('shortcut.notify')
local story = require('shortcut.buffer.story')
local uri = require('shortcut.uri')

local M = {}

--- The fields of a draft's template, as `config.create.template` gets and returns them.
---@class shortcut.create.Fields
---@field title string
---@field description string
---@field type? string `feature`, `bug` or `chore`.
---@field state? string Workflow state name.
---@field owners string[] Mention names.
---@field epic? integer|string An epic ID (optionally followed by its name).
---@field iteration? integer|string An iteration name or ID.
---@field estimate? integer
---@field labels string[] Label names.
---@field tasks (string|shortcut.create.Task)[] A string is an open task's description.

---@class shortcut.create.Task
---@field description string
---@field complete? boolean
---@field owners? string[] Mention names.

--- What a draft is created with, besides its text.
---@class shortcut.create.Spec
---@field fields shortcut.create.Fields
---@field workflow_id integer
---@field group_id? string

---@class shortcut.create.Draft
---@field n integer
---@field workflow_id integer
---@field group_id? string
---@field template string[] The lines it was opened with (`:e!` goes back to them).
---@field show_owners boolean
---@field created? integer The story created from it.
---@field sending? string[] The lines being sent, while the story is being created.
---@field uncertain? string Set when a create may or may not have happened (why): only `:w!` sends again.

--- Keys of `:Shortcut create key=value`, in completion order.
M.KEYS =
  { 'type', 'state', 'owners', 'epic', 'iteration', 'estimate', 'labels', 'workflow', 'team' }

--- Keys whose value is a comma-separated list.
local LIST_KEYS = { owners = true, labels = true }

local ALIASES = { owner = 'owners', label = 'labels' }

---@type table<integer, shortcut.create.Draft>
local drafts = {}

--- Drafts whose story is being created.
---@type table<integer, true>
local creating = {}

--- Drafts that are the user's current buffer (see `on_write()`).
---@type table<integer, true>
local focused = {}

--- The number of the last draft.
local counter = 0

---------------------------------------------------------------------------------------------------
-- Arguments
---------------------------------------------------------------------------------------------------

--- Parse the `key=value` arguments of `:Shortcut create`. Lists (`owners`, `labels`) are
--- comma-separated; `epic` and `estimate` are integers. Raises an error on anything else.
---@param args string[]
---@return table<string, any>
function M.parse_args(args)
  local out = {}
  for _, arg in ipairs(args) do
    local key, value = arg:match('^([%a_]+)=(.*)$')
    key = key and (ALIASES[key] or key)
    if not key or not vim.list_contains(M.KEYS, key) then
      error(
        ("invalid argument '%s': expected key=value, with key one of %s"):format(
          arg,
          table.concat(M.KEYS, ', ')
        ),
        0
      )
    end
    value = vim.trim(value)
    if LIST_KEYS[key] then
      local items = {}
      for _, item in ipairs(vim.split(value, ',', { plain = true })) do
        item = vim.trim(item):gsub('^@', '')
        if item ~= '' then
          table.insert(items, item)
        end
      end
      out[key] = items
    elseif value == '' then
      out[key] = vim.NIL
    elseif key == 'type' then
      local types = require('shortcut.buffer.story_parse').STORY_TYPES
      if not vim.list_contains(types, value) then
        error(
          ("type: '%s' is not a story type (use %s)"):format(value, table.concat(types, ', ')),
          0
        )
      end
      out.type = value
    elseif key == 'epic' or key == 'estimate' then
      local n = value:match('^%d+$') and tonumber(value)
      if not n or (key == 'epic' and (n < 1 or n > uri.MAX_ID)) then
        error(
          ("%s: expected %s, got '%s'"):format(
            key,
            key == 'epic' and 'an epic ID' or 'a non-negative integer',
            value
          ),
          0
        )
      end
      out[key] = n
    else
      out[key] = value
    end
  end
  return out
end

---------------------------------------------------------------------------------------------------
-- Template
---------------------------------------------------------------------------------------------------

---@param v any
---@return string[]
local function strings(v)
  local out = {}
  for _, item in ipairs(type(v) == 'table' and v or {}) do
    if type(item) == 'string' or type(item) == 'number' then
      table.insert(out, story.one_line(tostring(item)))
    end
  end
  return out
end

---@param v any
---@return shortcut.frontmatter.Scalar?
local function scalar(v)
  if type(v) == 'number' then
    return v
  end
  if type(v) == 'string' and vim.trim(v) ~= '' then
    return story.one_line(v)
  end
  return nil
end

--- Render a draft. Pure.
---@param fields shortcut.create.Fields
---@param opts? { show_owners?: boolean }
---@return string[] lines
---@return integer title_line
function M.render(fields, opts)
  vim.validate('fields', fields, 'table')
  local show_owners = not (opts and opts.show_owners == false)
  local lines = frontmatter.serialize({
    type = scalar(fields.type),
    state = scalar(fields.state),
    owners = strings(fields.owners),
    epic = scalar(fields.epic),
    iteration = scalar(fields.iteration),
    estimate = scalar(fields.estimate),
    labels = strings(fields.labels),
  }, story.DRAFT_FIELDS)
  table.insert(lines, '# ' .. story.one_line(fields.title or ''))
  local title_line = #lines
  table.insert(lines, '')
  local description = story.text_lines(fields.description)
  while #description > 0 and description[#description]:match('^%s*$') do
    table.remove(description)
  end
  while #description > 0 and description[1]:match('^%s*$') do
    table.remove(description, 1)
  end
  if #description > 0 then
    vim.list_extend(lines, description)
    table.insert(lines, '')
  end
  table.insert(lines, story.TASKS_MARKER)
  table.insert(lines, '## Tasks')
  for _, t in ipairs(type(fields.tasks) == 'table' and fields.tasks or {}) do
    if type(t) == 'string' then
      t = { description = t }
    end
    if type(t) == 'table' and type(t.description) == 'string' then
      local description_ = story.one_line(t.description)
      if show_owners then
        description_ = story.escape_task(description_)
      end
      local line = ('- [%s] %s'):format(t.complete == true and 'x' or ' ', description_)
      local owners = strings(t.owners)
      if show_owners and #owners > 0 then
        line = line
          .. story.SEPARATOR
          .. table.concat(
            vim.tbl_map(function(o)
              return '@' .. o
            end, owners),
            ' '
          )
      end
      table.insert(lines, line)
    end
  end
  return lines, title_line
end

--- The first `unstarted` state of a workflow (by position), else its default state, else its
--- first state.
---@param workflow shortcut.refs.Workflow
---@return shortcut.refs.State?
function M.default_state(workflow)
  for _, s in ipairs(workflow.states) do
    if s.type == 'unstarted' then
      return s
    end
  end
  for _, s in ipairs(workflow.states) do
    if s.id == workflow.default_state_id then
      return s
    end
  end
  return workflow.states[1]
end

--- A workflow by ID or name (exact, then ignoring case).
---@param spec string|integer
---@return shortcut.refs.Workflow? workflow
---@return string? err
function M.find_workflow(spec)
  local cache = require('shortcut.cache')
  local workflows = cache.workflows() or {}
  local id = type(spec) == 'number' and spec or (tostring(spec):match('^%s*(%d+)%s*$'))
  if id then
    local w = cache.workflow(tonumber(id) --[[@as integer]])
    if w then
      return w
    end
  end
  local wanted = vim.trim(tostring(spec))
  for _, eq in ipairs({
    function(name)
      return name == wanted
    end,
    function(name)
      return name:lower() == wanted:lower()
    end,
  }) do
    local found = vim.tbl_filter(function(w)
      return eq(w.name)
    end, workflows)
    if #found == 1 then
      return found[1]
    elseif #found > 1 then
      return nil, ("ambiguous workflow '%s'"):format(wanted)
    end
  end
  local names = vim.tbl_map(function(w)
    return "'" .. w.name .. "'"
  end, workflows)
  return nil, ("unknown workflow '%s' (workflows: %s)"):format(wanted, table.concat(names, ', '))
end

--- A team by ID, name or mention name.
---@param spec string
---@return shortcut.refs.Group? group
---@return string? err
local function find_team(spec)
  local cache = require('shortcut.cache')
  local group = cache.group(vim.trim(spec))
  if group then
    return group
  end
  return cache.group_by_name(spec)
end

--- Work out a draft's workflow, team and fields. `callback(err, spec)` runs on the main loop.
---@param args table<string, any> From `parse_args()`.
---@param callback fun(err?: string, spec?: shortcut.create.Spec)
function M.resolve(args, callback)
  local cache = require('shortcut.cache')
  local http = require('shortcut.http')
  local cfg = require('shortcut.config').get().create
  local function arg(key, default)
    local v = args[key]
    if v == vim.NIL then
      return nil
    end
    if v == nil then
      return default
    end
    return v
  end
  async.run(function()
    local workflow_spec = arg('workflow', cfg.workflow)
    local team_spec = arg('team', cfg.team)
    local kinds = { 'workflows' }
    if team_spec then
      table.insert(kinds, 'groups')
    end
    local err = async.await(cache.load, kinds)
    if err then
      return ('cannot fetch the lookup lists: %s'):format(http.format_error(err))
    end

    local group ---@type shortcut.refs.Group?
    if team_spec then
      local team_err
      group, team_err = find_team(team_spec)
      if not group then
        return ('team: %s'):format(team_err)
      end
    end

    local workflow ---@type shortcut.refs.Workflow?
    if workflow_spec then
      local werr
      workflow, werr = M.find_workflow(workflow_spec)
      if not workflow then
        return ('workflow: %s'):format(werr)
      end
    elseif group and group.default_workflow_id and cache.workflow(group.default_workflow_id) then
      workflow = cache.workflow(group.default_workflow_id)
    else
      local werr, identity = async.await(http.whoami)
      local id = identity and identity.default_workflow_id
      workflow = id and cache.workflow(id) or nil
      if not workflow then
        local all = cache.workflows() or {}
        if #all == 1 then
          workflow = all[1]
        else
          return ('cannot tell the workspace default workflow (%s); set create.workflow or use workflow=<name>'):format(
            werr and http.format_error(werr) or 'not in the workflow list'
          )
        end
      end
    end
    ---@cast workflow shortcut.refs.Workflow

    local owners = {}
    local uerr, user = async.await(http.user)
    if user then
      owners = { user.mention_name }
    elseif uerr then
      notify.warn(
        ('cannot tell who you are, so the story has no owner: %s'):format(http.format_error(uerr))
      )
    end
    local state = M.default_state(workflow)
    ---@type shortcut.create.Fields
    local fields = {
      title = '',
      description = '',
      type = 'feature',
      state = state and state.name or nil,
      owners = owners,
      labels = {},
      tasks = {},
    }
    if cfg.template then
      local ok, result = pcall(cfg.template, fields)
      if not ok then
        return ('create.template: %s'):format(tostring(result))
      end
      if result ~= nil then
        if type(result) ~= 'table' then
          return ('create.template: expected a table or nil, got %s'):format(type(result))
        end
        fields = result
      end
    end
    for _, key in ipairs({ 'type', 'state', 'owners', 'epic', 'iteration', 'estimate', 'labels' }) do
      if args[key] == vim.NIL then
        fields[key] = nil
      elseif args[key] ~= nil then
        fields[key] = args[key]
      end
    end
    return nil, { fields = fields, workflow_id = workflow.id, group_id = group and group.id or nil }
  end, function(thrown, err, spec)
    if thrown then
      return callback((tostring(thrown):gsub('^[^\n]-:%d+: ', '', 1)))
    end
    callback(err, spec)
  end)
end

---------------------------------------------------------------------------------------------------
-- Draft buffers
---------------------------------------------------------------------------------------------------

---@param target string
---@return string
local function refusal(target)
  return ('shortcut.nvim: cannot write the draft to %s: :w creates the story, :q! discards it'):format(
    notify.flatten(target)
  )
end

--- Replace a draft's lines, without undo history.
---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
  vim.bo[buf].modified = false
end

--- The draft of a buffer, if it is one.
---@param buf? integer Defaults to the current buffer.
---@return shortcut.create.Draft?
function M.draft(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf --[[@as integer]]
  return drafts[buf]
end

--- Whether the story of a draft is being created.
---@param buf? integer Defaults to the current buffer.
---@return boolean
function M.is_creating(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf --[[@as integer]]
  return creating[buf] == true
end

--- Put a draft back to its template (`:e!`).
---@param buf integer
function M.reset(buf)
  local d = drafts[buf]
  if not d then
    return
  end
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].modeline = false
  if creating[buf] and d.sending then
    -- Neovim has emptied the buffer already: put back what is being sent, still modified (it is
    -- not saved yet) and read-only (it is still being sent).
    set_lines(buf, d.sending)
    vim.bo[buf].modified = true
    vim.bo[buf].modifiable = false
    notify.warn('the story is being created: the draft was kept as it is being sent')
  else
    set_lines(buf, d.template)
    vim.diagnostic.reset(story.edit_ns(), buf)
  end
  -- A read sets the filetype again (as filetype detection would), so that highlighting (e.g.
  -- treesitter) attaches to the new text.
  vim.bo[buf].filetype = 'markdown'
end

--- Longest wait for the answer when writing a draft, in milliseconds. `nil`: three requests'
--- worth (`http.timeout`), plus some.
---@type integer?
M.WRITE_WAIT = nil

---@return integer
local function write_wait()
  return M.WRITE_WAIT or (require('shortcut.config').get().http.timeout * 3 + 5) * 1000
end

--- The one-line summary of a list of problems.
---@param errors shortcut.story_parse.Error[]
---@return string
local function error_summary(errors)
  local first = errors[1]
  local more = #errors > 1 and (' (and %d more)'):format(#errors - 1) or ''
  return ('line %d: %s%s; nothing was sent'):format(first.line, first.message, more)
end

---@param buf integer
---@param errors shortcut.story_parse.Error[]
local function show_errors(buf, errors)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local items = {}
  for _, e in ipairs(errors) do
    table.insert(items, {
      lnum = math.max(0, math.min(e.line, count) - 1),
      col = 0,
      severity = vim.diagnostic.severity.ERROR,
      source = 'shortcut',
      message = e.message,
    })
  end
  vim.diagnostic.set(story.edit_ns(), buf, items)
end

--- What creating the story of a draft sends, and the problems that keep it from being sent.
--- Synchronous: uses the lookup lists already loaded.
---@param buf? integer Defaults to the current buffer.
---@param lookup? shortcut.story_diff.Lookup Defaults to the cache's.
---@param lines? string[] Defaults to the buffer's.
---@return shortcut.story_diff.Create? create `nil` if the draft could not be parsed.
---@return shortcut.story_parse.Error[] errors
function M.body(buf, lookup, lines)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf --[[@as integer]]
  local d = assert(drafts[buf], 'not a draft')
  local parse = require('shortcut.buffer.story_parse')
  lines = lines or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cur, errors = parse.parse(lines, { draft = true, show_owners = d.show_owners })
  if not cur then
    return nil, errors
  end
  local create, create_errors = require('shortcut.buffer.story_diff').create(cur, {
    workflow_id = d.workflow_id,
    group_id = d.group_id,
    lookup = lookup or require('shortcut.buffer.story_save').cache_lookup(),
  })
  vim.list_extend(errors, create_errors)
  table.sort(errors, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.message < b.message
  end)
  return create, errors
end

--- Switch the windows showing a draft to the story created from it, and wipe the draft.
---@param buf integer
---@param id integer
local function finish(buf, id)
  if vim.api.nvim_buf_is_valid(buf) then
    -- Nothing in it is unsaved any more.
    vim.bo[buf].modified = false
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.api.nvim_win_call(win, function()
        local ok, err =
          pcall(require('shortcut.buffer.handlers').open, 'story', id, { keepalt = true })
        if not ok then
          notify.error(tostring(err))
        end
      end)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  notify.info(('Created sc-%d (:Shortcut yank copies its link)'):format(id))
end

--- Whether a failed `POST /stories` certainly created nothing: it was refused before being sent
--- (no token, invalid arguments), or answered with a 4xx. Anything else (no answer, a timeout,
--- a 5xx, a 2xx that can't be read) may have created the story.
---@param err shortcut.http.Error
---@return boolean
local function not_created(err)
  if err.kind == 'auth' or err.kind == 'invalid' then
    return true
  end
  return err.kind == 'http'
    and type(err.status) == 'number'
    and err.status >= 400
    and err.status < 500
end

--- The message for an outcome that may have created the story.
---@param why string
---@return string
local function uncertain_message(why)
  return (
    'the story may have been created (%s): check Shortcut before sending it again. '
    .. 'The draft is kept; :w refuses to send it again, :w! sends it anyway'
  ):format(why)
end

---@class shortcut.create.Outcome
---@field err? string
---@field id? integer
---@field uncertain? boolean The story may have been created.

---@class shortcut.create.Handle
---@field posting fun(): boolean Whether `POST /stories` has been sent.
---@field cancel fun(): boolean Stop before `POST /stories` is sent (`false` if it was already). `on_done` is not called.

--- Create the story of a draft from its current lines. `on_done(outcome)` runs on the main loop
--- once it is created or has failed; the draft is left as it is either way.
---@param buf integer
---@param on_done fun(outcome: shortcut.create.Outcome)
---@return shortcut.create.Handle
local function create(buf, on_done)
  local http = require('shortcut.http')
  local d = drafts[buf]
  creating[buf] = true
  -- What is created is what is in the buffer now (`:e!` meanwhile puts it back).
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  d.sending = lines
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = false
  local posting = false

  local function cleanup()
    creating[buf] = nil
    d.sending = nil
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = modifiable
    end
  end

  local task = async.run(function()
    async.await(require('shortcut.cache').load, story.REF_KINDS)
    if not vim.api.nvim_buf_is_loaded(buf) then
      return { err = 'the draft was closed; nothing was sent' }
    end
    local c, errors = M.body(buf, nil, lines)
    if #errors > 0 or not c then
      show_errors(buf, errors)
      return { err = error_summary(errors) }
    end
    if c.epic then
      local eerr = async.await(require('shortcut.api.epics').get, c.epic.id)
      if eerr then
        if eerr.status == 404 then
          local e = { line = c.epic.line, message = ('epic: no epic %d'):format(c.epic.id) }
          show_errors(buf, { e })
          return { err = error_summary({ e }) }
        end
        return {
          err = ('could not check the epic: %s; nothing was sent'):format(http.format_error(eerr)),
        }
      end
    end
    vim.diagnostic.reset(story.edit_ns(), buf)
    posting = true
    local perr, data = async.await(require('shortcut.api.stories').create, c.body)
    if perr then
      if not_created(perr) then
        return { err = ('%s; nothing was created'):format(http.format_error(perr)) }
      end
      return { err = uncertain_message(http.format_error(perr)), uncertain = true }
    end
    if type(data) ~= 'table' or type(data.id) ~= 'number' then
      return {
        err = uncertain_message('POST /stories answered without the new story'),
        uncertain = true,
      }
    end
    return { id = data.id }
  end, function(thrown, outcome)
    cleanup()
    if thrown then
      local msg = (tostring(thrown):gsub('^[^\n]-:%d+: ', '', 1))
      outcome = posting and { err = uncertain_message(msg), uncertain = true } or { err = msg }
    end
    ---@cast outcome shortcut.create.Outcome
    if outcome.id then
      d.created = outcome.id
    elseif outcome.uncertain then
      d.uncertain = outcome.err
    end
    on_done(outcome)
  end)

  return {
    posting = function()
      return posting
    end,
    cancel = function()
      if posting or task:is_done() then
        return false
      end
      task:cancel()
      cleanup()
      return true
    end,
  }
end

--- The message for a failed create.
---@param outcome shortcut.create.Outcome
---@return string
local function failure(outcome)
  if outcome.uncertain then
    return outcome.err --[[@as string]]
  end
  return ('could not create the story: %s'):format(outcome.err)
end

--- The `BufWriteCmd` of a draft.
---@param ev vim.api.keyset.create_autocmd.callback_args
function M.on_write(ev)
  local buf = ev.buf
  local d = drafts[buf]
  if not d then
    return
  end
  local name = uri.draft_name(d.n)
  local current = vim.api.nvim_buf_get_name(buf)
  if ev.match ~= name or current ~= name then
    if current ~= name then
      -- `:saveas`/`:file` renamed the buffer: give it its name back.
      pcall(vim.api.nvim_buf_set_name, buf, name)
    end
    -- An error, not a message: `:wq file` and `:x file` must not go on to quit.
    error(refusal(ev.match), 0)
  end
  if d.created then
    error(('shortcut.nvim: sc-%d was already created from this draft'):format(d.created), 0)
  end
  if creating[buf] then
    notify.warn('the story is already being created: nothing more was sent')
    return
  end
  if not focused[buf] or vim.api.nvim_get_current_buf() ~= buf then
    -- `:wall`/`:wqa` from another window: the draft may be half-written. Left modified, so
    -- `:wqa` doesn't exit.
    notify.warn(('%s was not created: only :w in its window creates the story'):format(name))
    return
  end
  if d.uncertain and vim.v.cmdbang ~= 1 then
    -- Left modified, so `:wq`/`:x` don't close it.
    notify.error(
      (
        'not sent: the last attempt may have created the story already. Check Shortcut; '
        .. ':w! sends it again (possibly creating it twice)'
      )
    )
    return
  end
  d.uncertain = nil

  local result ---@type shortcut.create.Outcome?
  local in_write = true
  local handle = create(buf, function(outcome)
    if in_write then
      result = outcome
      return
    end
    -- After the write returned (it stopped waiting).
    if outcome.err then
      notify.error(failure(outcome))
    elseif outcome.id then
      finish(buf, outcome.id)
    end
  end)
  if creating[buf] then
    vim.api.nvim_echo({ { 'shortcut.nvim: creating the story…' } }, false, {})
    vim.cmd.redraw()
    vim.wait(write_wait(), function()
      return result ~= nil
    end, 10)
  end
  in_write = false
  if not result then
    -- Interrupted (`<C-c>`), or no answer yet.
    if handle.cancel() then
      notify.warn('stopped before the story was sent: nothing was sent')
      return
    end
    -- Already sent: still modified, and the window switches once created.
    notify.warn('the story is still being created; its buffer opens once it is')
    return
  end
  if result.err then
    notify.error(failure(result))
    return
  end
  local id = result.id --[[@as integer]]
  vim.bo[buf].modified = false
  -- Not while Neovim is writing the buffer (nor before `:wq` has closed its window).
  vim.schedule(function()
    finish(buf, id)
  end)
end

--- Open a new draft in the current window (or a split, if the current buffer cannot be left).
---@param spec shortcut.create.Spec
---@return integer buf
function M.open_draft(spec)
  local show_owners = require('shortcut.config').get().tasks.show_owners
  local lines, title_line = M.render(spec.fields, { show_owners = show_owners })
  local name
  repeat
    counter = counter + 1
    name = uri.draft_name(counter)
  until vim.fn.bufexists(name) == 0
  local buf = vim.api.nvim_create_buf(true, false)
  drafts[buf] = {
    n = counter,
    workflow_id = spec.workflow_id,
    group_id = spec.group_id,
    template = lines,
    show_owners = show_owners,
  }
  vim.b[buf].shortcut_draft = counter
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].swapfile = false
  -- Lines may come from a template function or the server's names: never let them set options.
  vim.bo[buf].modeline = false
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].filetype = 'markdown'
  set_lines(buf, lines)

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    desc = 'shortcut.nvim: create the story',
    callback = M.on_write,
  })
  -- Part of the buffer (`:1,2w`, `:w >> file`): never sent, and never written anywhere.
  vim.api.nvim_create_autocmd({ 'FileWriteCmd', 'FileAppendCmd' }, {
    buffer = buf,
    desc = 'shortcut.nvim: refuse partial writes of a draft',
    callback = function(ev)
      error(refusal(ev.match), 0)
    end,
  })
  -- Not triggered when Neovim makes the buffer current for `:wall` from another window.
  vim.api.nvim_create_autocmd('BufEnter', {
    buffer = buf,
    callback = function(ev)
      focused[ev.buf] = true
    end,
  })
  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = buf,
    callback = function(ev)
      focused[ev.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function(ev)
      drafts[ev.buf] = nil
      creating[ev.buf] = nil
      focused[ev.buf] = nil
    end,
  })

  if not pcall(vim.cmd.buffer, buf) then
    vim.cmd.sbuffer(buf)
  end
  vim.api.nvim_win_set_cursor(0, { title_line, 0 })
  vim.cmd('startinsert!')
  return buf
end

--- `:Shortcut create [key=value...]`.
---@param args string[]
function M.open(args)
  local parsed = M.parse_args(args)
  M.resolve(parsed, function(err, spec)
    if err or not spec then
      return notify.error(('create: %s'):format(err))
    end
    local ok, open_err = pcall(M.open_draft, spec)
    if not ok then
      notify.error(('create: %s'):format((tostring(open_err):gsub('^[^\n]-:%d+: ', '', 1))))
    end
  end)
end

---------------------------------------------------------------------------------------------------
-- Completion
---------------------------------------------------------------------------------------------------

---@param s string
---@return string
local function escape(s)
  return (s:gsub('\\', '\\\\'):gsub(' ', '\\ '))
end

--- Names for a key's values, from the lists already loaded.
---@param key string
---@param args string[] The other arguments typed.
---@return string[]
local function values(key, args)
  local cache = require('shortcut.cache')
  local function names(kind, keep, field)
    local out = {}
    for _, item in ipairs(cache.list(kind) or {}) do
      if not keep or keep(item) then
        table.insert(out, item[field or 'name'])
      end
    end
    return out
  end
  if key == 'type' then
    return require('shortcut.buffer.story_parse').STORY_TYPES
  elseif key == 'workflow' then
    return names('workflows')
  elseif key == 'team' then
    return names('groups', function(g)
      return not g.archived
    end)
  elseif key == 'owners' then
    return names('members', function(m)
      return not m.disabled
    end, 'mention_name')
  elseif key == 'labels' then
    return names('labels', function(l)
      return not l.archived
    end)
  elseif key == 'iteration' then
    return names('iterations', function(i)
      return i.status ~= 'done'
    end)
  elseif key == 'state' then
    -- The workflow's states if it is known without asking the server, else every state name.
    local spec = require('shortcut.config').get().create.workflow
    for _, a in ipairs(args) do
      spec = a:match('^workflow=(.+)$') or spec
    end
    local workflow = spec and M.find_workflow(spec)
    local workflows = workflow and { workflow } or cache.workflows() or {}
    local out, seen = {}, {}
    for _, w in ipairs(workflows) do
      for _, s in ipairs(w.states) do
        if not seen[s.name] then
          seen[s.name] = true
          table.insert(out, s.name)
        end
      end
    end
    return out
  end
  return {}
end

--- Complete `:Shortcut create` arguments: keys, then values from the lookup lists if they are
--- loaded (they are fetched in the background otherwise, for the next try).
---@param arglead string
---@param args string[]
---@return string[]
function M.complete(arglead, args)
  local key, partial = arglead:match('^([%a_]+)=(.*)$')
  if not key then
    local out = {}
    for _, k in ipairs(M.KEYS) do
      if vim.startswith(k, arglead) then
        table.insert(out, k .. '=')
      end
    end
    return out
  end
  key = ALIASES[key] or key
  local cache = require('shortcut.cache')
  if key ~= 'type' and not cache.list('workflows') then
    pcall(cache.load, nil, function() end)
  end
  local prefix = ''
  if LIST_KEYS[key] then
    -- Complete the last item of the list.
    prefix = partial:match('^(.*,)') or ''
    partial = partial:sub(#prefix + 1)
  end
  local out = {}
  local lower = partial:lower()
  for _, v in ipairs(values(key, args)) do
    local e = escape(v)
    if vim.startswith(e:lower(), lower) then
      table.insert(out, ('%s=%s%s'):format(arglead:match('^([%a_]+)='), prefix, e))
    end
  end
  table.sort(out)
  return out
end

commands.register('create', {
  desc = 'Create a story: open a draft, :w creates it',
  run = function(args)
    M.open(args)
  end,
  complete = M.complete,
})

return M

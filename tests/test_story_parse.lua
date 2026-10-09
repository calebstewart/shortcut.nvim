-- Parsing story buffers and working out the changes: pure, tested in the test runner itself.
local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local story = require('shortcut.buffer.story')
local parse = require('shortcut.buffer.story_parse')
local diff = require('shortcut.buffer.story_diff')
local refs = require('shortcut.api.refs')

local JDOE = '00000000-0000-4000-8000-000000000101'
local ALEX = '00000000-0000-4000-8000-000000000102'
local FORMER = '00000000-0000-4000-8000-000000000103'
local GONE = '00000000-0000-4000-8000-000000000999'

local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))

---@param name string
---@return any
local function fixture(name)
  local f = assert(io.open(('%s/tests/fixtures/%s.json'):format(root, name)))
  local s = f:read('*a')
  f:close()
  return vim.json.decode(s, { luanil = { object = true, array = true } })
end

local workflows = refs.slim('workflows', fixture('workflows'))
local members = refs.slim('members', fixture('members'))
local labels = refs.slim('labels', fixture('labels'))
local iterations = refs.slim('iterations', fixture('iterations'))

---@param list table[]
---@return table<any, table>
local function index(list)
  local out = {}
  for _, x in ipairs(list) do
    out[x.id] = x
  end
  return out
end

local states = {}
for _, w in ipairs(workflows) do
  for _, s in ipairs(w.states) do
    states[s.id] = s
  end
end

--- Render refs over the fixtures.
local REFS = {
  state = function(id)
    return states[id]
  end,
  member = function(id)
    return index(members)[id]
  end,
  label = function(id)
    return index(labels)[id]
  end,
  iteration = function(id)
    return index(iterations)[id]
  end,
  epic = { id = 201, name = 'Example Epic' },
}

--- Case-insensitive lookups over the fixtures, like the cache's (without the suggestions).
---@param what string
---@param items table[]
---@param name string
---@param names_of? fun(item: table): string
local function find(what, items, name, names_of)
  names_of = names_of or function(x)
    return x.name
  end
  for _, item in ipairs(items) do
    if names_of(item):lower() == vim.trim(name):lower() then
      return item
    end
  end
  return nil, ("unknown %s '%s'"):format(what, name)
end

---@type shortcut.story_diff.Lookup
local LOOKUP = {
  state_by_name = function(workflow_id, name)
    for _, w in ipairs(workflows) do
      if w.id == workflow_id then
        return find('state', w.states, name)
      end
    end
    return nil, 'unknown workflow'
  end,
  member_by_mention = function(mention)
    return find('member', members, (mention:gsub('^@', '')), function(m)
      return m.mention_name
    end)
  end,
  label_by_name = function(name)
    return find('label', labels, name)
  end,
  iteration_by_name = function(name)
    return find('iteration', iterations, name)
  end,
  iteration = function(id)
    return index(iterations)[id]
  end,
}

--- The `story_render` fixture, modified by `patch`.
---@param patch? fun(s: table)
---@return table
local function fixture_story(patch)
  local s = fixture('story_render')
  if patch then
    patch(s)
  end
  return s
end

--- Render a story, then edit the lines with `edit` and work out the changes. Task marks follow
--- their lines as long as `edit` only replaces lines in place, unless `marks` is given.
---@param edit? fun(lines: string[])
---@param opts? { story?: table, refs?: table, show_owners?: boolean, marks?: table<integer, integer>, lookup?: table }
---@return shortcut.story_diff.Changes? changes
---@return shortcut.story_parse.Error[] errors
---@return string[] lines
local function changes(edit, opts)
  opts = opts or {}
  local s = opts.story or fixture_story()
  local show_owners = opts.show_owners ~= false
  local lines, meta = story.render(s, opts.refs or REFS, { show_owners = show_owners })
  local orig = assert(parse.parse(lines, { show_owners = show_owners }))
  local edited = vim.deepcopy(lines)
  if edit then
    edit(edited)
  end
  local cur, errors = parse.parse(edited, { show_owners = show_owners })
  if not cur then
    return nil, errors, edited
  end
  local orig_tasks = {}
  for _, t in ipairs(meta.tasks) do
    orig_tasks[t.line] = t.id
  end
  local result, diff_errors = diff.diff(orig, cur, {
    story = s,
    lookup = opts.lookup or LOOKUP,
    orig_tasks = orig_tasks,
    marks = opts.marks or vim.deepcopy(orig_tasks),
  })
  vim.list_extend(errors, diff_errors)
  return result, errors, edited
end

--- Replace the line starting with `prefix`.
---@param lines string[]
---@param prefix string
---@param line string
local function set(lines, prefix, line)
  for i, l in ipairs(lines) do
    if vim.startswith(l, prefix) then
      lines[i] = line
      return
    end
  end
  error('no line starting with ' .. prefix)
end

local NO_TASKS = { update = {}, create = {}, delete = {} }

local T = new_set()

---------------------------------------------------------------------------------------------------
-- parse()
---------------------------------------------------------------------------------------------------

T['parse()'] = new_set()

T['parse()']['reads every part of a render'] = function()
  local lines = story.render(fixture_story(), REFS)
  local p, errors = parse.parse(lines)
  eq(errors, {})
  ---@cast p shortcut.story_parse.Story
  eq(p.header, {
    id = 301,
    type = 'bug',
    state = 'In Progress',
    owners = { 'Alex.Smith', 'jdoe' },
    epic = { id = 201, text = '201 Example Epic' },
    iteration = 'Sprint 2',
    estimate = 5,
    labels = { 'Frontend', 'bug' },
    url = 'https://app.shortcut.com/example-workspace/story/301',
  })
  eq(p.header_end, 11)
  eq(p.title, 'Render me')
  eq(p.title_line, 12)
  -- A description containing `## Tasks` and a task-like line stays in the description.
  eq(p.description, 'Intro paragraph.\n\n## Tasks\n\n- [ ] not a real task, just text')
  eq(p.tasks_marker, 20)
  eq(p.comments_marker, 26)
  eq(p.tasks, {
    { line = 22, complete = true, description = 'Done task', owners = { 'jdoe' } },
    { line = 23, complete = false, description = 'Open task', owners = {} },
    { line = 24, complete = false, description = 'Shared task', owners = { 'jdoe', 'Alex.Smith' } },
  })
end

T['parse()']['empty values'] = function()
  local lines = story.render(
    fixture_story(function(s)
      s.epic_id = vim.NIL
      s.iteration_id = vim.NIL
      s.estimate = vim.NIL
      s.owner_ids = {}
      s.label_ids = {}
      s.labels = {}
      s.description = ''
      s.tasks = {}
    end),
    REFS
  )
  local p, errors = parse.parse(lines)
  eq(errors, {})
  ---@cast p shortcut.story_parse.Story
  eq(p.header.owners, {})
  eq(p.header.labels, {})
  eq(p.header.epic, nil)
  eq(p.header.iteration, nil)
  eq(p.header.estimate, nil)
  eq(p.description, '')
  eq(p.tasks, {})
  -- `~` and `null` are empty too; an estimate of 0 is not.
  lines[6] = 'epic: ~'
  lines[7] = 'iteration: null'
  lines[8] = 'estimate: 0'
  p = assert(parse.parse(lines))
  eq({ p.header.epic, p.header.iteration, p.header.estimate }, { nil, nil, 0 })
end

T['parse()']['mentions may have a leading @; values may be quoted'] = function()
  local lines = story.render(fixture_story(), REFS)
  lines[4] = 'state: "In Progress"'
  lines[5] = 'owners: [@jdoe, \'@Alex.Smith\', "x"]'
  lines[9] = 'labels: ["Frontend", \'a, b\']'
  lines[6] = "epic: '201 Example: Epic'"
  local p = assert(parse.parse(lines))
  eq(p.header.state, 'In Progress')
  eq(p.header.owners, { 'jdoe', 'Alex.Smith', 'x' })
  eq(p.header.labels, { 'Frontend', 'a, b' })
  eq(p.header.epic, { id = 201, text = '201 Example: Epic' })
end

T['parse()']['epic: an ID, with or without a name'] = function()
  local lines = story.render(fixture_story(), REFS)
  for value, expected in pairs({
    ['202'] = { id = 202, text = '202' },
    ['202 (name unavailable)'] = { id = 202, text = '202 (name unavailable)' },
    ['"203"'] = { id = 203, text = '203' },
  }) do
    lines[6] = 'epic: ' .. value
    eq(assert(parse.parse(lines)).header.epic, expected)
  end
  for _, value in ipairs({ 'Example Epic', '20x Epic', '0', '-3' }) do
    lines[6] = 'epic: ' .. value
    local _, errors = parse.parse(lines)
    eq({ value, #errors, errors[1].line }, { value, 1, 6 })
  end
end

T['parse()']['invalid header values are errors on their lines'] = function()
  local lines = story.render(fixture_story(), REFS)
  lines[3] = 'type: story'
  lines[4] = 'state:'
  lines[8] = 'estimate: -1'
  local _, errors = parse.parse(lines)
  eq(errors, {
    { line = 3, message = "type: 'story' is not a story type (use feature, bug, chore)" },
    { line = 4, message = 'state: a story needs a workflow state' },
    { line = 8, message = "estimate: expected a non-negative integer, got '-1'" },
  })
  lines = story.render(fixture_story(), REFS)
  lines[8] = 'estimate: 2.5'
  lines[9] = 'labels: [a, ""]'
  lines[3] = 'type: [bug]'
  _, errors = parse.parse(lines)
  eq(errors, {
    { line = 3, message = 'type: expected a single value, not a list' },
    { line = 8, message = "estimate: expected a non-negative integer, got '2.5'" },
    { line = 9, message = 'labels: empty name' },
  })
end

T['parse()']['unknown and missing header keys are errors'] = function()
  local lines = story.render(fixture_story(), REFS)
  lines[8] = 'points: 3'
  local _, errors = parse.parse(lines)
  eq(errors, {
    {
      line = 8,
      message = "unknown header field 'points' (fields: "
        .. table.concat(story.FIELDS, ', ')
        .. ')',
    },
    { line = 11, message = "missing header field 'estimate'; :e! reloads the story" },
  })
end

T['parse()']['an unreadable header is one error'] = function()
  local lines = story.render(fixture_story(), REFS)
  lines[5] = 'owners: [jdoe'
  local p, errors = parse.parse(lines)
  eq(p, nil)
  eq(errors, { { line = 5, message = "owners: unterminated list: missing ']'" } })
end

T['parse()']['missing markers suggest :e!'] = function()
  local lines = story.render(fixture_story(), REFS)
  for i, l in ipairs(lines) do
    if l == story.TASKS_MARKER then
      table.remove(lines, i)
      break
    end
  end
  local p, errors = parse.parse(lines)
  eq(p, nil)
  eq(#errors, 1)
  eq(errors[1].message:find(story.TASKS_MARKER, 1, true) ~= nil, true)
  eq(errors[1].message:find(':e!', 1, true) ~= nil, true)

  lines = story.render(fixture_story(), REFS)
  lines[26] = '## Comments marker removed'
  p, errors = parse.parse(lines)
  eq(p, nil)
  eq(errors[1].message:find(story.COMMENTS_MARKER, 1, true) ~= nil, true)
end

T['parse()']['title: required, right after the header'] = function()
  local lines = story.render(fixture_story(), REFS)
  lines[12] = '# '
  local _, errors = parse.parse(lines)
  eq(errors, { { line = 12, message = 'the title cannot be empty' } })
  lines[12] = 'Not a title'
  _, errors = parse.parse(lines)
  eq(errors, { { line = 12, message = "expected the title ('# <title>') right after the header" } })
  -- Blank lines before it are fine.
  lines[12] = ''
  table.insert(lines, 13, '#   Spaced title   ')
  local p = assert(parse.parse(lines))
  eq({ p.title, p.title_line }, { 'Spaced title', 13 })
  lines[12] = '# ' .. ('é'):rep(513)
  table.remove(lines, 13)
  _, errors = parse.parse(lines)
  eq(errors, { { line = 12, message = 'the title is too long (at most 512 characters)' } })
end

T['parse()']['description: verbatim, without surrounding blank lines'] = function()
  local lines = story.render(fixture_story(), REFS)
  lines[14] = '  Indented, trailing spaces  '
  table.insert(lines, 13, '')
  table.insert(lines, 20, '   ')
  local p = assert(parse.parse(lines))
  eq(p.description, '  Indented, trailing spaces  \n\n## Tasks\n\n- [ ] not a real task, just text')
end

T['parse()']['tasks: checkboxes, owners, blank lines and the heading'] = function()
  local lines = story.render(fixture_story(), REFS)
  lines[22] = '* [X] Upper-case x'
  lines[23] = '  - [ ]   padded   '
  lines[24] = '- [ ] a · b · @jdoe   @Alex.Smith'
  table.insert(lines, 25, '')
  table.insert(lines, 25, '- [ ] middle dot · not owners')
  table.insert(lines, 25, '- [ ] no owners after it ·')
  local p = assert(parse.parse(lines))
  eq(p.tasks, {
    { line = 22, complete = true, description = 'Upper-case x', owners = {} },
    { line = 23, complete = false, description = 'padded', owners = {} },
    { line = 24, complete = false, description = 'a · b', owners = { 'jdoe', 'Alex.Smith' } },
    { line = 25, complete = false, description = 'no owners after it ·', owners = {} },
    { line = 26, complete = false, description = 'middle dot · not owners', owners = {} },
  })
end

T['parse()']['tasks: with owners hidden, the whole text is the description'] = function()
  local lines = story.render(fixture_story(), REFS)
  local p = assert(parse.parse(lines, { show_owners = false }))
  eq(p.tasks[1], { line = 22, complete = true, description = 'Done task · @jdoe', owners = {} })
end

T['parse()']['tasks: other lines are errors with their line numbers'] = function()
  local lines = story.render(fixture_story(), REFS)
  lines[23] = 'just some text'
  table.insert(lines, 24, '- [?] odd checkbox')
  table.insert(lines, 24, '- [ ]')
  table.insert(lines, 24, '- [ ]x')
  local p, errors = parse.parse(lines)
  eq(errors, {
    { line = 23, message = "not a task: task lines look like '- [ ] description'" },
    { line = 24, message = "not a task: expected a space after '[ ]'" },
    { line = 25, message = 'a task needs a description' },
    { line = 26, message = "invalid checkbox '[?]': use '[ ]' or '[x]'" },
  })
  -- The task without a description is still returned, so it keeps its identity.
  ---@cast p shortcut.story_parse.Story
  eq(p.tasks[2], { line = 25, complete = false, description = '', owners = {} })
end

T['parse()']['everything below the comments marker is ignored'] = function()
  local lines = story.render(fixture_story(), REFS)
  local before = assert(parse.parse(lines))
  table.insert(lines, 'random text')
  table.insert(lines, '- [ ] not a task')
  table.insert(lines, 'owners: nope')
  lines[28] = 'edited comment'
  local p, errors = parse.parse(lines)
  eq(errors, {})
  eq(p, before)
end

T['split_owners()'] = function()
  local s = parse.split_owners
  eq({ s('a') }, { 'a', {} })
  eq({ s('a · @x') }, { 'a', { 'x' } })
  eq({ s('a · @x @y') }, { 'a', { 'x', 'y' } })
  eq({ s('a · @x y') }, { 'a · @x y', {} })
  eq({ s('a · @x · @y') }, { 'a · @x', { 'y' } })
  eq({ s('a · ') }, { 'a ·', {} })
  eq({ s('a·@x') }, { 'a·@x', {} })
end

---------------------------------------------------------------------------------------------------
-- diff()
---------------------------------------------------------------------------------------------------

T['diff()'] = new_set()

T['diff()']['an untouched buffer has no changes'] = function()
  local c, errors = changes()
  eq(errors, {})
  ---@cast c shortcut.story_diff.Changes
  eq(c, { story = {}, fields = {}, tasks = NO_TASKS })
  eq(diff.is_empty(c), true)
  -- Nor with owners hidden.
  c = changes(nil, { show_owners = false })
  eq(diff.is_empty(assert(c)), true)
end

T['diff()']['each field edit gives exactly that field'] = function()
  local cases = {
    { '# Render me', '# New title', { name = 'New title' }, 'title' },
    {
      'Intro paragraph.',
      'New intro.',
      {
        description = 'New intro.\n\n## Tasks\n\n- [ ] not a real task, just text',
      },
      'description',
    },
    { 'type:', 'type: feature', { story_type = 'feature' }, 'type' },
    { 'state:', 'state: Done', { workflow_state_id = 503 }, 'state' },
    { 'owners:', 'owners: [jdoe]', { owner_ids = { JDOE } }, 'owners' },
    { 'owners:', 'owners: []', { owner_ids = {} }, 'owners' },
    { 'epic:', 'epic: 202', { epic_id = 202 }, 'epic' },
    { 'epic:', 'epic:', { epic_id = vim.NIL }, 'epic' },
    { 'iteration:', 'iteration: Sprint 1', { iteration_id = 701 }, 'iteration' },
    { 'iteration:', 'iteration: 701', { iteration_id = 701 }, 'iteration' },
    { 'iteration:', 'iteration:', { iteration_id = vim.NIL }, 'iteration' },
    { 'estimate:', 'estimate: 8', { estimate = 8 }, 'estimate' },
    { 'estimate:', 'estimate: 0', { estimate = 0 }, 'estimate' },
    { 'estimate:', 'estimate:', { estimate = vim.NIL }, 'estimate' },
    { 'labels:', 'labels: [bug]', { labels = { { name = 'bug' } } }, 'labels' },
    { 'labels:', 'labels: []', { labels = {} }, 'labels' },
    {
      'labels:',
      'labels: [FRONTEND, bug, old-label]',
      { labels = { { name = 'Frontend' }, { name = 'bug' }, { name = 'old-label' } } },
      'labels',
    },
  }
  for _, case in ipairs(cases) do
    local prefix, line, body, field = case[1], case[2], case[3], case[4] ---@type string, string, table, string
    local c, errors = changes(function(lines)
      set(lines, prefix, line)
    end)
    eq({ line, errors }, { line, {} })
    ---@cast c shortcut.story_diff.Changes
    eq({ line, c.story, c.fields, c.tasks, c.epic and c.epic.id }, {
      line,
      body,
      { field },
      NO_TASKS,
      body.epic_id ~= vim.NIL and body.epic_id or nil,
    })
  end
end

T['diff()']['whitespace, case and order differences are not changes'] = function()
  local c, errors = changes(function(lines)
    set(lines, 'type:', 'type:   bug   ')
    set(lines, 'state:', 'state:   in progress')
    set(lines, 'owners:', 'owners: [ @JDOE ,alex.smith, jdoe ]')
    set(lines, 'epic:', 'epic:  201   Renamed or not')
    set(lines, 'iteration:', 'iteration: sprint 2 ')
    set(lines, 'estimate:', 'estimate:   5 # five')
    set(lines, 'labels:', 'labels: [bug,FRONTEND]')
    set(lines, '# Render me', '#   Render me   ')
    set(lines, '- [ ] Shared task', '-   [ ]   Shared task ·   @Alex.Smith @jdoe  ')
    table.insert(lines, 13, '')
  end, { marks = { [23] = 311, [24] = 312, [25] = 313 } })
  eq(errors, {})
  eq(diff.is_empty(assert(c)), true)
end

T['diff()']['unknown-<id> placeholders never make changes'] = function()
  local s = fixture_story(function(x)
    x.owner_ids = { GONE, JDOE }
    x.label_ids = { 699, 601 }
    x.labels = { { id = 601, name = 'bug' } }
    x.tasks[1].owner_ids = { GONE }
  end)
  -- Nothing resolvable: every name is a placeholder.
  local c, errors, lines = changes(nil, { story = s, refs = {} })
  eq(lines[4], 'state: unknown-502')
  eq(lines[5], ('owners: [unknown-%s, unknown-%s]'):format(GONE, JDOE))
  eq(errors, {})
  eq(diff.is_empty(assert(c)), true)

  -- Editing another field sends only that one.
  c, errors = changes(function(l)
    set(l, 'estimate:', 'estimate: 1')
  end, { story = s, refs = {} })
  eq(errors, {})
  eq(assert(c).story, { estimate = 1 })

  -- Editing owners keeps the placeholders' IDs.
  c, errors = changes(function(l)
    set(l, 'owners:', ('owners: [unknown-%s, Alex.Smith]'):format(GONE))
  end, { story = s, refs = REFS })
  eq(errors, {})
  eq(assert(c).story, { owner_ids = { GONE, ALEX } })

  -- A placeholder the story doesn't refer to is an unknown member.
  c, errors = changes(function(l)
    set(l, 'owners:', 'owners: [unknown-00000000-0000-4000-8000-000000000555]')
  end, { story = s, refs = REFS })
  eq(errors, {
    {
      line = 5,
      message = "owners: unknown member 'unknown-00000000-0000-4000-8000-000000000555'",
    },
  })

  -- Labels are saved by name: a label without one can't be kept.
  c, errors = changes(function(l)
    set(l, 'labels:', 'labels: [unknown-699, bug, Frontend]')
  end, { story = s, refs = REFS })
  eq(#errors, 1)
  eq(errors[1].line, 9)
  eq(vim.startswith(errors[1].message, "labels: label 'unknown-699' has no known name"), true)
end

T['diff()']['id and url are read-only'] = function()
  local _, errors = changes(function(lines)
    set(lines, 'id:', 'id: 302')
    set(lines, 'url:', 'url: https://example.com')
  end)
  eq(errors, {
    { line = 2, message = 'id: read-only: it cannot be changed (undo the edit, or :e! to reload)' },
    {
      line = 10,
      message = 'url: read-only: it cannot be changed (undo the edit, or :e! to reload)',
    },
  })
end

T['diff()']['names that cannot be resolved are errors on their lines'] = function()
  local c, errors = changes(function(lines)
    set(lines, 'state:', 'state: Shipped') -- a state of another workflow
    set(lines, 'owners:', 'owners: [jdoe, nobody, former]')
    set(lines, 'iteration:', 'iteration: Sprint 9')
    set(lines, 'labels:', 'labels: [bug, brand-new]')
  end)
  eq(errors, {
    { line = 4, message = "state: unknown state 'Shipped'" },
    { line = 5, message = "owners: member '@former' is disabled in the workspace" },
    { line = 5, message = "owners: unknown member 'nobody'" },
    { line = 7, message = "iteration: unknown iteration 'Sprint 9'" },
    { line = 9, message = "labels: unknown label 'brand-new'" },
  })
  -- Nothing is planned for them.
  eq(assert(c).story, {})
end

T['diff()']['labels the story has are known even if the cache does not have them'] = function()
  local s = fixture_story(function(x)
    x.label_ids = { 650, 601 }
    x.labels = { { id = 650, name = 'Fresh' }, { id = 601, name = 'bug' } }
  end)
  local c, errors = changes(function(lines)
    set(lines, 'labels:', 'labels: [fresh, Frontend]')
  end, { story = s })
  eq(errors, {})
  eq(assert(c).story, { labels = { { name = 'Fresh' }, { name = 'Frontend' } } })
end

T['diff()']['a disabled member who already owns the story may stay'] = function()
  local s = fixture_story(function(x)
    x.owner_ids = { FORMER }
  end)
  local c, errors = changes(function(lines)
    set(lines, 'owners:', 'owners: [former, jdoe]')
  end, { story = s })
  eq(errors, {})
  eq(assert(c).story, { owner_ids = { FORMER, JDOE } })
end

T['diff()']['a numeric iteration is an ID, or else a name'] = function()
  local iteration_named_1 = vim.tbl_extend('force', LOOKUP, {
    iteration_by_name = function(name)
      return name == '1' and { id = 777, name = '1' } or nil, 'unknown'
    end,
  })
  local c = changes(function(lines)
    set(lines, 'iteration:', 'iteration: 1')
  end, { lookup = iteration_named_1 })
  eq(assert(c).story, { iteration_id = 777 })
end

T['diff()']['tasks'] = new_set()

T['diff()']['tasks']['toggle, edit and owners'] = function()
  local c, errors = changes(function(lines)
    lines[22] = '- [ ] Done task · @jdoe'
    lines[23] = '- [x] Open task, edited · @Alex.Smith'
    lines[24] = '- [ ] Shared task'
  end)
  eq(errors, {})
  eq(assert(c).tasks, {
    update = {
      { id = 311, line = 22, description = 'Done task', fields = { complete = false } },
      {
        id = 312,
        line = 23,
        description = 'Open task, edited',
        fields = { complete = true, description = 'Open task, edited', owner_ids = { ALEX } },
      },
      { id = 313, line = 24, description = 'Shared task', fields = { owner_ids = {} } },
    },
    create = {},
    delete = {},
  })
  eq(diff.summary(assert(c)), '3 tasks updated')
end

T['diff()']['tasks']['changing owners'] = function()
  local c = changes(function(lines)
    lines[22] = '- [x] Done task · @Alex.Smith'
    lines[24] = '- [ ] Shared task · @ALEX.SMITH @JDoe'
  end)
  -- Reordered (and recased) owners are not a change.
  eq(assert(c).tasks.update, {
    { id = 311, line = 22, description = 'Done task', fields = { owner_ids = { ALEX } } },
  })
end

T['diff()']['tasks']['unknown or disabled owners are errors on the task line'] = function()
  local _, errors = changes(function(lines)
    lines[23] = '- [ ] Open task · @nobody'
    table.insert(lines, 25, '- [ ] New · @former')
  end, { marks = { [22] = 311, [23] = 312, [24] = 313 } })
  eq(errors, {
    { line = 23, message = "unknown member 'nobody'" },
    { line = 25, message = "member '@former' is disabled in the workspace" },
  })
end

T['diff()']['tasks']['lines without a mark are new; tasks without one are deleted'] = function()
  local c, errors = changes(function(lines)
    table.remove(lines, 23)
    table.insert(lines, 24, '- [x] Brand new · @jdoe')
    table.insert(lines, 22, '- [ ] First new')
  end, { marks = { [23] = 311, [24] = 313 } })
  eq(errors, {})
  ---@cast c shortcut.story_diff.Changes
  eq(c.tasks, {
    update = {},
    create = {
      { line = 22, fields = { description = 'First new', complete = false } },
      { line = 25, fields = { description = 'Brand new', complete = true, owner_ids = { JDOE } } },
    },
    delete = { { id = 312, description = 'Open task' } },
  })
  eq(c.story, {})
  eq(diff.summary(c), '2 tasks added, 1 task deleted')
end

T['diff()']['tasks']['a mark on a line that is no longer a task deletes the task'] = function()
  local c = changes(function(lines)
    lines[23] = ''
  end)
  eq(assert(c).tasks.delete, { { id = 312, description = 'Open task' } })
end

T['diff()']['tasks']['with owners hidden, owners never change'] = function()
  local c = changes(function(lines)
    lines[22] = '- [ ] Done task'
  end, { show_owners = false })
  eq(assert(c).tasks.update, {
    { id = 311, line = 22, description = 'Done task', fields = { complete = false } },
  })
  -- Text that looks like owners is part of the description.
  c = changes(function(lines)
    lines[23] = '- [ ] Open task · @jdoe'
  end, { show_owners = false })
  eq(assert(c).tasks.update[1].fields, { description = 'Open task · @jdoe' })
  c = changes(function(lines)
    table.insert(lines, 25, '- [ ] New · @jdoe')
  end, { show_owners = false })
  eq(assert(c).tasks.create, {
    { line = 25, fields = { description = 'New · @jdoe', complete = false } },
  })
end

T['diff()']['tasks']['a task rendered without a description keeps its identity'] = function()
  local s = fixture_story(function(x)
    x.tasks[1].description = '' -- task 313, rendered last
  end)
  local c, errors = changes(nil, { story = s })
  eq(errors, { { line = 24, message = 'a task needs a description' } })
  c, errors = changes(function(lines)
    lines[24] = '- [ ] Now described · @jdoe @Alex.Smith'
  end, { story = s })
  eq(errors, {})
  eq(assert(c).tasks, {
    update = {
      {
        id = 313,
        line = 24,
        description = 'Now described',
        fields = { description = 'Now described' },
      },
    },
    create = {},
    delete = {},
  })
end

T['diff()']['summary()'] = function()
  local c = changes(function(lines)
    set(lines, '# Render me', '# x')
    set(lines, 'state:', 'state: Done')
    lines[23] = '- [x] Open task'
  end)
  eq(diff.summary(assert(c)), 'title, state, 1 task updated')
end

return T

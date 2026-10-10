-- The help file: `:helptags` accepts it, its links resolve, and it documents every command,
-- option and highlight group (so it can't silently fall behind the code).
local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local DOC = 'doc/shortcut.txt'

local T = new_set()

---@return string[]
local function doc_lines()
  return vim.fn.readfile(DOC)
end

--- Run `:helptags` on a copy of doc/, so no `tags` file is written into the repository.
---@return table<string, true> tags
local function helptags()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. '/doc', 'p')
  vim.fn.writefile(doc_lines(), dir .. '/doc/shortcut.txt')
  vim.v.errmsg = ''
  local ok, err = pcall(vim.cmd.helptags, vim.fn.fnameescape(dir .. '/doc'))
  eq({ ok = ok, err = not ok and err or nil, errmsg = vim.v.errmsg }, { ok = true, errmsg = '' })
  local tags = {}
  for _, line in ipairs(vim.fn.readfile(dir .. '/doc/tags')) do
    tags[line:match('^[^\t]+')] = true
  end
  return tags
end

T[':helptags accepts it, without duplicate tags'] = function()
  local tags = helptags()
  eq(tags['shortcut.txt'], true)
  eq(tags['shortcut'], true)
end

T['every |link| resolves'] = function()
  local tags = helptags()
  -- Neovim's own help.
  for _, line in ipairs(vim.fn.readfile(vim.env.VIMRUNTIME .. '/doc/tags')) do
    tags[line:match('^[^\t]+')] = true
  end
  local missing = {}
  local in_code = false
  for i, line in ipairs(doc_lines()) do
    -- Code blocks (`>` at the end of a line, until a line starting with `<`) have no links.
    if in_code and (line:match('^<') or line:match('^%S')) then
      in_code = false
    end
    if not in_code then
      for link in line:gmatch('|([^|%s]+)|') do
        if not tags[link] then
          table.insert(missing, ('line %d: |%s|'):format(i, link))
        end
      end
    end
    if line:match('%s>%a*$') or line:match('^>%a*$') then
      in_code = true
    end
  end
  eq(missing, {})
end

T['documents every :Shortcut subcommand'] = function()
  local tags = helptags()
  local missing = {}
  for _, name in ipairs(require('shortcut.commands').names()) do
    if not tags[':Shortcut-' .. name] then
      table.insert(missing, name)
    end
  end
  eq(missing, {})
end

T['documents every option'] = function()
  local tags = helptags()
  local missing = {}
  for _, name in ipairs(require('shortcut.config').option_names()) do
    if not tags['shortcut-config.' .. name] then
      table.insert(missing, name)
    end
  end
  eq(missing, {})
  -- And no option that doesn't exist.
  local known = {}
  for _, name in ipairs(require('shortcut.config').option_names()) do
    known['shortcut-config.' .. name] = true
  end
  for tag in pairs(tags) do
    if vim.startswith(tag, 'shortcut-config.') then
      eq({ tag = tag, known = known[tag] }, { tag = tag, known = true })
    end
  end
end

T['documents every highlight group'] = function()
  local tags = helptags()
  local picker = require('shortcut.picker')
  local groups = { 'ShortcutId', 'ShortcutOwners', picker.STATE_HL_OTHER }
  vim.list_extend(groups, vim.tbl_values(picker.STATE_HL))
  for _, marker in pairs(picker.TYPE_MARKERS) do
    table.insert(groups, marker[2])
  end
  picker.define_highlights()
  local missing = {}
  for _, group in ipairs(groups) do
    if not tags['hl-' .. group] then
      table.insert(missing, group)
    end
  end
  eq(missing, {})
  -- And no group the plugin doesn't define.
  for tag in pairs(tags) do
    local group = tag:match('^hl%-(.*)$')
    if group then
      eq({ group = group, defined = vim.fn.hlexists(group) }, { group = group, defined = 1 })
    end
  end
end

T['lines fit in 78 columns'] = function()
  local long = {}
  for i, line in ipairs(doc_lines()) do
    if vim.fn.strdisplaywidth(line) > 78 then
      table.insert(long, ('line %d (%d)'):format(i, vim.fn.strdisplaywidth(line)))
    end
  end
  eq(long, {})
end

T['has the tags issue #13 asks for'] = function()
  local tags = helptags()
  local missing = {}
  for _, tag in ipairs({
    'shortcut',
    'shortcut-config',
    'shortcut-buffers',
    'shortcut-commands',
    'shortcut-pickers',
    'shortcut-troubleshooting',
    ':Shortcut',
    ':Shortcut-search',
  }) do
    if not tags[tag] then
      table.insert(missing, tag)
    end
  end
  eq(missing, {})
end

T['the README lists every subcommand'] = function()
  local readme = table.concat(vim.fn.readfile('README.md'), '\n')
  local missing = {}
  for _, name in ipairs(require('shortcut.commands').names()) do
    -- The whole word: `:Shortcut epics` doesn't count for `epic`.
    if not readme:find('`:Shortcut ' .. vim.pesc(name) .. '[`%s]') then
      table.insert(missing, name)
    end
  end
  eq(missing, {})
end

-- The documentation site (docs/) is written by hand from the README and the help file. These read
-- its Markdown directly, so they run without Zola (CI has no Nix); `nix build .#docs` checks the
-- rest (templates, and that every `@/` link and anchor resolves).
T['site'] = new_set()

---@param page string
---@return string
local function site_page(page)
  return table.concat(vim.fn.readfile('docs/content/' .. page), '\n')
end

--- The first cells of a page's table rows that are a single code span: `| `name` | ...`.
---@param page string
---@return table<string, true>
local function site_table_keys(page)
  local keys = {}
  for _, line in ipairs(vim.fn.readfile('docs/content/' .. page)) do
    local key = line:match('^| `([^`]+)` |')
    if key then
      keys[key] = true
    end
  end
  return keys
end

T['site']['the commands page lists every subcommand'] = function()
  local page = site_page('commands.md')
  local missing = {}
  for _, name in ipairs(require('shortcut.commands').names()) do
    -- In the table, as `:Shortcut <name>` followed by its arguments or the closing backtick.
    if not page:find('\n| `:Shortcut ' .. vim.pesc(name) .. '[`%s]') then
      table.insert(missing, name)
    end
  end
  eq(missing, {})
end

T['site']['the configuration page lists every option, and only those'] = function()
  local rows = site_table_keys('configuration.md')
  local known, missing = {}, {}
  for _, name in ipairs(require('shortcut.config').option_names()) do
    known[name] = true
    if not rows[name] then
      table.insert(missing, name)
    end
  end
  eq(missing, {})
  -- The options table is the only one whose first column is a bare identifier; the Lua API
  -- table's entries are calls.
  local unknown = {}
  for key in pairs(rows) do
    if not known[key] and not key:find('(', 1, true) then
      table.insert(unknown, key)
    end
  end
  eq(unknown, {})
end

T['site']['the searching page lists every highlight group, and only those'] = function()
  local picker = require('shortcut.picker')
  picker.define_highlights()
  local rows = site_table_keys('searching.md')
  local groups = { 'ShortcutId', 'ShortcutOwners', picker.STATE_HL_OTHER }
  vim.list_extend(groups, vim.tbl_values(picker.STATE_HL))
  for _, marker in pairs(picker.TYPE_MARKERS) do
    table.insert(groups, marker[2])
  end
  local missing = {}
  for _, group in ipairs(groups) do
    if not rows[group] then
      table.insert(missing, group)
    end
  end
  eq(missing, {})
  for key in pairs(rows) do
    if key:match('^Shortcut') then
      eq({ group = key, defined = vim.fn.hlexists(key) }, { group = key, defined = 1 })
    end
  end
end

T['site']['has no root-relative links'] = function()
  -- The site is served from a sub-path (https://calebstew.art/shortcut.nvim/): `/foo/` would
  -- resolve against the domain root and 404. Internal links use `@/page.md` or `get_url`.
  local bad = {}
  for _, dir in ipairs({ 'docs/content', 'docs/templates' }) do
    for _, path in ipairs(vim.fn.globpath(dir, '*', false, true)) do
      for i, line in ipairs(vim.fn.readfile(path)) do
        if line:find('%]%(/') or line:find('href="/') or line:find('src="/') then
          table.insert(bad, ('%s:%d'):format(path, i))
        end
      end
    end
  end
  eq(bad, {})
end

return T

--- Parsing and formatting of the names that refer to Shortcut objects.
---
--- Pure string functions with no Neovim state. Accepted forms:
---
--- - `shortcut://story/<id>`, `shortcut://epic/<id>`: canonical buffer names.
--- - `shortcut://id/<id>`: an object whose kind is not known yet (see `canonical('id', id)`).
--- - `http(s)://app.shortcut.com/<workspace>/(story|epic)/<id>[/<slug>][/][?query][#fragment]`
--- - `sc-<id>`: kind not known yet.
---
--- `shortcut://story/<id>/comment` names the buffer of a comment being written (see
--- `shortcut.buffer.comment`); `parse()` rejects it, `comment_name()`/`parse_comment_name()`
--- handle it.
---
--- `shortcut://story/new-<n>` names a draft of a new story (see `shortcut.buffer.story_create`):
--- `parse()` returns it as kind `'draft'`, with `id` the draft's number. Only `:Shortcut create`
--- makes such buffers; it is not an object on Shortcut, and is never loaded from there.
local M = {}

---@alias shortcut.Kind 'story'|'epic'

---@class shortcut.uri.Target
---@field kind shortcut.Kind|'id'|'draft' `'id'` when the kind is not known yet (`sc-<id>`),
--- `'draft'` for a new story's draft (`shortcut://story/new-<n>`, `id` is `n`).
---@field id integer
---@field workspace? string Workspace slug, for web URLs only.
---@field comment? integer Comment ID from a web URL fragment.

local HOST = 'app.shortcut.com'

---@type table<string, true>
local KINDS = { story = true, epic = true }

--- Fragments that point at a comment.
---
--- UNVERIFIED: the format of Shortcut's comment links has not been confirmed against the web app.
--- `#activity-<id>` is the best guess; keep any correction confined to this table.
local COMMENT_FRAGMENTS = { '^activity%-(%d+)$' }

--- Largest ID accepted (2^53 - 1), so IDs stay exact integers. `shortcut.api` uses the same
--- bound.
M.MAX_ID = 2 ^ 53 - 1
local MAX_ID = M.MAX_ID

---@param s string?
---@return integer?
local function to_id(s)
  if not s or not s:match('^%d+$') then
    return nil
  end
  local n = tonumber(s)
  if not n or n < 1 or n > MAX_ID then
    return nil
  end
  return n
end

---@param fragment string
---@return integer?
local function parse_comment(fragment)
  for _, pattern in ipairs(COMMENT_FRAGMENTS) do
    local id = to_id(fragment:match(pattern))
    if id then
      return id
    end
  end
  return nil
end

---@param str string
---@return shortcut.uri.Target?
local function parse_web(str)
  local scheme, rest = str:match('^(%a+)://(.*)$')
  if not scheme or (scheme:lower() ~= 'https' and scheme:lower() ~= 'http') then
    return nil
  end

  local fragment = rest:match('#(.*)$') or ''
  rest = rest:gsub('#.*$', ''):gsub('%?.*$', '')

  local host, path = rest:match('^([^/]+)(/.*)$')
  if not host or host:lower() ~= HOST then
    return nil
  end

  local segments = vim.split(path:gsub('^/', ''):gsub('/$', ''), '/', { plain = true })
  if #segments < 3 or #segments > 4 then
    return nil
  end
  local workspace, kind, id = segments[1], segments[2], to_id(segments[3])
  if workspace == '' or not KINDS[kind] or not id or segments[4] == '' then
    return nil
  end

  return { kind = kind, id = id, workspace = workspace, comment = parse_comment(fragment) }
end

--- Parse a reference to a Shortcut object.
---@param str string
---@return shortcut.uri.Target? target `nil` if `str` is not a recognised form.
function M.parse(str)
  if type(str) ~= 'string' then
    return nil
  end

  local sc_id = str:match('^sc%-(%d+)$')
  if sc_id then
    local id = to_id(sc_id)
    return id and { kind = 'id', id = id } or nil
  end

  local kind, digits = str:match('^shortcut://(%l+)/(%d+)$')
  if kind then
    local id = to_id(digits)
    if id and (KINDS[kind] or kind == 'id') then
      return { kind = kind, id = id }
    end
    return nil
  end

  local draft = to_id(str:match('^shortcut://story/new%-(%d+)$'))
  if draft then
    return { kind = 'draft', id = draft }
  end

  return parse_web(str)
end

--- The buffer name for an object. For `kind = 'id'` this is the not-yet-resolved form, which
--- the buffer handlers redirect to the real one.
---@param kind shortcut.Kind|'id'
---@param id integer
---@return string
function M.canonical(kind, id)
  return ('shortcut://%s/%d'):format(kind, id)
end

--- The name of the buffer for writing a comment on a story.
---@param id integer
---@return string
function M.comment_name(id)
  return ('shortcut://story/%d/comment'):format(id)
end

--- The story ID of a comment buffer name, or `nil` if `str` is not one.
---@param str any
---@return integer?
function M.parse_comment_name(str)
  if type(str) ~= 'string' then
    return nil
  end
  return to_id(str:match('^shortcut://story/(%d+)/comment$'))
end

--- The name of the buffer of draft number `n` of a new story.
---@param n integer
---@return string
function M.draft_name(n)
  return ('shortcut://story/new-%d'):format(n)
end

--- Whether `kind` is a real object kind (not `'id'`).
---@param kind string
---@return boolean
function M.is_kind(kind)
  return KINDS[kind] == true
end

return M

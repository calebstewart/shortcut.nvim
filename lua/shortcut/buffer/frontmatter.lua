--- Reading and writing the YAML front matter at the top of story/epic buffers.
---
--- Only a small subset of YAML is supported, the one `serialize()` writes:
---
--- ```yaml
--- ---
--- key: scalar
--- key: [item, item]
--- key:
--- ---
--- ```
---
--- - Values are integers, strings, lists of those, or empty (`nil`). `~` and `null` are empty
---   too; an empty list is `[]`.
--- - Strings are written plain unless YAML would read them differently (see `needs_quotes()`), in
---   which case they are double-quoted. The parser also accepts single-quoted strings, and drops
---   a leading `@` from unquoted list items (mentions are written without it, since a plain YAML
---   value cannot start with `@`, but users may type one).
--- - Blank lines and `#` comments are allowed. Anything else (nested maps, block lists,
---   multi-line strings, anchors...) is an error.
---
--- Pure: no buffer or editor state is used.
local M = {}

--- A value as written and parsed. `nil` is an empty value.
---@alias shortcut.frontmatter.Scalar integer|string
---@alias shortcut.frontmatter.Value shortcut.frontmatter.Scalar|shortcut.frontmatter.Scalar[]

M.DELIMITER = '---'

--- Plain scalars YAML (1.1 or 1.2) reads as booleans or null.
local KEYWORDS = {}
for _, w in ipairs({ 'true', 'false', 'yes', 'no', 'on', 'off', 'y', 'n', 'null', '~' }) do
  KEYWORDS[w] = true
end

--- Whether a plain scalar would be read as a number (int, float, hex, octal, binary,
--- sexagesimal, infinity, NaN) by some YAML parser.
---@param s string
---@return boolean
local function numeric(s)
  local body = s:gsub('^[-+]', '')
  if body:match('^[%d_]+$') then
    return true
  end
  if body:match('^0[xX][%x_]+$') or body:match('^0[oO][0-7_]+$') or body:match('^0[bB][01_]+$') then
    return true
  end
  -- Floats: digits with a dot and/or an exponent, as long as there is a digit.
  local mantissa, exponent = body:match('^([%d_]*%.?[%d_]*)(.*)$')
  if
    mantissa
    and mantissa:find('%d')
    and (exponent == '' and mantissa:find('%.') or exponent:match('^[eE][-+]?%d+$'))
  then
    return true
  end
  -- Sexagesimal (YAML 1.1): 1:30, 1:30:15.5
  if body:match('^%d+[:%d]*:[0-5]?%d%.?%d*$') then
    return true
  end
  local lower = body:lower()
  return lower == '.inf' or lower == '.nan'
end

--- Whether `s` must be double-quoted to be read back as the same string.
---@param s string
---@param in_list boolean Inside a `[...]` flow list, where `,[]{}` are special too.
---@return boolean
function M.needs_quotes(s, in_list)
  if s == '' or s:match('^%s') or s:match('%s$') then
    return true
  end
  -- Control characters (including newlines and tabs) can only be written escaped.
  if s:find('%c') then
    return true
  end
  if s:find(': ', 1, true) or s:sub(-1) == ':' or s:find(' #', 1, true) then
    return true
  end
  -- Indicator characters that cannot start a plain scalar.
  if s:match('^[%[%]{}"\'@&*!|>%%#`,]') then
    return true
  end
  -- `-`, `?` and `:` start a plain scalar only when followed by a non-space.
  if s:match('^[-?:]$') or s:match('^[-?:] ') then
    return true
  end
  if in_list and s:find('[,%[%]{}]') then
    return true
  end
  if KEYWORDS[s:lower()] or numeric(s) then
    return true
  end
  return false
end

local ESCAPES = { ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n', ['\t'] = '\\t', ['\r'] = '\\r' }

---@param s string
---@return string
local function quote(s)
  return '"'
    .. s:gsub('[%c\\"]', function(c)
      return ESCAPES[c] or ('\\x%02X'):format(c:byte())
    end)
    .. '"'
end

---@param v any
---@return boolean
local function is_integer(v)
  return type(v) == 'number' and v == math.floor(v) and v > -2 ^ 53 and v < 2 ^ 53
end

---@param key string
---@param v any
---@param in_list boolean
---@return string
local function scalar(key, v, in_list)
  if is_integer(v) then
    return ('%d'):format(v)
  elseif type(v) == 'string' then
    return M.needs_quotes(v, in_list) and quote(v) or v
  end
  error(('front matter: cannot write %s for %s'):format(type(v), key), 0)
end

--- Write `fields` as front matter, with the keys in `order` (keys missing from `fields` are
--- written empty; keys not in `order` are not written). Includes both `---` lines.
---@param fields table<string, shortcut.frontmatter.Value?>
---@param order string[]
---@return string[]
function M.serialize(fields, order)
  vim.validate('fields', fields, 'table')
  vim.validate('order', order, 'table')
  local lines = { M.DELIMITER }
  for _, key in ipairs(order) do
    if not key:match('^[%w_][%w_-]*$') then
      error(('front matter: invalid key %q'):format(key), 0)
    end
    local v = fields[key]
    if v == nil or v == vim.NIL then
      table.insert(lines, key .. ':')
    elseif type(v) == 'table' then
      local items = {}
      for i, item in ipairs(v) do
        items[i] = scalar(key, item, true)
      end
      table.insert(lines, ('%s: [%s]'):format(key, table.concat(items, ', ')))
    else
      table.insert(lines, ('%s: %s'):format(key, scalar(key, v, false)))
    end
  end
  table.insert(lines, M.DELIMITER)
  return lines
end

---------------------------------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------------------------------

--- Parse error carrying a column-free message; the caller adds the line number.
---@param msg string
local function fail(msg)
  error({ msg = msg }, 0)
end

local UNESCAPES = {
  ['\\'] = '\\',
  ['"'] = '"',
  ['/'] = '/',
  ['n'] = '\n',
  ['t'] = '\t',
  ['r'] = '\r',
  ['0'] = '\0',
  [' '] = ' ',
}

--- UTF-8 encoding of a code point below U+10000.
---@param code integer
---@return string
local function utf8_char(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  end
  return string.char(
    0xE0 + math.floor(code / 0x1000),
    0x80 + math.floor(code / 0x40) % 0x40,
    0x80 + code % 0x40
  )
end

--- Read a quoted string starting at `pos` (on the quote). Returns the string and the position
--- after the closing quote.
---@param s string
---@param pos integer
---@return string value
---@return integer next
local function read_quoted(s, pos)
  local q = s:sub(pos, pos)
  local out = {}
  local i = pos + 1
  while i <= #s do
    local c = s:sub(i, i)
    if q == "'" then
      if c == "'" then
        if s:sub(i + 1, i + 1) == "'" then
          table.insert(out, "'")
          i = i + 2
        else
          return table.concat(out), i + 1
        end
      else
        table.insert(out, c)
        i = i + 1
      end
    elseif c == '"' then
      return table.concat(out), i + 1
    elseif c == '\\' then
      local e = s:sub(i + 1, i + 1)
      if UNESCAPES[e] then
        table.insert(out, UNESCAPES[e])
        i = i + 2
      elseif e == 'x' or e == 'u' then
        local n = e == 'x' and 2 or 4
        local hex = s:sub(i + 2, i + 1 + n)
        if #hex ~= n or not hex:match('^%x+$') then
          fail(('invalid escape \\%s%s'):format(e, hex))
        end
        local code = tonumber(hex, 16) --[[@as integer]]
        table.insert(out, e == 'x' and string.char(code) or utf8_char(code))
        i = i + 2 + n
      else
        fail(('invalid escape \\%s'):format(e))
      end
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  fail(('unterminated %s-quoted string'):format(q == '"' and 'double' or 'single'))
  error('unreachable')
end

--- A plain (unquoted) scalar's value: integers become numbers, `~`/`null` nil.
---@param s string Trimmed, non-empty.
---@return shortcut.frontmatter.Scalar?
local function plain(s)
  if s:match('^[-+]?%d+$') then
    local n = tonumber(s)
    if n and is_integer(n) then
      return n
    end
  end
  if s == '~' or s == 'null' or s == 'Null' or s == 'NULL' then
    return nil
  end
  return s
end

--- Remove a trailing ` # comment` from a plain value.
---@param s string
---@return string
local function strip_comment(s)
  local pos = s:find('%s#')
  if pos then
    s = s:sub(1, pos - 1)
  end
  return vim.trim(s)
end

--- Check that only whitespace or a comment follows position `pos`.
---@param s string
---@param pos integer
local function expect_end(s, pos)
  local rest = s:sub(pos)
  if not (rest:match('^%s*$') or rest:match('^%s+#')) then
    fail(('unexpected text after the value: %s'):format(vim.trim(rest)))
  end
end

--- Parse a `[a, b]` flow list starting at `pos` (on the `[`).
---@param s string
---@param pos integer
---@return shortcut.frontmatter.Scalar[]
local function read_list(s, pos)
  local items = {}
  local i = pos + 1
  while true do
    i = s:find('%S', i) or #s + 1
    local c = s:sub(i, i)
    if c == '' then
      fail("unterminated list: missing ']'")
    elseif c == ']' then
      expect_end(s, i + 1)
      return items
    elseif c == ',' then
      fail('empty list item')
    elseif c == '[' or c == '{' then
      fail('nested lists and maps are not supported')
    end
    local value
    if c == '"' or c == "'" then
      value, i = read_quoted(s, i)
    else
      local stop = s:find('[,%]]', i) or #s + 1
      local raw = vim.trim(s:sub(i, stop - 1))
      if raw:find(' #', 1, true) or raw:find('[%[{}]') then
        fail(('invalid list item: %s'):format(raw))
      end
      -- Mentions may be typed with their `@`.
      raw = raw:gsub('^@', '')
      if raw == '' then
        fail('empty list item')
      end
      value = plain(raw)
      if value == nil then
        fail(('empty list item: %s'):format(raw))
      end
      i = stop
    end
    table.insert(items, value)
    i = s:find('%S', i) or #s + 1
    c = s:sub(i, i)
    if c == ',' then
      i = i + 1
      -- A trailing comma before `]` is allowed.
    elseif c ~= ']' then
      fail(c == '' and "unterminated list: missing ']'" or "expected ',' or ']' in list")
    end
  end
end

--- Parse one value (the text after `key:`).
---@param s string
---@return shortcut.frontmatter.Value?
local function read_value(s)
  local i = s:find('%S')
  if not i or s:sub(i, i) == '#' then
    return nil
  end
  local c = s:sub(i, i)
  if c == '[' then
    return read_list(s, i)
  elseif c == '"' or c == "'" then
    local value, next = read_quoted(s, i)
    expect_end(s, next)
    return value
  elseif c == '{' then
    fail('maps are not supported')
  elseif c == '|' or c == '>' then
    fail('multi-line strings are not supported')
  elseif c == '&' or c == '*' or c == '!' then
    fail('anchors, aliases and tags are not supported')
  end
  return plain(strip_comment(s))
end

--- Parse the front matter at the start of `lines`.
---
--- On success returns the fields (keys to values; empty values are absent), the index of the
--- first line after the closing `---`, and the line number of each key. On failure returns
--- `nil`, a message and the 1-based number of the offending line.
---@param lines string[]
---@return table<string, shortcut.frontmatter.Value>? fields
---@return integer|string body_start_or_err
---@return table<string, integer>|integer key_lines_or_lnum
function M.parse(lines)
  vim.validate('lines', lines, 'table')
  if vim.trim(lines[1] or '') ~= M.DELIMITER then
    return nil, "missing front matter: the first line must be '---'", 1
  end
  local fields, key_lines = {}, {}
  for lnum = 2, #lines do
    local line = lines[lnum]
    if line:match('^%-%-%-%s*$') then
      return fields, lnum + 1, key_lines
    end
    if not (line:match('^%s*$') or line:match('^%s*#')) then
      local key, rest = line:match('^([%w_][%w_-]*)%s*:(.*)$')
      if not key or (rest ~= '' and not rest:match('^%s')) then
        if line:match('^%s') then
          return nil, 'indented lines are not supported', lnum
        end
        return nil, "expected 'key: value'", lnum
      end
      if key_lines[key] then
        return nil, ("duplicate key '%s' (first on line %d)"):format(key, key_lines[key]), lnum
      end
      local ok, value = pcall(read_value, rest)
      if not ok then
        local msg = type(value) == 'table' and value --[[@as { msg: string }]].msg
          or tostring(value)
        return nil, ('%s: %s'):format(key, msg), lnum
      end
      key_lines[key] = lnum
      fields[key] = value
    end
  end
  return nil, "missing front matter: no closing '---'", #lines
end

return M

-- The front matter module is pure: tested in the test runner itself.
local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local fm = require('shortcut.buffer.frontmatter')

local T = new_set()

---@param fields table
---@param order string[]
local function round_trip(fields, order)
  local lines = fm.serialize(fields, order)
  local parsed, body_start = fm.parse(lines)
  eq(parsed, fields)
  eq(body_start, #lines + 1)
  return lines
end

T['serialize()'] = new_set()

T['serialize()']['writes keys in order, empty values and lists'] = function()
  eq(
    fm.serialize({
      id = 12345,
      type = 'feature',
      state = 'In Progress',
      owners = { 'someone', 'someone-else' },
      estimate = 3,
      labels = {},
      url = 'https://app.shortcut.com/acme/story/12345',
    }, { 'id', 'type', 'state', 'owners', 'epic', 'estimate', 'labels', 'url' }),
    {
      '---',
      'id: 12345',
      'type: feature',
      'state: In Progress',
      'owners: [someone, someone-else]',
      'epic:',
      'estimate: 3',
      'labels: []',
      'url: https://app.shortcut.com/acme/story/12345',
      '---',
    }
  )
end

T['serialize()']['leaves ordinary strings plain'] = function()
  for _, s in ipairs({
    '678 Some epic',
    'Sprint 42',
    'a:b',
    'C#',
    'x-y',
    '-x',
    'v1.2.3',
    'Ünïcødé',
    "it's",
    'say "hi"',
    '2026-10-01',
  }) do
    eq(fm.serialize({ k = s }, { 'k' })[2], 'k: ' .. s)
  end
end

T['serialize()']['quotes strings YAML would read differently'] = function()
  local cases = {
    { 'a: b', '"a: b"' },
    { 'ends with:', '"ends with:"' },
    { 'a #b', '"a #b"' },
    { ' lead', '" lead"' },
    { 'trail ', '"trail "' },
    { '', '""' },
    { '[x', '"[x"' },
    { '{x', '"{x"' },
    { '"q"', '"\\"q\\""' },
    { "'q'", '"\'q\'"' },
    { '@someone', '"@someone"' },
    { '&anchor', '"&anchor"' },
    { '*alias', '"*alias"' },
    { '!tag', '"!tag"' },
    { '|', '"|"' },
    { '>', '">"' },
    { '%x', '"%x"' },
    { '#x', '"#x"' },
    { '`x', '"`x"' },
    { '- x', '"- x"' },
    { '-', '"-"' },
    { '? x', '"? x"' },
    { '12', '"12"' },
    { '-3', '"-3"' },
    { '1.5', '"1.5"' },
    { '1e3', '"1e3"' },
    { '0x1F', '"0x1F"' },
    { '0o17', '"0o17"' },
    { '1_000', '"1_000"' },
    { '1:30', '"1:30"' },
    { '.inf', '".inf"' },
    { '.NaN', '".NaN"' },
    { 'true', '"true"' },
    { 'False', '"False"' },
    { 'yes', '"yes"' },
    { 'off', '"off"' },
    { 'null', '"null"' },
    { '~', '"~"' },
    { 'a\nb', '"a\\nb"' },
    { 'tab\there', '"tab\\there"' },
    { 'back\\slash: x', '"back\\\\slash: x"' },
    { 'bell\7', '"bell\\x07"' },
  }
  for _, c in ipairs(cases) do
    eq({ c[1], fm.serialize({ k = c[1] }, { 'k' })[2] }, { c[1], 'k: ' .. c[2] })
  end
end

T['serialize()']['quotes flow indicators in list items only'] = function()
  eq(fm.serialize({ k = 'a, b [c]' }, { 'k' })[2], 'k: a, b [c]')
  eq(
    fm.serialize({ k = { 'a, b', 'c]', 'd{', 'plain' } }, { 'k' })[2],
    'k: ["a, b", "c]", "d{", plain]'
  )
end

T['serialize()']['rejects values it cannot write'] = function()
  expect.error(function()
    fm.serialize({ k = 1.5 }, { 'k' })
  end, 'cannot write number for k')
  expect.error(function()
    fm.serialize({ k = true } --[[@as table]], { 'k' })
  end, 'cannot write boolean')
  expect.error(function()
    fm.serialize({ k = { { 'nested' } } } --[[@as table]], { 'k' })
  end, 'cannot write table')
  expect.error(function()
    fm.serialize({}, { 'bad key' })
  end, 'invalid key')
end

T['round trip'] = new_set()

T['round trip']['a story header'] = function()
  round_trip({
    id = 101,
    type = 'feature',
    state = 'In Progress',
    owners = { 'jdoe', 'Alex.Smith' },
    epic = '201 Example Epic',
    iteration = 'Sprint 2',
    estimate = 0,
    labels = { 'bug', 'Frontend', 'needs review', 'a, b', '@at', '42' },
    url = 'https://app.shortcut.com/example-workspace/story/101',
  }, { 'id', 'type', 'state', 'owners', 'epic', 'iteration', 'estimate', 'labels', 'url' })
end

T['round trip']['empty values'] = function()
  local lines = round_trip({ id = 1, labels = {} }, { 'id', 'epic', 'iteration', 'labels' })
  eq(lines[3], 'epic:')
end

T['round trip']['every quoting trigger'] = function()
  local strings = {
    'a: b',
    'x #y',
    ' a',
    'a ',
    '',
    '[a]',
    '{a}',
    '"',
    "'",
    '@x',
    '&x',
    '*x',
    '!x',
    '|x',
    '>x',
    '%x',
    '#x',
    '12',
    '-7',
    '+7',
    '3.25',
    '6e10',
    '0xff',
    'true',
    'NO',
    'null',
    '~',
    'multi\nline\r\n',
    'tab\t',
    '\\',
    'ctrl\1',
    'ünï "çødé"',
    '1:30',
    'a,b',
    '- a',
    ':',
    '?',
  }
  for _, s in ipairs(strings) do
    round_trip({ scalar = s, list = { s, 'x' } }, { 'scalar', 'list' })
    -- Also in the middle and at the end of a list.
    round_trip({ list = { 'x', s, s } }, { 'list' })
  end
end

T['round trip']['integers, including negative and large ones'] = function()
  round_trip({ a = 0, b = -5, c = 9007199254740991, d = { 1, 2, 'three' } }, { 'a', 'b', 'c', 'd' })
end

T['parse()'] = new_set()

T['parse()']['returns the fields, the first body line and key lines'] = function()
  local fields, body_start, key_lines = fm.parse({
    '---',
    'id: 7',
    '',
    '# a comment',
    'state: Done  # trailing comment',
    'owners: [a, b]   # comment',
    'empty:',
    'tilde: ~',
    'null: null',
    'list: []',
    '---',
    '# Title',
  })
  eq(fields, { id = 7, state = 'Done', owners = { 'a', 'b' }, list = {} })
  eq(body_start, 12)
  eq(key_lines, {
    id = 2,
    state = 5,
    owners = 6,
    empty = 7,
    tilde = 8,
    null = 9,
    list = 10,
  })
end

T['parse()']['tolerates single quotes, spacing, a leading @ and trailing commas'] = function()
  local fields = fm.parse({
    '---',
    "owners: [ @someone ,'@quoted', \"@kept\",  'it''s'  , plain words, ]",
    "state:   'In Progress'   ",
    'key :  value',
    'at: @scalar',
    '---  ',
  })
  eq(fields, {
    owners = { 'someone', '@quoted', '@kept', "it's", 'plain words' },
    state = 'In Progress',
    key = 'value',
    at = '@scalar',
  })
end

T['parse()']['reads escapes in double quotes'] = function()
  local fields = fm.parse({ '---', [[k: "a\"b\\c\nd\te\x41é\/"]], '---' })
  eq(fields, { k = 'a"b\\c\nd\teA\195\169/' })
end

T['parse()']['keeps numbers in quotes as strings and plain floats as strings'] = function()
  local fields = fm.parse({ '---', 'a: "3"', 'b: 3', 'c: 3.5', 'd: +4', 'e: [1, "1"]', '---' })
  eq(fields, { a = '3', b = 3, c = '3.5', d = 4, e = { 1, '1' } })
end

T['parse()']['reports errors with line numbers'] = function()
  local cases = {
    { { 'id: 1' }, 1, 'missing front matter' },
    { {}, 1, 'missing front matter' },
    { { '---', 'id: 1' }, 2, "no closing '---'" },
    { { '---', 'just text', '---' }, 2, "expected 'key: value'" },
    { { '---', 'key:value', '---' }, 2, "expected 'key: value'" },
    { { '---', '  nested: 1', '---' }, 2, 'indented lines' },
    { { '---', 'a: 1', 'b: 2', 'a: 3', '---' }, 4, "duplicate key 'a' (first on line 2)" },
    { { '---', 'k: [a, b', '---' }, 2, "missing ']'" },
    { { '---', 'k: [a, , b]', '---' }, 2, 'empty list item' },
    { { '---', 'k: [a b] c', '---' }, 2, 'unexpected text after the value' },
    { { '---', 'k: [[a]]', '---' }, 2, 'nested lists' },
    { { '---', 'k: [a, ~]', '---' }, 2, 'empty list item' },
    { { '---', 'k: [a, @]', '---' }, 2, 'empty list item' },
    { { '---', 'k: {a: 1}', '---' }, 2, 'maps are not supported' },
    { { '---', 'k: |', '---' }, 2, 'multi-line strings' },
    { { '---', 'k: &a x', '---' }, 2, 'anchors' },
    { { '---', 'k: "open', '---' }, 2, 'unterminated double-quoted string' },
    { { '---', "k: 'open", '---' }, 2, 'unterminated single-quoted string' },
    { { '---', 'k: "a" b', '---' }, 2, 'unexpected text after the value: b' },
    { { '---', 'k: "\\q"', '---' }, 2, 'invalid escape \\q' },
    { { '---', 'k: "\\x4"', '---' }, 2, 'invalid escape' },
    { { '---', 'k: ["a" "b"]', '---' }, 2, "expected ',' or ']'" },
  }
  for _, c in ipairs(cases) do
    local fields, msg, lnum = fm.parse(c[1])
    eq({ fields, lnum }, { nil, c[2] })
    if not tostring(msg):find(c[3], 1, true) then
      error(('%q does not contain %q'):format(tostring(msg), c[3]))
    end
  end
end

T['parse()']['prefixes value errors with the key'] = function()
  local _, msg = fm.parse({ '---', 'owners: [a, , b]', '---' })
  eq(msg, 'owners: empty list item')
end

return T

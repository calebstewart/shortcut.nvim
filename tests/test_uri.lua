local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local uri = require('shortcut.uri')

local T = new_set()

local valid = {
  -- canonical names
  { 'shortcut://story/123', { kind = 'story', id = 123 } },
  { 'shortcut://epic/45', { kind = 'epic', id = 45 } },
  { 'shortcut://id/7', { kind = 'id', id = 7 } },
  { 'shortcut://story/007', { kind = 'story', id = 7 } },
  -- sc-<id>
  { 'sc-123', { kind = 'id', id = 123 } },
  { 'sc-1', { kind = 'id', id = 1 } },
  -- web URLs: https and http, with and without slug, trailing slash, query and fragment
  {
    'https://app.shortcut.com/acme/story/123',
    { kind = 'story', id = 123, workspace = 'acme' },
  },
  {
    'http://app.shortcut.com/acme/story/123',
    { kind = 'story', id = 123, workspace = 'acme' },
  },
  {
    'https://app.shortcut.com/acme/story/123/',
    { kind = 'story', id = 123, workspace = 'acme' },
  },
  {
    'https://app.shortcut.com/acme/story/123/fix-the-thing',
    { kind = 'story', id = 123, workspace = 'acme' },
  },
  {
    'https://app.shortcut.com/acme/story/123/fix-the-thing/',
    { kind = 'story', id = 123, workspace = 'acme' },
  },
  {
    'https://app.shortcut.com/acme/story/123/fix-the-thing?ct_workflow=all&vc_group_by=day',
    { kind = 'story', id = 123, workspace = 'acme' },
  },
  {
    'https://app.shortcut.com/acme/story/123?x=1#activity-456',
    { kind = 'story', id = 123, workspace = 'acme', comment = 456 },
  },
  {
    'https://app.shortcut.com/acme/story/123/slug#activity-456',
    { kind = 'story', id = 123, workspace = 'acme', comment = 456 },
  },
  {
    'https://app.shortcut.com/acme/story/123/slug#unrelated',
    { kind = 'story', id = 123, workspace = 'acme' },
  },
  {
    'https://app.shortcut.com/acme/epic/45/big-epic',
    { kind = 'epic', id = 45, workspace = 'acme' },
  },
  {
    'HTTPS://App.Shortcut.com/acme/epic/45',
    { kind = 'epic', id = 45, workspace = 'acme' },
  },
}

T['parse()'] = new_set()

T['parse()']['accepts'] = new_set({ parametrize = valid }, {
  test = function(input, expected)
    eq(uri.parse(input), expected)
  end,
})

local invalid = {
  { 'sc-' },
  { 'sc-12a' },
  { 'sc-0' },
  { 'xsc-12' },
  { 'sc-12 ' },
  { 'SC-12' },
  { '123' },
  { '' },
  { 'shortcut://story/' },
  { 'shortcut://story/abc' },
  { 'shortcut://story/1/2' },
  { 'shortcut://iteration/1' },
  { 'shortcut://Story/1' },
  { 'https://app.shortcut.com/acme/story/abc' },
  { 'https://app.shortcut.com/acme/story/' },
  { 'https://app.shortcut.com/acme/iteration/12' },
  { 'https://app.shortcut.com/acme/stories/space/12' },
  { 'https://app.shortcut.com/story/12' },
  { 'https://app.shortcut.com/acme/story/12/slug/extra' },
  { 'https://app.shortcut.com/acme/settings' },
  { 'https://example.com/acme/story/12' },
  { 'https://app.shortcut.com.evil.com/acme/story/12' },
  { 'https://notapp.shortcut.com/acme/story/12' },
  { 'ftp://app.shortcut.com/acme/story/12' },
  { 'https://app.clubhouse.io/acme/story/12' },
}

T['parse()']['rejects'] = new_set({ parametrize = invalid }, {
  test = function(input)
    eq(uri.parse(input), nil)
  end,
})

T['parse()']['rejects non-strings'] = function()
  ---@diagnostic disable: param-type-mismatch
  eq(uri.parse(nil), nil)
  eq(uri.parse(123), nil)
  ---@diagnostic enable: param-type-mismatch
end

T['canonical()'] = function()
  eq(uri.canonical('story', 123), 'shortcut://story/123')
  eq(uri.canonical('epic', 4), 'shortcut://epic/4')
  eq(uri.canonical('id', 9), 'shortcut://id/9')
end

T['canonical() round-trips through parse()'] = function()
  for _, kind in ipairs({ 'story', 'epic', 'id' }) do
    eq(uri.parse(uri.canonical(kind, 42)), { kind = kind, id = 42 })
  end
end

return T

local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local URL = 'https://app.shortcut.com/acme/story/123/some-slug'

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua([[
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end

        -- Never touch the network: record what the built-in net plugin would fetch.
        _G.requests = {}
        vim.net.request = function(url) table.insert(_G.requests, url); return { close = function() end } end
        local executable = vim.fn.executable
        vim.fn.executable = function(name) return name == 'curl' and 1 or executable(name) end

        _G.handlers = require('shortcut.buffer.handlers')

        -- Work in a scratch directory with a known starting buffer.
        _G.dir = vim.fn.tempname() .. '/'
        vim.fn.mkdir(_G.dir, 'p')
        vim.cmd.cd(vim.fn.fnameescape(_G.dir))
        vim.fn.writefile({ 'start' }, 'start.txt')
        vim.cmd.edit('start.txt')
      ]])
    end,
    post_once = child.stop,
  },
})

--- Let scheduled callbacks (the switch away from temporary buffers) run.
local function settle()
  child.lua('vim.wait(20)')
end

local function edit(name)
  child.cmd('edit ' .. child.fn.fnameescape(name))
  settle()
end

local function bufname(buf)
  return child.lua_get('vim.fn.fnamemodify(vim.api.nvim_buf_get_name(...), ":t")', { buf or 0 })
end

local function cur_name()
  return child.api.nvim_buf_get_name(0)
end

local function alt_name()
  return child.lua_get([[vim.fn.fnamemodify(vim.fn.bufname('#'), ':t')]])
end

local function lines(buf)
  return child.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

--- Names of all buffers, sorted.
local function buffers()
  local names = child.lua_get([[vim.tbl_map(function(b)
    local name = vim.api.nvim_buf_get_name(b)
    return name:match('^%a+://') and name or vim.fn.fnamemodify(name, ':t')
  end, vim.api.nvim_list_bufs())]])
  table.sort(names)
  return names
end

local function messages()
  return child.lua_get('_G.messages')
end

--- Register a loader that records its calls and finishes immediately.
local function record_loads(kind)
  child.lua(
    [[
    local kind = ...
    _G.loads = _G.loads or {}
    handlers.register(kind, {
      load = function(buf, id, opts, done)
        table.insert(_G.loads, { kind = kind, id = id, opts = opts })
        done(nil, { kind .. ' ' .. id })
      end,
    })
  ]],
    { kind }
  )
end

local function loads()
  return child.lua_get('_G.loads or {}')
end

T['shortcut://'] = new_set()

T['shortcut://']['loads with the placeholder'] = function()
  edit('shortcut://story/42')
  eq(cur_name(), 'shortcut://story/42')
  eq(lines(), { '# Story 42', '', 'Rendering stories is not implemented yet.' })
  eq(child.bo.buftype, 'acwrite')
  eq(child.bo.swapfile, false)
  eq(child.bo.filetype, 'markdown')
  eq(child.bo.modifiable, true)
  eq(child.bo.modified, false)
  eq(child.b.shortcut, { kind = 'story', id = 42 })
  -- Loading is not undoable.
  eq(child.fn.undotree().seq_last, 0)

  edit('shortcut://epic/7')
  eq(lines(), { '# Epic 7', '', 'Rendering epics is not implemented yet.' })
  eq(child.b.shortcut, { kind = 'epic', id = 7 })
end

T['shortcut://']['shows a loading message while an async load runs'] = function()
  child.lua([[
    handlers.register('story', {
      load = function(buf, id, opts, done) _G.finish = function() done(nil, { 'loaded ' .. id }) end end,
    })
  ]])
  edit('shortcut://story/5')
  eq(lines(), { 'Loading sc-5…' })
  eq(child.bo.modifiable, false)
  child.lua('_G.finish()')
  eq(lines(), { 'loaded 5' })
  eq(child.bo.modifiable, true)
  eq(child.bo.modified, false)
end

T['shortcut://']['accepts results delivered from a fast event'] = function()
  child.lua([[
    handlers.register('story', {
      load = function(buf, id, opts, done)
        local timer = vim.uv.new_timer()
        timer:start(1, 0, function() timer:close(); done(nil, { 'from timer' }) end)
      end,
    })
  ]])
  edit('shortcut://story/5')
  child.lua(
    [[vim.wait(1000, function() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'from timer' end)]]
  )
  eq(lines(), { 'from timer' })
end

T['shortcut://']['shows and reports load errors'] = function()
  child.lua([[
    handlers.register('story', { load = function(buf, id, opts, done) done('boom') end })
  ]])
  edit('shortcut://story/5')
  eq(lines(), { 'Failed to load sc-5:', '', 'boom' })
  eq(child.bo.modifiable, false)
  eq(child.bo.modified, false)
  eq(messages(), {
    {
      msg = 'shortcut.nvim: failed to load sc-5: boom',
      level = child.lua_get('vim.log.levels.ERROR'),
    },
  })
end

T['shortcut://']['reports loaders that throw'] = function()
  child.lua([[handlers.register('epic', { load = function() error('kaboom', 0) end })]])
  edit('shortcut://epic/5')
  eq(lines(), { 'Failed to load sc-5:', '', 'kaboom' })
end

T['shortcut://'][':e! reloads and ignores superseded results'] = function()
  child.lua([[
    _G.pending = {}
    handlers.register('story', {
      load = function(buf, id, opts, done) table.insert(_G.pending, done) end,
    })
  ]])
  edit('shortcut://story/5')
  child.cmd('edit!')
  eq(child.lua_get('#_G.pending'), 2)
  child.lua([[_G.pending[2](nil, { 'second' })]])
  child.lua([[_G.pending[1](nil, { 'first' })]])
  eq(lines(), { 'second' })
end

T['shortcut://']['a non-canonical spelling switches to the canonical buffer'] = function()
  edit('shortcut://story/0042')
  eq(cur_name(), 'shortcut://story/42')
  eq(buffers(), { 'shortcut://story/42', 'start.txt' })
end

T['shortcut://'][':w calls the saver'] = function()
  child.lua([[
    _G.saves = {}
    handlers.register('story', {
      load = function(buf, id, opts, done) done(nil, { 'text' }) end,
      save = function(buf, id, opts, done)
        table.insert(_G.saves, { id = id, force = opts.force, text = vim.api.nvim_buf_get_lines(buf, 0, -1, false) })
        _G.finish_save = done
      end,
    })
  ]])
  edit('shortcut://story/5')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited' })
  child.cmd('write')
  eq(child.bo.modified, true)
  child.lua('_G.finish_save("nope")')
  eq(child.bo.modified, true)
  eq(messages()[1].msg, 'shortcut.nvim: failed to save sc-5: nope')

  child.cmd('write!')
  child.lua('_G.finish_save()')
  eq(child.bo.modified, false)
  eq(child.lua_get('_G.saves'), {
    { id = 5, force = false, text = { 'edited' } },
    { id = 5, force = true, text = { 'edited' } },
  })
end

T['shortcut://'][':w keeps modified if the buffer changed during the save'] = function()
  child.lua([[
    handlers.register('story', {
      load = function(buf, id, opts, done) done(nil, { 'text' }) end,
      save = function(buf, id, opts, done) _G.finish_save = done end,
    })
  ]])
  edit('shortcut://story/5')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited' })
  child.cmd('write')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited again' })
  child.lua('_G.finish_save()')
  eq(child.bo.modified, true)
end

T['shortcut://'][':w with the placeholder says saving is unsupported'] = function()
  edit('shortcut://story/5')
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited' })
  child.cmd('write')
  eq(child.bo.modified, true)
  eq(messages()[1].msg, 'shortcut.nvim: failed to save sc-5: saving stories is not supported yet')
end

T['shortcut://'][':w is refused unless the load succeeded'] = function()
  child.lua([[
    _G.saves = 0
    _G.pending = {}
    handlers.register('story', {
      load = function(buf, id, opts, done) table.insert(_G.pending, done) end,
      save = function(buf, id, opts, done) _G.saves = _G.saves + 1; done() end,
    })
  ]])
  edit('shortcut://story/6')

  -- In flight: the buffer holds the loading message.
  child.cmd('write')
  eq(child.lua_get('_G.saves'), 0)
  eq(messages()[1].msg, 'shortcut.nvim: sc-6 is still loading')

  -- Failed: the buffer holds the error message.
  child.lua([[_G.pending[1]('boom')]])
  child.lua('_G.messages = {}')
  child.cmd('write!')
  eq(child.lua_get('_G.saves'), 0)
  eq(messages(), {
    {
      msg = 'shortcut.nvim: sc-6 is not loaded; :e! to retry',
      level = child.lua_get('vim.log.levels.ERROR'),
    },
  })

  -- :e! again: in flight, and the failed load finishing late changes nothing.
  child.cmd('edit!')
  child.lua([[_G.pending[1]('late')]])
  child.cmd('write')
  eq(child.lua_get('_G.saves'), 0)

  child.lua([[_G.pending[2](nil, { 'loaded' })]])
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited' })
  child.cmd('write')
  eq(child.lua_get('_G.saves'), 1)
  eq(child.bo.modified, false)
end

T['shortcut://']['register() validates its arguments'] = function()
  expect.error(function()
    child.lua([[handlers.register('iteration', { load = function() end })]])
  end, 'kind')
  expect.error(function()
    child.lua([[handlers.register('story', {})]])
  end, 'handler.load')
end

T['redirects'] = new_set({
  parametrize = {
    { URL, 'story', 123 },
    { 'http://app.shortcut.com/acme/story/123', 'story', 123 },
    { 'https://app.shortcut.com/acme/epic/9/slug?x=1#frag', 'epic', 9 },
    { 'sc-123', 'story', 123 },
    { 'shortcut://id/123', 'story', 123 },
  },
})

T['redirects']['end on the canonical buffer with the alternate file restored'] = function(
  name,
  kind,
  id
)
  edit(name)
  eq(cur_name(), ('shortcut://%s/%d'):format(kind, id))
  eq(alt_name(), 'start.txt')
  eq(buffers(), { ('shortcut://%s/%d'):format(kind, id), 'start.txt' })
  eq(child.lua_get('_G.requests'), {})
  eq(messages(), {})

  -- <C-^> goes back.
  child.type_keys('<C-^>')
  eq(bufname(), 'start.txt')
end

T['redirects']['reuse an open buffer'] = function(name, kind, id)
  record_loads(kind)
  local canonical = ('shortcut://%s/%d'):format(kind, id)
  edit(canonical)
  local buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved edit' })
  edit('start.txt')

  edit(name)
  eq(child.api.nvim_get_current_buf(), buf)
  eq(lines(), { 'unsaved edit' })
  eq(#loads(), 1)
  eq(alt_name(), 'start.txt')
  eq(buffers(), { canonical, 'start.txt' })
end

T['redirects']['work in a split'] = function(name, kind, id)
  child.cmd('split ' .. child.fn.fnameescape(name))
  settle()
  eq(cur_name(), ('shortcut://%s/%d'):format(kind, id))
  eq(#child.api.nvim_list_wins(), 2)
  eq(alt_name(), 'start.txt')
  eq(buffers(), { ('shortcut://%s/%d'):format(kind, id), 'start.txt' })
end

T['redirects']['close a temporary buffer not shown in any window'] = function(name, _, _)
  child.lua('vim.fn.bufload(vim.fn.bufadd(...))', { name })
  settle()
  eq(bufname(), 'start.txt')
  eq(buffers(), { 'start.txt' })
  eq(messages(), {})
end

T['redirect details'] = new_set()

T['redirect details']['pass the comment anchor to the loader'] = function()
  record_loads('story')
  edit(URL .. '#activity-77')
  eq(loads(), { { kind = 'story', id = 123, opts = { comment = 77 } } })
end

T['redirect details']['jump to the comment in an already-open buffer'] = function()
  child.lua([[
    _G.jumps = {}
    handlers.register('story', {
      load = function(buf, id, opts, done) done(nil, { 'x' }) end,
      jump = function(buf, comment) table.insert(_G.jumps, { vim.api.nvim_buf_get_name(buf), comment }) end,
    })
  ]])
  edit('shortcut://story/123')
  edit(URL .. '#activity-77')
  eq(child.lua_get('_G.jumps'), { { 'shortcut://story/123', 77 } })
end

T['redirect details']['work from the command line'] = function()
  -- Files on the command line are read before VimEnter, with the net plugin sourced after this
  -- one: only the guard in our own handler stops the download.
  child.restart({
    '--cmd',
    'lua _G.requests = {}; vim.net.request = function(url) table.insert(_G.requests, url) end',
    '--cmd',
    'lua _G.messages = {}; vim.notify = function(msg) table.insert(_G.messages, msg) end',
    '-u',
    'tests/minimal_init.lua',
    URL,
  })
  child.lua(
    [[vim.wait(1000, function() return vim.api.nvim_buf_get_name(0) == 'shortcut://story/123' end)]]
  )
  eq(cur_name(), 'shortcut://story/123')
  eq(buffers(), { 'shortcut://story/123' })
  eq(child.lua_get('_G.requests'), {})
  eq(messages(), {})
end

T['workspace'] = new_set()

T['workspace']['warns when the URL is for another workspace'] = function()
  child.lua([[handlers.set_slug_source(function(done) done('other') end)]])
  edit(URL)
  eq(cur_name(), 'shortcut://story/123')
  local msgs = messages()
  eq(#msgs, 1)
  eq(msgs[1].level, child.lua_get('vim.log.levels.WARN'))
  expect.no_error(function()
    assert(msgs[1].msg:find("workspace 'acme'", 1, true))
  end)
end

T['workspace']['does not warn for the same workspace or an unknown slug'] = function()
  child.lua([[handlers.set_slug_source(function(done) done('ACME') end)]])
  edit(URL)
  child.lua([[handlers.set_slug_source(function(done) done(nil) end)]])
  edit('https://app.shortcut.com/elsewhere/story/1')
  child.lua([[handlers.set_slug_source(nil)]])
  edit('https://app.shortcut.com/elsewhere/story/2')
  eq(messages(), {})
end

T['sc-<id>'] = new_set()

T['sc-<id>']['uses the resolver and remembers the answer'] = function()
  child.lua([[
    _G.resolved = {}
    handlers.set_resolver(function(id, done)
      table.insert(_G.resolved, id)
      vim.schedule(function() done('epic') end)
    end)
  ]])
  edit('sc-55')
  eq(cur_name(), 'shortcut://epic/55')
  edit('start.txt')
  edit('sc-55')
  eq(cur_name(), 'shortcut://epic/55')
  eq(child.lua_get('_G.resolved'), { 55 })
  eq(buffers(), { 'shortcut://epic/55', 'start.txt' })
end

T['sc-<id>']['reports an unknown ID and returns to the previous buffer'] = function()
  child.lua([[handlers.set_resolver(function(id, done) done(nil) end)]])
  edit('sc-55')
  eq(bufname(), 'start.txt')
  eq(buffers(), { 'start.txt' })
  eq(messages()[1].msg, 'shortcut.nvim: sc-55 not found')
end

T['sc-<id>']['reports resolver errors'] = function()
  child.lua([[handlers.set_resolver(function(id, done) done(nil, 'offline') end)]])
  edit('sc-55')
  eq(bufname(), 'start.txt')
  eq(buffers(), { 'start.txt' })
  eq(messages()[1].msg, 'shortcut.nvim: could not look up sc-55: offline')
end

T['sc-<id>']['other names matching sc-[0-9]* open as normal files'] = function()
  child.lua([[
    vim.fn.writefile({ 'hello', 'world', 'vim: set shiftwidth=3 :' }, 'sc-1notes.txt')
    vim.cmd('filetype on')
  ]])
  edit('sc-1notes.txt')
  eq(bufname(), 'sc-1notes.txt')
  eq(lines(), { 'hello', 'world', 'vim: set shiftwidth=3 :' })
  eq(child.bo.filetype, 'text')
  eq(child.bo.shiftwidth, 3) -- modeline
  eq(child.bo.buftype, '')
  eq(child.bo.modified, false)
  eq(child.fn.undotree().seq_last, 0)
  eq(alt_name(), 'start.txt')

  -- Undo, then writing, work as usual.
  child.type_keys('dd')
  eq(lines(), { 'world', 'vim: set shiftwidth=3 :' })
  child.type_keys('u')
  eq(lines(), { 'hello', 'world', 'vim: set shiftwidth=3 :' })
  child.type_keys('dd')
  child.cmd('write')
  eq(child.bo.modified, false)
  eq(child.fn.readfile('sc-1notes.txt'), { 'world', 'vim: set shiftwidth=3 :' })
  eq(messages(), {})
end

T['sc-<id>']['keeps the file format of a file matching sc-[0-9]*'] = function()
  child.lua([[vim.fn.writefile({ 'a\r', 'b\r' }, 'sc-2.log')]])
  edit('sc-2.log')
  eq(lines(), { 'a', 'b' })
  eq(child.bo.fileformat, 'dos')
end

T['sc-<id>']['a real file named sc-<id> opens as a file'] = function()
  child.lua([[vim.fn.writefile({ 'real file' }, 'sc-123')]])
  edit('sc-123')
  eq(bufname(), 'sc-123')
  eq(lines(), { 'real file' })
  eq(child.bo.buftype, '')
  child.type_keys('Aedit<Esc>')
  child.cmd('write')
  eq(child.fn.readfile('sc-123'), { 'real fileedit' })
end

T['sc-<id>']['a new file matching sc-[0-9]* behaves as a new file'] = function()
  child.lua([[
    _G.newfile = 0
    vim.api.nvim_create_autocmd('BufNewFile', { callback = function() _G.newfile = _G.newfile + 1 end })
  ]])
  edit('sc-1notes.md')
  eq(bufname(), 'sc-1notes.md')
  eq(lines(), { '' })
  eq(child.bo.filetype, 'markdown')
  eq(child.lua_get('_G.newfile'), 1)
  child.type_keys('ihi<Esc>')
  child.cmd('write')
  eq(child.fn.readfile('sc-1notes.md'), { 'hi' })
end

T['sc-<id>']['a new file in a directory is not an ID'] = function()
  child.lua([[vim.fn.mkdir('notes')]])
  edit('notes/sc-42')
  eq(child.bo.buftype, '')
  eq(buffers(), { 'sc-42', 'start.txt' })
  child.type_keys('ihi<Esc>')
  child.cmd('write')
  eq(child.fn.readfile('notes/sc-42'), { 'hi' })
  eq(messages(), {})
end

T['sc-<id>']['a swap file is handled as for any file'] = function()
  -- Another running Nvim editing the file: Neovim's default SwapExists handler opens it anyway
  -- with W325, as it would for a file not matching sc-[0-9]*.
  child.lua([[
    vim.o.updatecount = 200 -- the test child runs with -n
    vim.o.directory = _G.dir .. 'swap//'
    vim.fn.mkdir(_G.dir .. 'swap')
    vim.fn.writefile({ 'content' }, 'sc-1notes.txt')
    _G.other = vim.fn.jobstart(
      { vim.v.progpath, '--clean', '--headless', '--cmd', 'set directory=' .. vim.o.directory, 'sc-1notes.txt' },
      { cwd = _G.dir }
    )
    assert(vim.wait(5000, function() return #vim.fn.glob(_G.dir .. 'swap/*', false, true) > 0 end))
    _G.swapexists = 0
    vim.api.nvim_create_autocmd('SwapExists', { callback = function() _G.swapexists = _G.swapexists + 1 end })
  ]])
  edit('sc-1notes.txt')
  child.lua('vim.fn.jobstop(_G.other)')
  eq(lines(), { 'content' })
  eq(child.lua_get('_G.swapexists'), 1)
  eq(child.bo.readonly, false)
  local msgs = messages()
  eq(#msgs, 1)
  expect.no_error(function()
    assert(msgs[1].msg:find('W325', 1, true))
  end)
end

T['sc-<id>']['a directory path ending in sc-<id> is not an ID'] = function()
  child.lua([[vim.fn.mkdir('sub'); vim.fn.writefile({ 'nested' }, 'sub/sc-9')]])
  edit('sub/sc-9')
  eq(lines(), { 'nested' })
end

T['sc-<id>']['sc_ids = false turns the form off'] = function()
  child.lua([[require('shortcut').setup({ sc_ids = false })]])
  edit('sc-123')
  eq(bufname(), 'sc-123')
  eq(child.bo.buftype, '')
  eq(buffers(), { 'sc-123', 'start.txt' })
  eq(
    child.lua_get([[#vim.api.nvim_get_autocmds({ event = 'BufReadCmd', pattern = 'sc-[0-9]*' })]]),
    0
  )

  child.lua([[require('shortcut').setup({ sc_ids = true })]])
  edit('sc-124')
  eq(cur_name(), 'shortcut://story/124')
end

T['sc-<id>']['sc_ids = false set before the plugin loads is respected'] = function()
  child.restart({
    '--cmd',
    'set rtp^=. | lua require("shortcut").setup({ sc_ids = false })',
    '-u',
    'tests/minimal_init.lua',
  })
  eq(
    child.lua_get([[#vim.api.nvim_get_autocmds({ event = 'BufReadCmd', pattern = 'sc-[0-9]*' })]]),
    0
  )
end

T['gf'] = new_set()

T['gf']['works on sc-<id> and on a Shortcut URL'] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'see sc-123 here', 'and ' .. URL })
  child.cmd('write')
  child.api.nvim_win_set_cursor(0, { 1, 5 })
  child.type_keys('gf')
  settle()
  eq(cur_name(), 'shortcut://story/123')
  eq(alt_name(), 'start.txt')

  child.type_keys('<C-^>')
  child.api.nvim_win_set_cursor(0, { 2, 10 })
  child.type_keys('gf')
  settle()
  eq(cur_name(), 'shortcut://story/123')
  eq(buffers(), { 'shortcut://story/123', 'start.txt' })
  eq(messages(), {})
end

T['gf']['works in git commit messages'] = function()
  child.lua([[
    vim.cmd('filetype plugin on')
    vim.fn.writefile({ 'Fix the thing', '', 'Part of sc-123.', 'See b/start.txt' }, 'COMMIT_EDITMSG')
  ]])
  edit('COMMIT_EDITMSG')
  eq(child.bo.filetype, 'gitcommit')
  -- The gitcommit ftplugin's own expression is kept for other names.
  eq(child.b.shortcut_includeexpr, "substitute(v:fname,'^[bi]/','','')")

  child.api.nvim_win_set_cursor(0, { 3, 9 })
  child.type_keys('gf')
  settle()
  eq(cur_name(), 'shortcut://story/123')

  child.type_keys('<C-^>')
  child.api.nvim_win_set_cursor(0, { 4, 6 })
  child.type_keys('gf')
  eq(bufname(), 'start.txt')
  eq(messages(), {})
end

T['gf']['chain_includeexpr() is idempotent and keeps the original expression'] = function()
  child.lua([[
    vim.bo.includeexpr = "toupper(v:fname)"
    require('shortcut').chain_includeexpr()
    require('shortcut').chain_includeexpr()
  ]])
  eq(child.b.shortcut_includeexpr, 'toupper(v:fname)')
  eq(
    child.bo.includeexpr,
    "v:lua.require'shortcut.buffer.handlers'.includeexpr(v:fname, b:shortcut_includeexpr)"
  )
  eq(child.lua_get([[require('shortcut').includeexpr('sc-5', 'toupper("x")')]]), 'shortcut://id/5')
  eq(child.lua_get([[require('shortcut').includeexpr('a.txt', 'toupper("x")')]]), 'X')
  eq(child.lua_get([[require('shortcut').includeexpr('a.txt', string.upper)]]), 'A.TXT')
  eq(child.lua_get([[require('shortcut').includeexpr('a.txt')]]), 'a.txt')
end

T['gf']['includeexpr leaves other names alone'] = function()
  eq(child.lua_get([[handlers.includeexpr('foo.lua')]]), 'foo.lua')
  eq(child.lua_get([[handlers.includeexpr('sc-12')]]), 'shortcut://id/12')
  eq(
    child.lua_get('vim.go.includeexpr'),
    "v:lua.require'shortcut.buffer.handlers'.includeexpr(v:fname)"
  )
end

T['net plugin'] = new_set()

T['net plugin']['still fetches other URLs'] = function()
  edit('https://example.com/page')
  eq(child.lua_get('_G.requests'), { 'https://example.com/page' })
  edit('https://app.shortcut.com/acme/settings')
  eq(
    child.lua_get('_G.requests'),
    { 'https://example.com/page', 'https://app.shortcut.com/acme/settings' }
  )
end

T['net plugin']['guarding is idempotent'] = function()
  local count =
    [[#vim.api.nvim_get_autocmds({ group = 'nvim.net.remotefile', event = 'BufReadCmd' })]]
  local before = child.lua_get(count)
  child.lua('handlers.guard_net_plugin(); handlers.guard_net_plugin()')
  eq(child.lua_get(count), before)
  edit('https://example.com/page')
  eq(child.lua_get('_G.requests'), { 'https://example.com/page' })
end

T['net plugin']['is guarded even if it is loaded after this plugin'] = function()
  child.lua([[
    vim.api.nvim_del_augroup_by_name('nvim.net.remotefile')
    vim.g.loaded_nvim_net_plugin = nil
    vim.cmd('runtime plugin/net.lua')
  ]])
  edit(URL)
  eq(cur_name(), 'shortcut://story/123')
  eq(child.lua_get('_G.requests'), {})
  eq(messages(), {})
end

T['net plugin']['only skips URLs that this plugin opens'] = function()
  -- Autocommand patterns ignore case only with 'fileignorecase' (the default on macOS and
  -- Windows). Without it our handler doesn't see this URL, so the built-in one must fetch it
  -- rather than leave an empty buffer.
  local url = 'https://APP.shortcut.com/acme/story/9'
  child.o.fileignorecase = false
  edit(url)
  eq(cur_name(), url)
  eq(child.lua_get('_G.requests'), { url })

  child.cmd('enew')
  child.lua('_G.requests = {}')
  child.o.fileignorecase = true
  edit('https://APP.shortcut.com/acme/story/10')
  eq(cur_name(), 'shortcut://story/10')
  eq(child.lua_get('_G.requests'), {})
end

T['net plugin']['being disabled is fine'] = function()
  child.restart({ '--cmd', 'let g:loaded_nvim_net_plugin = 1', '-u', 'tests/minimal_init.lua' })
  child.lua([[_G.messages = {}; vim.notify = function(msg) table.insert(_G.messages, msg) end]])
  edit(URL)
  eq(cur_name(), 'shortcut://story/123')
  eq(messages(), {})
end

T['commands'] = new_set()

T['commands'][':Shortcut story/epic accept an ID, sc-<id> or a URL'] = function()
  child.cmd('Shortcut story 12')
  eq(cur_name(), 'shortcut://story/12')
  eq(alt_name(), 'start.txt')
  child.cmd('Shortcut story sc-13')
  eq(cur_name(), 'shortcut://story/13')
  child.cmd('Shortcut story ' .. URL)
  eq(cur_name(), 'shortcut://story/123')
  child.cmd('Shortcut epic 4')
  eq(cur_name(), 'shortcut://epic/4')
  child.cmd('Shortcut epic sc-5')
  eq(cur_name(), 'shortcut://epic/5')
  child.cmd('Shortcut epic https://app.shortcut.com/acme/epic/6/slug')
  eq(cur_name(), 'shortcut://epic/6')
  eq(messages(), {})
end

T['commands']['pass the comment anchor and check the workspace'] = function()
  record_loads('story')
  child.lua([[handlers.set_slug_source(function(done) done('other') end)]])
  child.cmd('Shortcut story ' .. URL .. '#activity-8')
  eq(loads(), { { kind = 'story', id = 123, opts = { comment = 8 } } })
  eq(#messages(), 1)
end

T['commands']['without an argument show usage'] = function()
  child.cmd('Shortcut story')
  eq(messages()[1].msg, 'shortcut.nvim: usage: :Shortcut story {id | sc-<id> | url}')
  eq(bufname(), 'start.txt')
end

T['commands']['reject invalid and mismatched arguments'] = function()
  child.cmd('Shortcut story nope')
  child.cmd('Shortcut story https://app.shortcut.com/acme/epic/6')
  child.cmd('Shortcut epic 1 2')
  local msgs = messages()
  eq(#msgs, 3)
  expect.no_error(function()
    assert(msgs[1].msg:find("invalid story reference 'nope'", 1, true))
    assert(msgs[2].msg:find('is a link to an epic, not a story', 1, true))
    assert(msgs[3].msg:find('expected one argument', 1, true))
  end)
  eq(bufname(), 'start.txt')
end

return T

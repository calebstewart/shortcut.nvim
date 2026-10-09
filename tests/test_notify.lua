local new_set, expect = MiniTest.new_set, MiniTest.expect
local eq = expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.lua([[
        _G.messages = {}
        vim.notify = function(msg, level) table.insert(_G.messages, { msg = msg, level = level }) end
        _G.notify = require('shortcut.notify')
      ]])
    end,
    post_once = child.stop,
  },
})

T['strip_location()'] = new_set()

T['strip_location()']['removes a leading Lua position'] = function()
  for input, expected in pairs({
    ['/home/u/.config/nvim/init.lua:12: keychain locked'] = 'keychain locked',
    ['...ent/lua/shortcut/actions.lua:3: sc-1 not found'] = 'sc-1 not found',
    ['[string "<nvim>"]:1: oops'] = 'oops',
    ['C:\\nvim\\init.lua:7: oops'] = 'oops',
    ['plain message'] = 'plain message',
    ['x.lua:1: first\nstack traceback:\n\t[C]: in ?'] = 'first',
  }) do
    eq({ input, child.lua_get('notify.strip_location(...)', { input }) }, { input, expected })
  end
end

T['strip_location()']['leaves positions inside the message alone'] = function()
  for _, input in ipairs({
    'invalid value in /x/shortcut.lua:3: oops',
    'the `token` function passed to setup() failed: keychain: 2: locked',
    'GET /stories/1: HTTP 404: not found',
  }) do
    eq(child.lua_get('notify.strip_location(...)', { input }), input)
  end
end

T['refuse_write()'] = new_set()

--- A buffer refusing writes elsewhere, like the comment float, in the current window.
local function refusing_buffer()
  child.lua([[
    vim.cmd('new')
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = 'acwrite'
    vim.api.nvim_buf_set_name(buf, 'shortcut://test/refusing')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'draft' })
    vim.api.nvim_create_autocmd('BufWriteCmd', {
      buffer = buf,
      callback = function(ev)
        if ev.match == vim.api.nvim_buf_get_name(ev.buf) then
          vim.bo[ev.buf].modified = false
        else
          notify.refuse_write('refused')
        end
      end,
    })
  ]])
end

T['refuse_write()'][':wq {file} keeps the window and leaves no + in cpoptions'] = function()
  refusing_buffer()
  local file = child.fn.tempname()
  local cpo = child.o.cpoptions
  -- (`type_keys()` would raise if typing showed an error message: the refusal comes later.)
  child.type_keys(':wq ' .. file .. '<CR>')
  child.lua('vim.wait(20)')
  eq(#child.api.nvim_list_wins(), 2)
  eq(child.bo.modified, true)
  eq(child.fn.filereadable(file), 0)
  eq(child.o.cpoptions, cpo)
  eq(child.lua_get('_G.messages'), { { msg = 'shortcut.nvim: refused', level = 4 } })
end

T['refuse_write()']['another write in the same command keeps its buffer modified'] = function()
  -- A modified ordinary buffer in the other window.
  local orig = child.fn.tempname() .. '-orig.txt'
  child.fn.writefile({ 'original' }, orig)
  child.cmd('edit ' .. orig)
  child.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
  refusing_buffer()
  local a, b = child.fn.tempname() .. '-a.md', child.fn.tempname() .. '-b.txt'
  pcall(child.type_keys, (':w %s | wincmd p | w %s<CR>'):format(a, b))
  -- The refusal did its job...
  eq(child.fn.filereadable(a), 0)
  eq(child.fn.getbufvar('shortcut://test/refusing', '&modified'), 1)
  -- ...and `:w b.txt` wrote a copy without marking the original's changes as saved.
  eq(child.fn.readfile(b), { 'changed' })
  eq(vim.endswith(child.api.nvim_buf_get_name(0), '-orig.txt'), true)
  eq(child.bo.modified, true)
  eq(child.fn.readfile(orig), { 'original' })
  eq(child.o.cpoptions:find('+', 1, true), nil)
end

T['refuse_write()']['keeps a + the user had'] = function()
  child.o.cpoptions = child.o.cpoptions .. '+'
  local cpo = child.o.cpoptions
  refusing_buffer()
  pcall(child.type_keys, ':w ' .. child.fn.tempname() .. '<CR>')
  child.lua('vim.wait(20)')
  eq(child.o.cpoptions, cpo)
end

return T

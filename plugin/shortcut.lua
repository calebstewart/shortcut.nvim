-- Keep this file cheap: it runs at startup. Feature modules are required on first use.
if vim.g.loaded_shortcut then
  return
end
vim.g.loaded_shortcut = true

if vim.fn.has('nvim-0.12') == 0 then
  vim.notify('shortcut.nvim: requires Neovim >= 0.12', vim.log.levels.ERROR)
  return
end

-- Buffer routing for shortcut://, Shortcut web URLs and sc-<id>. Has to be in place before any
-- such name is edited, including files given on the command line.
require('shortcut.buffer.handlers').setup()

vim.api.nvim_create_user_command('Shortcut', function(cmd)
  require('shortcut.commands').dispatch(cmd)
end, {
  nargs = '*',
  bang = true,
  desc = 'Shortcut: browse, search and edit stories and epics',
  complete = function(arglead, cmdline, cursorpos)
    return require('shortcut.commands').complete(arglead, cmdline, cursorpos)
  end,
})

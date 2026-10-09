-- Minimal init used by the test runner and by child Neovim processes in tests.
--
-- Puts the plugin and mini.nvim on 'runtimepath'. mini.nvim comes from $MINI_NVIM when set
-- (the Nix dev shell sets it), otherwise from deps/mini.nvim (see `make deps`).
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.env.MINI_NVIM or (root .. '/deps/mini.nvim'))

-- Never see the real `short` config, a real token or the real lookup-list cache: tests that
-- need them create them themselves. (Without a token, nothing can reach the network either.)
-- Applies to child processes, which also load this file and inherit the environment.
local home = vim.fn.tempname() .. '-home'
vim.fn.mkdir(home, 'p')
vim.env.HOME = home
for _, name in ipairs({
  'XDG_CONFIG_HOME',
  'XDG_DATA_HOME',
  'XDG_CACHE_HOME',
  'XDG_STATE_HOME',
  'SHORTCUT_API_TOKEN',
  'CLUBHOUSE_API_TOKEN',
}) do
  vim.env[name] = nil
end

-- Load the plugin the same way Neovim would at startup.
vim.cmd('runtime plugin/shortcut.lua')

require('mini.test').setup()

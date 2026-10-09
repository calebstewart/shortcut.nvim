-- Minimal init used by the test runner and by child Neovim processes in tests.
--
-- Puts the plugin and mini.nvim on 'runtimepath'. mini.nvim comes from $MINI_NVIM when set
-- (the Nix dev shell sets it), otherwise from deps/mini.nvim (see `make deps`).
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.env.MINI_NVIM or (root .. '/deps/mini.nvim'))

-- Load the plugin the same way Neovim would at startup.
vim.cmd('runtime plugin/shortcut.lua')

require('mini.test').setup()

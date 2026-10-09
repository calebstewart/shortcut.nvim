# Not `NVIM`: Neovim sets $NVIM to its server address inside :terminal.
NVIM_BIN ?= nvim
# The Nix dev shell exports MINI_NVIM; otherwise mini.nvim is cloned into deps/.
MINI_NVIM ?= $(CURDIR)/deps/mini.nvim
export MINI_NVIM

.PHONY: test test-file deps fmt fmt-check typecheck clean

test: deps
	$(NVIM_BIN) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"

# Run a single test file: make test-file FILE=tests/test_config.lua
test-file: deps
	$(NVIM_BIN) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

deps: $(MINI_NVIM)/lua/mini/test.lua

$(CURDIR)/deps/mini.nvim/lua/mini/test.lua:
	git clone --filter=blob:none --depth 1 https://github.com/nvim-mini/mini.nvim $(CURDIR)/deps/mini.nvim

fmt:
	stylua .

fmt-check:
	stylua --check .

typecheck:
	VIMRUNTIME=$$($(NVIM_BIN) --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c q) \
		lua-language-server --check . --checklevel=Warning --configpath=.luarc.json

clean:
	rm -rf deps

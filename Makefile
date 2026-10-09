# Not `NVIM`: Neovim sets $NVIM to its server address inside :terminal.
NVIM_BIN ?= nvim
# The Nix dev shell exports MINI_NVIM; otherwise mini.nvim is cloned into deps/.
MINI_NVIM ?= $(CURDIR)/deps/mini.nvim
export MINI_NVIM
# snacks.nvim, for the picker tests (the plugin itself only uses it optionally). Pinned to the
# commit nixpkgs packages (2.31.0-unstable-2026-05-25); the Nix dev shell exports SNACKS_NVIM.
SNACKS_NVIM ?= $(CURDIR)/deps/snacks.nvim
SNACKS_REV := 882c996cf28183f4d63640de0b4c02ec886d01f2
export SNACKS_NVIM

.PHONY: test test-file deps fmt fmt-check typecheck clean

test: deps
	$(NVIM_BIN) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"

# Run a single test file: make test-file FILE=tests/test_config.lua
test-file: deps
	$(NVIM_BIN) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

deps: $(MINI_NVIM)/lua/mini/test.lua $(SNACKS_NVIM)/lua/snacks/init.lua

$(CURDIR)/deps/mini.nvim/lua/mini/test.lua:
	git clone --filter=blob:none --depth 1 https://github.com/nvim-mini/mini.nvim $(CURDIR)/deps/mini.nvim

$(CURDIR)/deps/snacks.nvim/lua/snacks/init.lua:
	rm -rf $(CURDIR)/deps/snacks.nvim
	git init --quiet $(CURDIR)/deps/snacks.nvim
	git -C $(CURDIR)/deps/snacks.nvim fetch --quiet --depth 1 https://github.com/folke/snacks.nvim $(SNACKS_REV)
	git -C $(CURDIR)/deps/snacks.nvim checkout --quiet FETCH_HEAD

fmt:
	stylua .

fmt-check:
	stylua --check .

typecheck:
	VIMRUNTIME=$$($(NVIM_BIN) --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c q) \
		lua-language-server --check . --checklevel=Warning --configpath=.luarc.json

clean:
	rm -rf deps

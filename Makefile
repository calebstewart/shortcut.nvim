# Not `NVIM`: Neovim sets $NVIM to its server address inside :terminal.
NVIM_BIN ?= nvim
# The Nix dev shell exports MINI_NVIM; otherwise mini.nvim is cloned into deps/.
MINI_NVIM ?= $(CURDIR)/deps/mini.nvim
export MINI_NVIM
# snacks.nvim, for the picker tests (the plugin itself only uses it optionally). The Nix dev
# shell exports SNACKS_NVIM; otherwise it is fetched into deps/ at SNACKS_REV, the commit nixpkgs
# packages (2.31.0-unstable-2026-05-25), and fetched again when SNACKS_REV changes. If it can't
# be fetched (e.g. offline), the snacks tests are skipped, unless REQUIRE_SNACKS=1 (as in CI).
SNACKS_DEPS := $(CURDIR)/deps/snacks.nvim
SNACKS_NVIM ?= $(SNACKS_DEPS)
SNACKS_REV := 882c996cf28183f4d63640de0b4c02ec886d01f2
SNACKS_URL := https://github.com/folke/snacks.nvim
export SNACKS_NVIM

.PHONY: test test-file deps deps-snacks fmt fmt-check typecheck clean

test: deps
	$(NVIM_BIN) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"

# Run a single test file: make test-file FILE=tests/test_config.lua
test-file: deps
	$(NVIM_BIN) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

deps: $(MINI_NVIM)/lua/mini/test.lua deps-snacks

$(CURDIR)/deps/mini.nvim/lua/mini/test.lua:
	git clone --filter=blob:none --depth 1 https://github.com/nvim-mini/mini.nvim $(CURDIR)/deps/mini.nvim

deps-snacks:
	@if [ "$(SNACKS_NVIM)" != "$(SNACKS_DEPS)" ]; then \
	  if [ ! -f "$(SNACKS_NVIM)/lua/snacks/init.lua" ]; then \
	    echo "error: SNACKS_NVIM=$(SNACKS_NVIM) is not a snacks.nvim checkout (no lua/snacks/init.lua)" >&2; \
	    exit 1; \
	  fi; \
	elif [ "$$(cat '$(SNACKS_DEPS)/.shortcut-rev' 2>/dev/null)" != "$(SNACKS_REV)" ]; then \
	  echo "fetching snacks.nvim $(SNACKS_REV) into deps/"; \
	  tmp='$(SNACKS_DEPS).tmp'; rm -rf "$$tmp"; \
	  if git init --quiet "$$tmp" \
	    && git -C "$$tmp" fetch --quiet --depth 1 $(SNACKS_URL) $(SNACKS_REV) \
	    && git -C "$$tmp" checkout --quiet FETCH_HEAD \
	    && echo $(SNACKS_REV) > "$$tmp/.shortcut-rev"; then \
	    rm -rf '$(SNACKS_DEPS)' && mv "$$tmp" '$(SNACKS_DEPS)'; \
	  else \
	    rm -rf "$$tmp"; \
	    if [ "$(REQUIRE_SNACKS)" = 1 ]; then \
	      echo "error: could not fetch snacks.nvim $(SNACKS_REV)" >&2; exit 1; \
	    elif [ -f '$(SNACKS_DEPS)/lua/snacks/init.lua' ]; then \
	      echo "warning: could not fetch snacks.nvim $(SNACKS_REV); testing with the older copy in deps/" >&2; \
	    else \
	      echo "warning: could not fetch snacks.nvim; the snacks picker tests will be skipped" >&2; \
	    fi; \
	  fi; \
	fi

fmt:
	stylua .

fmt-check:
	stylua --check .

typecheck:
	VIMRUNTIME=$$($(NVIM_BIN) --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c q) \
		lua-language-server --check . --checklevel=Warning --configpath=.luarc.json

clean:
	rm -rf deps

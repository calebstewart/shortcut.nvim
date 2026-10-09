# shortcut.nvim

Browse, search, and edit [Shortcut](https://www.shortcut.com/) stories and epics without leaving
Neovim. Stories and epics open as Markdown buffers — `:e` a story URL or `sc-12345`, edit it, and
`:w` saves it back to Shortcut. Authentication is shared with the
[`short` CLI](https://github.com/shortcut-cli/shortcut-cli), so if you already use it there is
nothing to set up.

> [!WARNING]
> Early development. Most of the functionality described here is not implemented yet.

## Requirements

- Neovim >= 0.12
- `curl`
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for the pickers (falls back to
  `vim.ui.select`)

## Installation

### lazy.nvim

```lua
{
  'calebstewart/shortcut.nvim',
  dependencies = { { 'folke/snacks.nvim', optional = true } },
  opts = {},
}
```

`setup()` is optional; without it the defaults apply.

### Nix

The flake provides the plugin as a package and through an overlay:

```nix
{
  inputs.shortcut-nvim.url = "github:calebstewart/shortcut.nvim";

  # nixpkgs.overlays = [ inputs.shortcut-nvim.overlays.default ];
  # programs.neovim.plugins = [ pkgs.vimPlugins.shortcut-nvim ];  # home-manager
}
```

Try it without installing anything (uses an isolated config, not yours):

```sh
nix run github:calebstewart/shortcut.nvim
```

## Configuration

Defaults:

```lua
require('shortcut').setup({
  token = nil,            -- string | fun(): string; see "Authentication"
  cli_config_path = nil,  -- override path to the `short` CLI's config.json
  cache = { ttl = 24 * 60 * 60 },  -- lookup-list cache lifetime (seconds)
  sc_ids = true,          -- allow `:e sc-<id>`
  picker = { page_size = 25, max_results = 200 },
  http = { timeout = 30 },  -- seconds
})
```

## Authentication

_Coming soon._

## Commands

| Command | Description |
|---|---|
| `:Shortcut help` | List available subcommands |

## Development

With Nix:

```sh
nix run .#dev        # Neovim with the plugin loaded from this checkout (isolated config)
nix develop          # neovim, stylua, lua-language-server, make, ...
make test
```

`nix run .#dev` reads the plugin straight from the working tree, so changes take effect on
restart without rebuilding. (Plain `nix run .` uses the packaged plugin and, like every flake
build, only sees files tracked by git.)

Without Nix:

```sh
make test            # clones mini.nvim into deps/ on first run
make test-file FILE=tests/test_config.lua
make fmt             # requires stylua
```

## License

[MIT](LICENSE)

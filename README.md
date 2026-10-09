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

shortcut.nvim needs a Shortcut API token (create one under
[Settings → API Tokens](https://app.shortcut.com/settings/account/api-tokens)). It looks in these
places, in order, and uses the first token it finds:

1. **`token` in `setup()`**: a string, or a function returning one. A function is called once
   per Neovim session, so it can fetch the token from a password manager:

   ```lua
   require('shortcut').setup({
     token = function()
       return vim.trim(vim.fn.system({ 'pass', 'show', 'shortcut/api-token' }))
     end,
   })
   ```

2. **The `SHORTCUT_API_TOKEN` environment variable** (or the older `CLUBHOUSE_API_TOKEN`).
3. **The [`short` CLI](https://github.com/shortcut-cli/shortcut-cli)'s config file.** If you
   have run `short install`, there is nothing else to do. The file is found exactly where
   `short` looks for it: `~/.config/shortcut-cli/config.json` by default, or
   `$XDG_CONFIG_HOME/shortcut-cli/config.json` when `XDG_CONFIG_HOME` is set. (Like `short`,
   when `XDG_CONFIG_HOME` is unset but `XDG_DATA_HOME` is set, it uses
   `$XDG_DATA_HOME/.config/shortcut-cli/config.json`.) Set `cli_config_path` to use a different
   file; `require('shortcut.auth').cli_config_path()` shows the path in use.

Your mention name and workspace URL slug are read from the `short` config file when its token
is the one in use; otherwise they are fetched once per session from the API.

### `:Shortcut login`

`:Shortcut login` asks for a token (the input is hidden), checks it against the API, and saves
it with your mention name and workspace slug to the `short` config file, keeping every other
setting in it. `short` picks up the same token. If the saved token is for a different
workspace, you are asked before it is replaced; an invalid token saves nothing. A token from
`setup()` or `$SHORTCUT_API_TOKEN` still takes precedence over the saved one.

shortcut.nvim never shows the token in messages; at most it shows the last four characters.
The token is passed to `curl` on its standard input, never on its command line, where other
users could see it with `ps`.

### Health check

`:checkhealth shortcut` reports the Neovim and `curl` versions, where the token comes from (with
only its last four characters shown), whether it works (by asking the API who you are), and
whether snacks.nvim is installed.

## Commands

| Command | Description |
|---|---|
| `:Shortcut story {id \| sc-<id> \| url}` | Open a story |
| `:Shortcut epic {id \| sc-<id> \| url}` | Open an epic |
| `:Shortcut login` | Save an API token to the shared `short` config |
| `:Shortcut help` | List available subcommands |

## Opening stories and epics

Each story or epic is a single buffer named `shortcut://story/<id>` or `shortcut://epic/<id>`.
Other ways of naming it switch to that buffer:

- `:e https://app.shortcut.com/<workspace>/story/<id>/...` (or `/epic/<id>`): a link copied from
  the web app. Neovim's built-in download of `https://` files is skipped for these. A link to a
  workspace other than your token's opens with a warning.
- `:e sc-<id>`: looked up as a story or epic. Turn this off with `sc_ids = false`. Names that
  merely start with `sc-<digits>` (e.g. `sc-1notes.txt`), paths with a directory (e.g.
  `notes/sc-42`), and files that exist on disk open as normal files.
- `gf` on a Shortcut link or on `sc-<id>`. For `sc-<id>` this works through `'includeexpr'`,
  which the plugin sets globally when it is empty, and chains onto the `gitcommit` ftplugin's
  own. Other filetypes that set their own (e.g. `lua`, `python`) can opt in from
  `after/ftplugin/<filetype>.lua`; the original expression still handles every other name:

  ```lua
  require('shortcut').chain_includeexpr()
  ```

After the switch, `<C-^>` returns to the buffer you came from.

> [!NOTE]
> Rendering is not implemented yet: the buffer only shows the object's kind and ID, and `:w`
> reports that saving is not supported. For now `sc-<id>` always opens a story.

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

+++
title = "Installation"
weight = 1
description = "Requirements, plugin managers, Neovim packages, and the Nix flake."
+++

## Requirements

| | |
|---|---|
| Neovim | 0.12 or newer |
| `curl` | Every API request goes through it |
| `git` | Optional: finds the story of the current branch |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | Optional: live search with previews; without it the pickers use `vim.ui.select` |

## lazy.nvim

```lua
{
  'calebstewart/shortcut.nvim',
  dependencies = { { 'folke/snacks.nvim', optional = true } },
  opts = {},
}
```

`setup()` is optional; without it the defaults apply. `opts` is passed to it, see
[Configuration](@/configuration.md).

> [!WARNING]
> Don't lazy-load it on the `:Shortcut` command alone. The plugin also opens Shortcut links, `sc-<id>`
> names and `shortcut://` buffers given to `:edit` or on the command line, which only works if it is loaded
> at startup.

Loading it costs well under a millisecond: the plugin file only registers the command and a few
autocommands, and everything else is loaded on first use.

## Neovim packages

Without a plugin manager, clone it into a `pack/*/start` directory:

```sh
git clone https://github.com/calebstewart/shortcut.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/shortcut.nvim
```

Or clone it into a `pack/*/opt` directory and load it with `packadd`:

```vim
:packadd shortcut.nvim
```

## Nix

The flake provides the plugin as a package, `packages.<system>.default`, and through `overlays.default` as
`pkgs.vimPlugins.shortcut-nvim`. Add the input to your flake:

```nix
# flake.nix
{
  inputs.shortcut-nvim.url = "github:calebstewart/shortcut.nvim";
  # ...
}
```

Then, in your NixOS or home-manager configuration (with `inputs` passed to it, e.g. through `specialArgs`
or `extraSpecialArgs`):

```nix
{ inputs, pkgs, ... }:
{
  nixpkgs.overlays = [ inputs.shortcut-nvim.overlays.default ];

  # home-manager
  programs.neovim.plugins = [ pkgs.vimPlugins.shortcut-nvim ];
}
```

The package declares `curl` and `git` as runtime dependencies, which Neovim wrappers put on `PATH`.

### Trying it without installing

```sh
nix run github:calebstewart/shortcut.nvim
```

This starts a Neovim with the packaged plugin and snacks.nvim, in an isolated configuration
(`NVIM_APPNAME=shortcut-nvim-dev`): your own config, plugins and state stay out of it. Its own config calls
`setup({})`, so a `token` set in your `setup()` (e.g. a password-manager function) is not used: the token
comes from [`$SHORTCUT_API_TOKEN`](@/authentication.md#where-the-token-comes-from) (or
`$CLUBHOUSE_API_TOKEN`) or the [`short` CLI's config file](@/authentication.md#sharing-it-with-the-short-cli).

## Checking the install

```vim
:checkhealth shortcut
```

It reports the Neovim and `curl` versions, where the token comes from and whether it works, and whether
the optional dependencies are there. See [Troubleshooting](@/troubleshooting.md#health-check).

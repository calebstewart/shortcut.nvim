+++
title = "Troubleshooting"
weight = 8
description = "The health check, rate limits, other workspaces, sc-<id> names, and Neovim's https:// handler."
+++

Every error is a notification prefixed with `shortcut.nvim:`; none should come with a Lua stack trace. If one
does, please [report it](https://github.com/calebstewart/shortcut.nvim/issues).

## Health check

```vim
:checkhealth shortcut
```

It reports:

- the Neovim and `curl` versions;
- where the token comes from (only its last four characters are shown) and whether it works, by asking the
  API who you are;
- what the [lookup-list cache](@/configuration.md#the-lookup-list-cache) holds and how old each list is;
- whether `:e sc-<id>` is handled, whether Neovim's built-in `https://` handler
  [skips Shortcut links](#neovim-s-built-in-https-handler), and whether `gf` works on `sc-<id>`;
- whether snacks.nvim and `git` are installed.

## Rate limits

Shortcut allows about 200 API requests per minute. A request answered with HTTP 429 (too many requests) is
retried up to three times, waiting as long as the answer asks (at most a minute) or 1, 2 and 4 seconds; after
that the command fails with "rate limited". Wait a minute and try again.

Picker previews are limited to 40 a minute and the lookup lists are cached, so normal use stays well below
the limit.

## Links to another workspace

Your token belongs to one workspace. A link to another workspace opens with a warning, and the story is
usually "not found", since your token can't read it. Use a token for that workspace (see
[Authentication](@/authentication.md)).

## A name, label or member is missing

If something was added in Shortcut after the [lookup lists](@/configuration.md#the-lookup-list-cache) were
fetched, run `:Shortcut refresh` to fetch them again.

## `sc-<id>` gets in the way

If `:e sc-<id>` gets in your way (e.g. you edit files named `sc-123` without a path; those that exist on disk
open as files anyway), set [`sc_ids = false`](@/configuration.md#options). That also turns off `gf` on
`sc-<id>`; `:Shortcut story sc-123` and links still work.

## Neovim's built-in https:// handler

Neovim 0.12 downloads `http://` and `https://` names given to `:edit` in the background (the
`nvim.net.remotefile` autocommands), which would replace a story with the web app's login page.
shortcut.nvim wraps those handlers at startup so they skip Shortcut story and epic links, and leaves every
other link to them. If you turned that plugin off (`g:loaded_nvim_net_plugin`), there is nothing to wrap.
`:checkhealth shortcut` shows the state.

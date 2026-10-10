+++
title = "Authentication"
weight = 2
description = "Where the API token comes from, sharing it with the short CLI, and :Shortcut login."
+++

shortcut.nvim needs a Shortcut API token. Create one in Shortcut under
[Settings → API Tokens](https://app.shortcut.com/settings/account/api-tokens).

## Where the token comes from

The plugin looks in these places, in order, and uses the first token it finds:

1. **[`token`](@/configuration.md#options) in `setup()`**: a string, or a function returning one. A function
   is called once per Neovim session, so it can read the token from a
   [password manager](#reading-it-from-a-password-manager).
2. **The `SHORTCUT_API_TOKEN` environment variable**, or the older `CLUBHOUSE_API_TOKEN`.
3. **The [`short` CLI](https://github.com/shortcut-cli/shortcut-cli)'s config file.** See
   [below](#sharing-it-with-the-short-cli).

Without a token, every command says how to provide one.

Your mention name (for `:Shortcut mine`) and workspace (for links) are read from the `short` config file
when its token is the one in use; otherwise they are fetched once per session from the API.

## Sharing it with the short CLI

If you have run `short install`, there is nothing else to do. The file is found exactly where `short` looks
for it:

- `~/.config/shortcut-cli/config.json` by default;
- `$XDG_CONFIG_HOME/shortcut-cli/config.json` when `XDG_CONFIG_HOME` is set;
- like `short`, `$XDG_DATA_HOME/.config/shortcut-cli/config.json` when `XDG_CONFIG_HOME` is unset but
  `XDG_DATA_HOME` is set.

Set [`cli_config_path`](@/configuration.md#options) to use a different file.
`require('shortcut.auth').cli_config_path()` shows the path in use.

## :Shortcut login

```vim
:Shortcut login
```

asks for a token (the input is hidden), checks it against the API, and saves it with your mention name and
workspace slug to the `short` config file, keeping every other setting in it. `short` picks up the same
token.

- If the saved token is for a different workspace, you are asked before it is replaced.
- An invalid token saves nothing.
- A token from `setup()` or `$SHORTCUT_API_TOKEN` still takes precedence over the saved one, and you are
  told so.

This is the only thing in the plugin that writes that file.

## Reading it from a password manager

A `token` function that reads the token from a password manager's command line tool should fail when the
command does, rather than return its error message as the token:

```lua
--- The first line a command prints, or an error if it fails (rather than its error message
--- being used as the token).
local function command_token(cmd)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    error(('%s failed: %s'):format(cmd[1], vim.trim(res.stderr or '')))
  end
  return vim.trim(vim.split(res.stdout or '', '\n')[1])
end

require('shortcut').setup({
  token = function()
    return command_token({ 'pass', 'show', 'shortcut/api-token' })
  end,
})
```

Other password managers only need another command:

```lua
-- macOS Keychain
{ 'security', 'find-generic-password', '-s', 'shortcut-api-token', '-w' }
-- 1Password CLI
{ 'op', 'read', 'op://Private/Shortcut/token' }
```

If the function raises an error or returns anything but a non-empty string, commands say so (without a
stack trace) and send nothing.

## Keeping the token private

The token is never shown in messages: at most its last four characters, as in `:checkhealth shortcut`. It
is passed to `curl` on its standard input, never on its command line, where other users could see it with
`ps`.

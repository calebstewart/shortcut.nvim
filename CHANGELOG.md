# Changelog

All notable changes to shortcut.nvim are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-09

The first release: browse, search, edit and create Shortcut stories and epics from Neovim 0.12+.

### Added

- **Authentication shared with the `short` CLI.** The token comes from `setup({ token })` (a
  string or a function, e.g. for a password manager), `$SHORTCUT_API_TOKEN` (or
  `$CLUBHOUSE_API_TOKEN`), or the `short` CLI's config file, found where `short` looks for it
  (including its `XDG_CONFIG_HOME`/`XDG_DATA_HOME` rules). `:Shortcut login` checks a token and
  saves it to that file, keeping everything else in it. The token is never shown or passed on a
  command line.
- **Async HTTP client** on `curl` with timeouts, retries of `429` responses (honouring
  `Retry-After`) and of failed `GET`s, and readable errors.
- **Lookup-list cache** of workflows, members, labels, teams and iterations, in memory and on
  disk per workspace, refreshed in the background after `cache.ttl` (stale-while-revalidate);
  `:Shortcut refresh` fetches it again.
- **Story buffers** (`shortcut://story/<id>`): a YAML header (type, state, owners, epic,
  iteration, estimate, labels, link), title, description, tasks with their owners
  (` · @mention`, with `\·` to escape a literal one), and read-only comments, replies and file
  attachments, with section markers. Modelines are always off.
- **Editing with `:w`**: only changed fields are sent, in one `PUT`, plus one request per
  changed task; every value is validated first and problems are shown as diagnostics. Deleting
  tasks asks first (`tasks.confirm_delete`). Changes made by someone else since the buffer was
  loaded are never overwritten silently: `:Shortcut diff` shows them, `:w!` saves over them,
  `:e!` reloads. Partly failed saves report what was and wasn't saved, and `:w` retries only
  what failed.
- **Epic buffers** (`shortcut://epic/<id>`): the epic's fields and description, and its stories
  grouped by workflow state; `<CR>` opens the story under the cursor and otherwise does what it
  did before.
- **Opening by link, `sc-<id>` and `gf`**: `:e` a Shortcut web app link or `sc-<id>` (story or
  epic) switches to its single buffer; `gf` works on both, including in git commit messages.
  Neovim's built-in `https://` download is skipped for Shortcut links, links to another
  workspace warn, and real files named like `sc-<id>` still open normally (`sc_ids = false`
  turns the lookups off).
- **`:Shortcut create`**: a draft from a template (defaults from `create.workflow`,
  `create.team` and `create.template`, plus `key=value` arguments); `:w` creates the story and
  switches to it. A create that may have happened without an answer is never resent without
  `:w!`.
- **Quick actions** on the current story (argument, buffer, or the `sc-<id>` in the git branch):
  `:Shortcut comment` (a floating buffer; `:w` posts it, unsent comments are kept on exit),
  `:Shortcut state`, `:Shortcut browse`, `:Shortcut yank`; `:Shortcut story` opens the branch's
  story.
- **Pickers**: `:Shortcut search`, `:Shortcut mine` and `:Shortcut epics`, live with previews
  in snacks.nvim (keys to copy and open links, rate-limited previews), and with
  `vim.ui.input`/`vim.ui.select` without it.
- **`:checkhealth shortcut`**: Neovim, `curl`, the token and whether it works, the cache, link
  and `sc-<id>` routing, snacks.nvim and `git`.
- **Documentation**: the README and `:help shortcut`.
- **Nix flake**: the plugin package and overlay (`vimPlugins.shortcut-nvim`), `nix run` and
  `nix run .#dev` to try it in an isolated Neovim, a dev shell, and checks.

[0.1.0]: https://github.com/calebstewart/shortcut.nvim/releases/tag/v0.1.0

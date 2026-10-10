+++
title = "Development"
weight = 9
description = "Trying changes, running the tests, and previewing this site."
+++

## The dev shell

```sh
nix develop
```

That gives you Neovim, stylua, lua-language-server, make, curl, git and zola: everything the repository
builds and checks with.

## Trying it out

```sh
nix run .#dev
```

This opens a Neovim with the plugin loaded straight from the working tree, in an isolated configuration
(`NVIM_APPNAME=shortcut-nvim-dev`) with snacks.nvim: changes take effect on restart, without rebuilding. Run
it from the repository root, or set `SHORTCUT_NVIM_DIR` to a checkout. It uses your real API token, from the
[usual places](@/authentication.md).

Plain `nix run .` uses the packaged plugin instead and, like every flake build (and `nix flake check`), only
sees files tracked by git: `git add` new files first.

## Tests

With Nix:

```sh
nix develop -c make test
nix flake check      # the plugin package, the tests, the formatting and this site, in the sandbox
```

Without Nix:

```sh
make deps            # fetch mini.nvim and snacks.nvim (pinned) into deps/; `make test` does it too
make test            # every test file, in parallel
make test-file FILE=tests/test_config.lua
make fmt             # requires stylua (fmt-check to check only)
make typecheck       # requires lua-language-server
```

`make test` runs each test file in its own headless Neovim, one per CPU at a time (`JOBS=1` runs them one
after another), prints a line per file, then the full report of any file that failed or skipped tests
(`VERBOSE=1`: of every file). If snacks.nvim can't be fetched (e.g. offline), the picker tests are skipped,
unless `REQUIRE_SNACKS=1` (as in CI).

Tests never touch the network or your real `short` config and cache: they run against recorded API responses
with a temporary `$HOME`.

## Documentation

The plugin is documented in three places, and the README and `doc/shortcut.txt` (`:help shortcut`) are the
source of truth. This site is written from them by hand, rearranged into pages; a change to the plugin's
behaviour updates all three.

`tests/test_doc.lua` keeps them from falling behind the code. It checks that:

- `:helptags` accepts the help file, its links resolve, and every command, option and highlight group has a
  tag;
- the README lists every subcommand;
- this site's [Commands](@/commands.md) page lists every subcommand, its [Configuration](@/configuration.md)
  page every option, and its [Searching](@/searching.md) page every highlight group;
- no page links to a root-relative `/path`, which would 404 under the site's sub-path.

It reads the Markdown directly, so it runs in CI without Nix or Zola.

## This site

The documentation site is a [Zola](https://www.getzola.org/) site under `docs/`, deployed to GitHub Pages by
`.github/workflows/pages.yml` on every push to `main`. Pull requests that touch it build it without
deploying.

For the fast loop, with live reload, from the dev shell:

```sh
zola --root docs serve
```

> [!NOTE]
> `zola serve` overrides `base_url` with `127.0.0.1:1111`, so it cannot tell you whether a link works at the
> site's real sub-path. Use `nix build .#docs` for that.

To build it exactly as CI does:

```sh
nix build .#docs --print-build-logs
nix flake check --print-build-logs
```

`checks.docs` is the same derivation, so a broken template or a dead `@/` link fails `nix flake check`.

> [!WARNING]
> The flake's source is `git+file://`, which means Nix does not see untracked files. A newly added page must
> be `git add`-ed (staging is enough, no commit needed) before `nix build .#docs` can see it. Otherwise it
> fails with a confusing "path does not exist" error.

### Writing pages

Pages are flat Markdown files in `docs/content/`, ordered by `weight` in their front matter:

```toml
+++
title = "Configuration"
weight = 3
description = "Every option, its default, and what it changes."
+++
```

`description` does double duty: the `<meta name=description>` and the visible tagline under the page's
heading. The sidebar builds itself from the section's pages, so adding a file is all that's needed to add a
nav entry.

Internal links **must** use Zola's `@/` form, because the site is served from a sub-path:

```markdown
[Configuration](@/configuration.md)
[a specific section](@/configuration.md#the-lookup-list-cache)
```

A hand-written `/configuration/` would resolve against the domain root and 404. A dead `@/` link fails the
build, which is the point.

Examples use placeholders only (`sc-<id>`, `<workspace>`, `someone`), never real workspace data.

## Layout

| Path | |
|---|---|
| `lua/shortcut/` | The plugin |
| `lua/shortcut/buffer/` | Story, epic and draft buffers: rendering, parsing and saving |
| `lua/shortcut/picker/` | The pickers (snacks.nvim and `vim.ui.select`) |
| `lua/shortcut/api/` | The Shortcut REST API client |
| `plugin/shortcut.lua` | The `:Shortcut` command and the autocommands for `shortcut://`, links and `sc-<id>` |
| `doc/shortcut.txt` | `:help shortcut` |
| `tests/` | The test suite and its recorded API responses |
| `nix/docs.nix` | This site's derivation |
| `docs/` | This site |

## Contributing

Issues and pull requests are welcome on [GitHub](https://github.com/calebstewart/shortcut.nvim). Before
opening a pull request, run `make test`, `make fmt-check` and `make typecheck` (or `nix flake check`), and
update the README, the help file and this site if the behaviour changes. See the
[changelog](https://github.com/calebstewart/shortcut.nvim/blob/main/CHANGELOG.md) for the release history.

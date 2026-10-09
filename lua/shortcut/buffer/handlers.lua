--- Buffer routing for Shortcut objects.
---
--- Every story and epic lives in exactly one buffer named `shortcut://<kind>/<id>`, read and
--- written through `BufReadCmd`/`BufWriteCmd`. Other names for the same object (Shortcut web
--- URLs, `sc-<id>`, `shortcut://id/<id>`) open a temporary buffer whose read handler switches
--- every window showing it to the canonical buffer and then deletes it.
---
--- How objects are loaded and saved is pluggable: renderers call `register()` for their kind.
--- Stories are handled by `shortcut.buffer.story` and epics by `shortcut.buffer.epic`, each
--- loaded on first use.
---
--- Drafts of new stories (`shortcut://story/new-<n>`, see `shortcut.buffer.story_create`) and
--- comment buffers write themselves; reading a draft's name that `:Shortcut create` did not make
--- is an error.
local notify = require('shortcut.notify')
local uri = require('shortcut.uri')

local M = {}

---@class shortcut.buffer.LoadOpts
---@field comment? integer Comment to jump to once loaded.

---@class shortcut.buffer.SaveOpts
---@field force boolean `true` for `:w!`.

--- Called by a loader when it has finished. On success, `lines` (if given) replace the buffer
--- contents; a loader that renders the buffer itself passes no lines, and must make the buffer
--- modifiable while it writes (it is not modifiable while loading).
---@alias shortcut.buffer.LoadDone fun(err?: string, lines?: string[])

--- Called by a saver when it has finished. `'modified'` is cleared only on success, and not if
--- `opts.keep_modified` is set (e.g. the user cancelled the save: nothing was saved, but it is not
--- an error either).
---@alias shortcut.buffer.SaveDone fun(err?: string, opts?: { keep_modified?: boolean })

---@class shortcut.buffer.Handler
---@field load fun(buf: integer, id: integer, opts: shortcut.buffer.LoadOpts, done: shortcut.buffer.LoadDone)
---@field save? fun(buf: integer, id: integer, opts: shortcut.buffer.SaveOpts, done: shortcut.buffer.SaveDone)
---@field jump? fun(buf: integer, comment: integer) Jump to a comment in an already-loaded buffer.

--- Resolves the kind of an `sc-<id>`. Call `done('story'|'epic')`, `done(nil)` if no such
--- object exists, or `done(nil, err)` on failure. May return a handle whose `cancel()` stops the
--- lookup: it is called if the `sc-<id>` buffer goes away first.
---@alias shortcut.buffer.Resolver fun(id: integer, done: fun(kind?: shortcut.Kind, err?: string)): { cancel: fun(self: any) }?

--- Provides the user's workspace slug (`url_slug`), or `nil` if unknown.
---@alias shortcut.buffer.SlugSource fun(done: fun(slug?: string))

local GROUP = 'shortcut.buffer'
local SC_GROUP = 'shortcut.buffer.sc_ids'
local NET_GROUP = 'nvim.net.remotefile'
local WEB_PATTERNS = { 'https://app.shortcut.com/*', 'http://app.shortcut.com/*' }
local INCLUDEEXPR = "v:lua.require'shortcut.buffer.handlers'.includeexpr(v:fname)"
local CHAINED_INCLUDEEXPR =
  "v:lua.require'shortcut.buffer.handlers'.includeexpr(v:fname, b:shortcut_includeexpr)"
local PLURAL = { story = 'stories', epic = 'epics' }

--- A handler that requires `module` (exporting `handler`) only when first used, so nothing
--- heavy is loaded at startup.
---@param module string
---@return shortcut.buffer.Handler
local function lazy(module)
  local function get()
    return require(module).handler --[[@as shortcut.buffer.Handler]]
  end
  return {
    load = function(...)
      return get().load(...)
    end,
    save = function(...)
      return assert(get().save)(...)
    end,
    -- Handlers without `jump` (epics have no comments to jump to) ignore it.
    jump = function(...)
      local jump = get().jump
      if jump then
        return jump(...)
      end
    end,
  }
end

---@type table<shortcut.Kind, shortcut.buffer.Handler>
local registry = { story = lazy('shortcut.buffer.story'), epic = lazy('shortcut.buffer.epic') }

--- The default resolver: `GET /stories/<id>`, and on 404 `GET /epics/<id>`.
---
--- Stories and epics share one public-ID space, so an ID names at most one of them and the order
--- does not matter. (Not stated in the API docs; checked against a real workspace: epic IDs
--- interleave with story IDs and never coincide with story, label or iteration IDs, and
--- `GET /stories/<epic id>` and `GET /epics/<story id>` answer 404.) The API modules are only
--- loaded when an `sc-<id>` is opened.
---@type shortcut.buffer.Resolver
function M.api_resolver(id, done)
  local http = require('shortcut.http')
  local handle = { cancelled = false, current = nil } ---@type { cancelled: boolean, current?: shortcut.http.Handle, cancel: fun(self: any) }
  function handle:cancel()
    self.cancelled = true
    if self.current then
      self.current:cancel()
    end
  end
  handle.current = require('shortcut.api.stories').get(id, function(err)
    if not err then
      return done('story')
    end
    if err.status ~= 404 then
      return done(nil, http.format_error(err))
    end
    if handle.cancelled then
      return
    end
    handle.current = require('shortcut.api.epics').get(id, function(epic_err)
      if not epic_err then
        return done('epic')
      end
      if epic_err.status == 404 then
        return done(nil)
      end
      done(nil, http.format_error(epic_err))
    end)
  end)
  return handle
end

---@type shortcut.buffer.Resolver?
local resolver = M.api_resolver

---@type table<integer, shortcut.Kind>
local kind_cache = {}

--- The default slug source: the resolved token's workspace (from the `short` config, or else
--- `GET /member`, cached for the session). Unknown (no warning) if there is no usable token.
---@type shortcut.buffer.SlugSource
local function default_slug_source(done)
  require('shortcut.http').user(function(err, user)
    done(not err and user and user.url_slug or nil)
  end)
end

---@type shortcut.buffer.SlugSource?
local slug_source = default_slug_source

--- Options for the next load of a canonical name, set just before `:edit`ing it.
---@type table<string, shortcut.buffer.LoadOpts>
local pending = {}

--- Incremented on every load of a buffer, so results of superseded loads are dropped.
---@type table<integer, integer>
local generation = {}

--- State of the current load of each buffer. Only a `'loaded'` buffer may be saved: otherwise
--- its contents are a loading or error message, not the object.
---@type table<integer, 'loading'|'loaded'|'failed'>
local load_state = {}

--- Callbacks of the built-in net plugin that have been wrapped already.
---@type table<function, true>
local wrapped = {}

--- Register how objects of `kind` are loaded and saved.
---@param kind shortcut.Kind
---@param handler shortcut.buffer.Handler
function M.register(kind, handler)
  vim.validate('kind', kind, function(k)
    return uri.is_kind(k)
  end, "'story' or 'epic'")
  vim.validate('handler', handler, 'table')
  vim.validate('handler.load', handler.load, 'function')
  vim.validate('handler.save', handler.save, 'function', true)
  vim.validate('handler.jump', handler.jump, 'function', true)
  registry[kind] = handler
end

--- Set how `sc-<id>` is resolved to a story or an epic. The default is `api_resolver`; with
--- `nil`, `sc-<id>` is assumed to be a story. Answers are remembered for the session.
---@param fn shortcut.buffer.Resolver?
function M.set_resolver(fn)
  vim.validate('fn', fn, 'function', true)
  resolver = fn
  kind_cache = {}
end

--- Set where the user's workspace slug comes from. By default it is the API token's workspace;
--- with `nil`, opening a URL for another workspace does not warn.
---@param fn shortcut.buffer.SlugSource?
function M.set_slug_source(fn)
  vim.validate('fn', fn, 'function', true)
  slug_source = fn
end

---@return boolean
local function sc_ids_enabled()
  return require('shortcut.config').get().sc_ids
end

--- Run `fn` on the main loop: soon if called from a fast event, otherwise now.
---@param fn function
local function main_loop(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

--- The message of an error caught with `pcall()`, without the `file:line: ` prefix Lua adds.
---@param err any
---@return string
local function error_message(err)
  return notify.strip_location(err)
end

---@param name string
---@return integer?
local function find_buf(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return nil
end

--- Replace the contents of `buf` without recording undo history.
---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
end

--- Warn if a URL's workspace is not the user's.
---@param workspace? string
local function check_workspace(workspace)
  if not workspace or not slug_source then
    return
  end
  slug_source(function(slug)
    if slug and slug:lower() ~= workspace:lower() then
      main_loop(function()
        notify.warn(
          ("this link is for workspace '%s' but your token is for '%s'; it may not be accessible"):format(
            workspace,
            slug
          )
        )
      end)
    end
  end)
end

--- Whether our web URL autocommand (`WEB_PATTERNS`) handles `name`. Like all autocommand
--- patterns, those ignore case only if 'fileignorecase' is set.
---@param name string
---@return boolean
local function is_routed_url(name)
  if vim.o.fileignorecase then
    name = name:lower()
  end
  if not name:match('^https?://app%.shortcut%.com/') then
    return false
  end
  local target = uri.parse(name)
  return target ~= nil and target.workspace ~= nil
end

--- Guard the built-in `nvim.net.remotefile` `BufReadCmd` handlers so they ignore Shortcut
--- story/epic URLs instead of downloading the web page into the buffer. Idempotent; does nothing
--- if that plugin is disabled.
function M.guard_net_plugin()
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = NET_GROUP, event = 'BufReadCmd' })
  for _, ac in ipairs(ok and autocmds or {}) do
    local orig = ac.callback
    if type(orig) == 'function' and not wrapped[orig] then
      vim.api.nvim_del_autocmd(ac.id)
      local function guarded(ev)
        -- Skip exactly what our own handler switches away from; anything else (other pages,
        -- or a host spelled in another case when our pattern doesn't match it) is fetched.
        if is_routed_url(ev.match) then
          return
        end
        return orig(ev)
      end
      wrapped[guarded] = true
      vim.api.nvim_create_autocmd('BufReadCmd', {
        group = ac.group,
        pattern = ac.pattern,
        desc = ac.desc,
        callback = guarded,
      })
    end
  end
end

---@param buf integer
---@param target shortcut.uri.Target
---@param opts shortcut.buffer.LoadOpts
---@param read? boolean Loading from `BufReadCmd` (`:e`, `:e!`), not reloading in the background.
local function load(buf, target, opts, read)
  local kind, id =
    target.kind, --[[@as shortcut.Kind]]
    target.id
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].swapfile = false
  -- The content comes from the server (comments, names...): never let it set options. Neovim
  -- applies modelines again whenever an autocommand runs for the buffer with modelines enabled
  -- (e.g. `:doautocmd`, or `nvim_exec_autocmds()` for some plugin's User event).
  vim.bo[buf].modeline = false
  vim.b[buf].shortcut = { kind = kind, id = id }

  generation[buf] = (generation[buf] or 0) + 1
  local gen = generation[buf]
  load_state[buf] = 'loading'

  -- Before the filetype is set, so that FileType handlers only see this placeholder and not the
  -- previous server text: for a buffer not shown in the current tab they run in an autocommand
  -- window, and with 'cpoptions' containing `S` entering that copies the global 'modeline' in
  -- again. (Anything else that touches a hidden buffer through an autocommand window can turn it
  -- back on as well; the BufEnter/BufWinEnter handler below only covers real windows.)
  set_lines(buf, { ('Loading sc-%d…'):format(id) })
  -- A read sets the filetype even when it is already markdown, as filetype detection does for a
  -- file: `:e!` drops the buffer's highlighting (the treesitter highlighter detaches), and only
  -- FileType starts it again (with the markdown ftplugin and any other FileType handlers).
  -- Background reloads only replace the lines, which keeps the highlighting.
  if read or vim.bo[buf].filetype ~= 'markdown' then
    vim.bo[buf].modeline = false
    vim.bo[buf].filetype = 'markdown'
    vim.bo[buf].modeline = false
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  local finished = false
  ---@type shortcut.buffer.LoadDone
  local function done(err, lines)
    main_loop(function()
      -- An unloaded buffer must stay unloaded: writing to it would load it again (and start a
      -- new load). Unloading also bumps the generation, so a later reload ignores this result.
      if finished or not vim.api.nvim_buf_is_loaded(buf) or generation[buf] ~= gen then
        return
      end
      finished = true
      load_state[buf] = err and 'failed' or 'loaded'
      if err then
        notify.error(('failed to load sc-%d: %s'):format(id, err))
        local msg = { ('Failed to load sc-%d:'):format(id), '' }
        vim.list_extend(msg, vim.split(tostring(err), '\n', { plain = true }))
        set_lines(buf, msg)
        -- Not editable, and on_write refuses to save it; `:e!` retries.
        vim.bo[buf].modifiable = false
      else
        if lines then
          set_lines(buf, lines)
        end
        vim.bo[buf].modifiable = true
        -- A picker preview of the object may be older than what was just loaded.
        local picker = package.loaded['shortcut.picker']
        if picker then
          picker.invalidate_preview(kind, id)
        end
      end
      vim.bo[buf].modified = false
    end)
  end

  local handler = registry[kind]
  local ok, err = pcall(handler.load, buf, id, opts, done)
  if not ok then
    done(error_message(err))
  end
end

--- Open the canonical buffer for an object in the current window.
---@param kind shortcut.Kind
---@param id integer
---@param opts? { comment?: integer, keepalt?: boolean }
local function edit(kind, id, opts)
  opts = opts or {}
  local name = uri.canonical(kind, id)
  local existing = find_buf(name)
  local loaded = existing and vim.api.nvim_buf_is_loaded(existing)
  pending[name] = { comment = opts.comment }
  local ok, err = pcall(
    vim.api.nvim_command,
    (opts.keepalt and 'keepalt ' or '') .. 'edit ' .. vim.fn.fnameescape(name)
  )
  pending[name] = nil
  if not ok then
    error(err, 0)
  end
  local handler = registry[kind]
  if loaded and opts.comment and handler.jump then
    handler.jump(vim.api.nvim_get_current_buf(), opts.comment)
  end
end

--- Switch every window showing the temporary buffer `alias` to `kind`/`id` (or, if `kind` is
--- nil, back to the window's alternate buffer) and delete `alias`.
---@param alias integer
---@param kind? shortcut.Kind
---@param id? integer
---@param opts? { comment?: integer }
local function replace(alias, kind, id, opts)
  if not vim.api.nvim_buf_is_valid(alias) then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(alias)) do
    vim.api.nvim_win_call(win, function()
      if kind and id then
        -- `keepalt` keeps the buffer the user came from as the alternate file, so `<C-^>` still
        -- goes back once the temporary buffer is gone.
        local ok, err = pcall(edit, kind, id, { comment = opts and opts.comment, keepalt = true })
        if not ok then
          notify.error(tostring(err))
        end
      else
        local alt = vim.fn.bufnr('#')
        if alt > 0 and alt ~= alias and vim.api.nvim_buf_is_valid(alt) then
          pcall(vim.cmd.buffer, alt)
        end
      end
    end)
  end
  pcall(vim.api.nvim_buf_delete, alias, { force = true })
end

--- Make a temporary buffer inert while it waits to be replaced.
---@param buf integer
local function prepare_alias(buf)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

---@param id integer
---@param done fun(kind?: shortcut.Kind, err?: string)
---@return { cancel: fun(self: any) }? handle From the resolver, if it returned one.
local function resolve(id, done)
  if kind_cache[id] then
    return done(kind_cache[id])
  end
  if not resolver then
    -- No way to ask the API: assume a story.
    return done('story')
  end
  local current = resolver
  local ok, handle = pcall(current, id, function(kind, rerr)
    main_loop(function()
      if kind and uri.is_kind(kind) and resolver == current then
        kind_cache[id] = kind
      end
      done(kind, rerr)
    end)
  end)
  if not ok then
    done(nil, error_message(handle))
    return nil
  end
  if type(handle) == 'table' and type(handle.cancel) == 'function' then
    return handle
  end
  return nil
end

--- Handle a temporary buffer for an object of unknown kind. If the buffer goes away before the
--- lookup finishes, the lookup is cancelled and its outcome is not reported.
---@param alias integer
---@param id integer
local function redirect_id(alias, id)
  prepare_alias(alias)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_loaded(alias) then
      return
    end
    local handle ---@type { cancel: fun(self: any) }?
    local finished = false
    local autocmd = vim.api.nvim_create_autocmd('BufUnload', {
      buffer = alias,
      once = true,
      desc = 'shortcut.nvim: cancel the sc-<id> lookup',
      callback = function()
        if not finished and handle then
          pcall(handle.cancel, handle)
        end
      end,
    })
    handle = resolve(id, function(kind, err)
      finished = true
      pcall(vim.api.nvim_del_autocmd, autocmd)
      if not vim.api.nvim_buf_is_loaded(alias) then
        -- Closed meanwhile: nobody is waiting for it any more.
        return
      end
      if kind and uri.is_kind(kind) then
        replace(alias, kind, id)
        return
      end
      if err then
        notify.error(('could not look up sc-%d: %s'):format(id, err))
      else
        notify.error(('sc-%d not found'):format(id))
      end
      replace(alias, nil)
    end)
  end)
end

--- Whether `buf` is a comment buffer (`shortcut://story/<id>/comment`), which
--- `shortcut.buffer.comment` reads and writes itself.
---@param buf integer
---@param name string
---@return boolean is_comment_name
---@return boolean owned Created by `shortcut.buffer.comment`.
local function comment_buffer(buf, name)
  if not uri.parse_comment_name(name) then
    return false, false
  end
  return true, vim.b[buf].shortcut_comment ~= nil
end

---@param ev vim.api.keyset.create_autocmd.callback_args
local function on_read(ev)
  local draft = uri.parse(ev.match)
  if draft and draft.kind == 'draft' then
    -- Never on Shortcut: only `:Shortcut create` makes drafts, and `:e!` resets one.
    if vim.b[ev.buf].shortcut_draft ~= nil then
      require('shortcut.buffer.story_create').reset(ev.buf)
    else
      prepare_alias(ev.buf)
      notify.error(('%s is not a draft; :Shortcut create starts one'):format(ev.match))
    end
    return
  end
  local is_comment, owned = comment_buffer(ev.buf, ev.match)
  if is_comment then
    -- Never a story: there is nothing to load.
    if not owned then
      prepare_alias(ev.buf)
      notify.error(
        ('%s is not a file; use :Shortcut comment %d'):format(
          ev.match,
          uri.parse_comment_name(ev.match)
        )
      )
    end
    return
  end
  local target = uri.parse(ev.match)
  if not target or target.workspace then
    notify.error(('not a Shortcut buffer name: %s'):format(ev.match))
    return
  end
  if target.kind == 'id' then
    redirect_id(ev.buf, target.id)
    return
  end
  local name = uri.canonical(target.kind --[[@as shortcut.Kind]], target.id)
  if name ~= ev.match then
    -- A non-canonical spelling, e.g. a leading zero.
    prepare_alias(ev.buf)
    vim.schedule(function()
      replace(ev.buf, target.kind --[[@as shortcut.Kind]], target.id)
    end)
    return
  end
  local opts = pending[name] or {}
  pending[name] = nil
  load(ev.buf, target, opts, true)
end

---@param ev vim.api.keyset.create_autocmd.callback_args
local function on_write(ev)
  local buf = ev.buf
  if vim.b[buf].shortcut_comment ~= nil or vim.b[buf].shortcut_draft ~= nil then
    -- A comment buffer or a draft, written to whatever name: its own BufWriteCmd posts it or
    -- refuses.
    return
  end
  local info = vim.b[buf].shortcut
  if vim.api.nvim_buf_get_name(buf) ~= ev.match or type(info) ~= 'table' then
    notify.refuse_write(('cannot write to %s'):format(notify.flatten(ev.match)))
    return
  end
  local kind, id = info.kind, info.id
  -- 'nomodifiable' does not stop `:w`, and acwrite buffers are written even when unmodified.
  local state = load_state[buf]
  if state ~= 'loaded' then
    notify.refuse_write(
      state == 'loading' and ('sc-%d is still loading'):format(id)
        or ('sc-%d is not loaded; :e! to retry'):format(id)
    )
    return
  end
  local handler = registry[kind]
  if not handler or not handler.save then
    notify.refuse_write(('saving %s is not supported'):format(PLURAL[kind] or kind))
    return
  end

  local tick = vim.b[buf].changedtick
  local finished = false
  local in_write = true
  ---@type shortcut.buffer.SaveDone
  local function done(err, opts)
    main_loop(function()
      if finished then
        return
      end
      finished = true
      if err then
        -- Reported even if the buffer has gone: the changes were not saved.
        local msg = ('failed to save sc-%d: %s'):format(id, err)
        if in_write then
          -- Refused before anything was sent (e.g. invalid values).
          notify.refuse_write(msg)
        else
          notify.error(msg)
        end
      elseif
        not (opts and opts.keep_modified)
        and vim.api.nvim_buf_is_loaded(buf)
        and vim.b[buf].changedtick == tick
      then
        vim.bo[buf].modified = false
      end
    end)
  end

  local ok, err = pcall(handler.save, buf, id, { force = vim.v.cmdbang == 1 }, done)
  if not ok then
    done(error_message(err))
  end
  in_write = false
end

---@param ev vim.api.keyset.create_autocmd.callback_args
local function on_web_read(ev)
  -- In case the net plugin was sourced after this one and before VimEnter (e.g. a URL given
  -- on the command line). Its pending handler for this event is skipped once deleted.
  M.guard_net_plugin()
  if not is_routed_url(ev.match) then
    -- Some other Shortcut page: leave it to the built-in handler.
    return
  end
  local target = assert(uri.parse(ev.match))
  prepare_alias(ev.buf)
  check_workspace(target.workspace)
  vim.schedule(function()
    replace(ev.buf, target.kind --[[@as shortcut.Kind]], target.id, { comment = target.comment })
  end)
end

--- Read a real file into `buf` as `:edit` would. Used for names matching `sc-[0-9]*` that are not
--- `sc-<id>` references, since a `BufReadCmd` handler replaces Neovim's own reading.
---@param buf integer
---@param name string
local function read_file(buf, name)
  local stat = vim.uv.fs_stat(name)
  if stat and stat.type == 'directory' then
    return
  end
  if not stat then
    vim.api.nvim_exec_autocmds('BufNewFile', { buffer = buf, modeline = false })
    return
  end

  vim.api.nvim_buf_call(buf, function()
    vim.api.nvim_exec_autocmds('BufReadPre', { buffer = buf, modeline = false })
    local undolevels = vim.bo[buf].undolevels
    vim.bo[buf].undolevels = -1
    -- `++edit` detects 'fileformat', 'fileencoding', etc. as `:edit` would; `v:cmdarg` carries
    -- any `++opt` given to the `:edit`. Skip FileReadPre/Post, which `:edit` does not fire, but
    -- not other autocommands: SwapExists handlers (e.g. Neovim's default one) must still run.
    local eventignore = vim.go.eventignore
    vim.go.eventignore = (eventignore == '' and '' or eventignore .. ',')
      .. 'FileReadPre,FileReadPost'
    local ok, err = pcall(
      vim.api.nvim_command,
      ('keepalt read ++edit %s %s'):format(
        vim.v.cmdarg,
        -- Relative, so the file info message reads as it would for `:edit`.
        vim.fn.fnameescape(vim.fn.fnamemodify(name, ':~:.'))
      )
    )
    vim.go.eventignore = eventignore
    if ok then
      -- `:read` appends below the buffer's initial empty line.
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
    end
    vim.bo[buf].undolevels = undolevels
    vim.bo[buf].modified = false
    if not ok then
      notify.error(tostring(err))
      return
    end
    if vim.fn.filewritable(name) == 0 then
      vim.bo[buf].readonly = true
    end
    if vim.bo[buf].undofile then
      vim.cmd('silent! rundo ' .. vim.fn.fnameescape(vim.fn.undofile(name)))
    end
    -- Filetype detection etc. Neovim applies modelines itself once this handler returns.
    vim.api.nvim_exec_autocmds('BufReadPost', { buffer = buf, modeline = false })
  end)
end

---@param ev vim.api.keyset.create_autocmd.callback_args
local function on_sc_read(ev)
  local name = ev.match
  if name:match('^%a[%w+.-]*://') then
    -- A URL whose last component looks like `sc-<n>`: its own handlers deal with it.
    return
  end
  if sc_ids_enabled() then
    -- The pattern matches the tail of any path, but only a bare `sc-<id>` as typed (`ev.file`;
    -- `ev.match` is always a full path) is a reference; `notes/sc-42` is a file.
    local target = uri.parse(ev.file)
    if target and target.kind == 'id' and not vim.uv.fs_stat(name) then
      redirect_id(ev.buf, target.id)
      return
    end
  end
  read_file(ev.buf, name)
end

--- `'includeexpr'` that makes `gf` work on `sc-<id>`: Neovim's `gf` only opens names that exist
--- as files or look like URLs, so map `sc-<id>` to its not-yet-resolved `shortcut://` form.
--- Any other name is passed to `fallback`, a Vimscript expression (evaluated with the same
--- `v:fname`) or a Lua function, and returned unchanged if there is none.
---@param fname string
---@param fallback? string|fun(fname: string): string
---@return string
function M.includeexpr(fname, fallback)
  local target = uri.parse(fname)
  if target and target.kind == 'id' and sc_ids_enabled() then
    return uri.canonical('id', target.id)
  end
  if type(fallback) == 'function' then
    return fallback(fname)
  end
  if type(fallback) == 'string' and fallback ~= '' then
    local ok, result = pcall(vim.fn.eval, fallback)
    if ok and type(result) == 'string' then
      return result
    end
  end
  return fname
end

--- Make `gf` work on `sc-<id>` in a buffer that has its own 'includeexpr', by wrapping it: other
--- names still go through the original expression (kept in `b:shortcut_includeexpr`).
--- Idempotent.
---@param buf? integer Defaults to the current buffer.
function M.chain_includeexpr(buf)
  buf = buf == nil and vim.api.nvim_get_current_buf() or buf
  local current = vim.bo[buf].includeexpr
  if current == INCLUDEEXPR or current == CHAINED_INCLUDEEXPR then
    return
  end
  if current == '' then
    vim.bo[buf].includeexpr = INCLUDEEXPR
    return
  end
  vim.b[buf].shortcut_includeexpr = current
  vim.bo[buf].includeexpr = CHAINED_INCLUDEEXPR
end

--- Register or remove the `sc-<id>` handler according to `config.sc_ids`.
---@param enabled? boolean Defaults to the configured value.
function M.sync_sc_ids(enabled)
  if enabled == nil then
    enabled = sc_ids_enabled()
  end
  local group = vim.api.nvim_create_augroup(SC_GROUP, { clear = true })
  if enabled then
    vim.api.nvim_create_autocmd('BufReadCmd', {
      group = group,
      pattern = 'sc-[0-9]*',
      desc = 'shortcut.nvim: open sc-<id>',
      -- So that autocommands triggered while reading a real file (SwapExists) run.
      nested = true,
      callback = on_sc_read,
    })
  end
end

--- Open an object in the current window.
---@param kind shortcut.Kind
---@param id integer
---@param opts? { comment?: integer, workspace?: string, keepalt?: boolean }
function M.open(kind, id, opts)
  opts = opts or {}
  check_workspace(opts.workspace)
  edit(kind, id, { comment = opts.comment, keepalt = opts.keepalt })
end

--- Load a story or epic buffer again, as `:e!` does (discarding any changes). Does nothing for
--- other buffers.
---@param buf integer
---@return boolean reloaded
function M.reload(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local target = uri.parse(name)
  if
    not target
    or not uri.is_kind(target.kind)
    or uri.canonical(target.kind --[[@as shortcut.Kind]], target.id) ~= name
  then
    return false
  end
  load(buf, target, {})
  return true
end

--- The loaded buffer of a story or epic, if there is one.
---@param kind shortcut.Kind
---@param id integer
---@return integer?
function M.find(kind, id)
  local buf = find_buf(uri.canonical(kind, id))
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
  return nil
end

--- After `kind`/`id` changed on the server: reload its buffer if it is open and unmodified.
---@param kind shortcut.Kind
---@param id integer
---@return 'reloaded'|'modified'|nil result `nil` if there is no such buffer.
function M.reload_if_unmodified(kind, id)
  local buf = M.find(kind, id)
  if not buf then
    return nil
  end
  if vim.bo[buf].modified then
    return 'modified'
  end
  M.reload(buf)
  return 'reloaded'
end

--- Whether `id` is a story or an epic, as `sc-<id>` is resolved (see `set_resolver()`).
--- `done(kind)`, `done(nil)` if there is no such object, or `done(nil, err)`; on the main loop,
--- or at once if the answer is known.
---@param id integer
---@param done fun(kind?: shortcut.Kind, err?: string)
---@return { cancel: fun(self: any) }?
function M.resolve_kind(id, done)
  return resolve(id, done)
end

--- Create the autocommands. Called once when the plugin loads.
function M.setup()
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    pattern = 'shortcut://*',
    desc = 'shortcut.nvim: load story/epic',
    callback = on_read,
  })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    pattern = 'shortcut://*',
    desc = 'shortcut.nvim: save story/epic',
    callback = on_write,
  })
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    pattern = WEB_PATTERNS,
    desc = 'shortcut.nvim: open Shortcut URL',
    callback = on_web_read,
  })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter' }, {
    group = group,
    pattern = 'shortcut://*',
    desc = 'shortcut.nvim: keep modelines off',
    callback = function(ev)
      -- With 'cpoptions' containing `S`, entering a buffer copies the global options into it,
      -- 'modeline' included. Modelines are applied after the autocommands for an event, so
      -- turning it off again here keeps server text from setting options.
      vim.bo[ev.buf].modeline = false
    end,
  })
  vim.api.nvim_create_autocmd('BufUnload', {
    group = group,
    pattern = 'shortcut://*',
    callback = function(ev)
      -- Invalidate any load in flight. Not reset to nil: a reload restarting the count could
      -- match that load's generation again.
      generation[ev.buf] = (generation[ev.buf] or 0) + 1
      load_state[ev.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    pattern = 'shortcut://*',
    callback = function(ev)
      -- Buffer numbers are never reused.
      generation[ev.buf] = nil
    end,
  })
  -- Plugin managers source plugins in varying orders relative to $VIMRUNTIME/plugin.
  vim.api.nvim_create_autocmd('VimEnter', {
    group = group,
    once = true,
    callback = M.guard_net_plugin,
  })
  M.guard_net_plugin()

  -- Don't load the config module at startup just to read the default; if the user called
  -- setup() already it is loaded, and later setup() calls run sync_sc_ids() themselves.
  local config = package.loaded['shortcut.config']
  M.sync_sc_ids(config == nil or config.get().sc_ids)

  -- Only where nothing else is set: buffer-local values (from ftplugins) take precedence.
  if vim.go.includeexpr == '' then
    vim.go.includeexpr = INCLUDEEXPR
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].includeexpr == '' then
        vim.bo[buf].includeexpr = INCLUDEEXPR
      end
    end
  end
  -- Commit messages are where sc-<id> appears most, and the gitcommit ftplugin sets its own
  -- 'includeexpr'. Chaining keeps its behaviour for every other name. Deferred so it runs after
  -- the ftplugin whatever order the FileType handlers were defined in (this plugin may be loaded
  -- from init.lua, before filetype plugins are enabled).
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'gitcommit',
    desc = 'shortcut.nvim: gf on sc-<id>',
    callback = function(ev)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(ev.buf) and vim.bo[ev.buf].filetype == 'gitcommit' then
          M.chain_includeexpr(ev.buf)
        end
      end)
    end,
  })
end

--- Forget cached `sc-<id>` kinds (for tests).
function M._clear_cache()
  kind_cache = {}
end

return M

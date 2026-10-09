--- The story named by the current git branch.
---
--- Shortcut's branch names look like `<user>/sc-<id>/<slug>`; the first `sc-<digits>` in the
--- branch name is the story. `git` runs asynchronously (`vim.system`), never blocking the UI.
local M = {}

--- Longest wait for `git`, in milliseconds.
M.TIMEOUT = 5000

--- The story ID in a branch name: the first `sc-<digits>` that starts a word (so `misc-12` is
--- not one), or `nil`.
---@param branch string
---@return integer?
function M.story_id(branch)
  if type(branch) ~= 'string' then
    return nil
  end
  local max = require('shortcut.uri').MAX_ID
  for digits in branch:gmatch('%f[%w]sc%-(%d+)') do
    local id = tonumber(digits)
    if id and id >= 1 and id <= max then
      return id
    end
  end
  return nil
end

--- The directory of the file in `buf`, if it is a file on disk; `nil` for scratch buffers, URLs
--- (`fugitive://`, `shortcut://`, ...) and unnamed buffers.
---@param buf? integer Defaults to the current buffer.
---@return string?
function M.buffer_dir(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf --[[@as integer]]
  if vim.bo[buf].buftype ~= '' then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or name:match('^%a[%w+.-]*://') then
    return nil
  end
  local dir = vim.fs.dirname(vim.fs.abspath(name))
  local stat = vim.uv.fs_stat(dir)
  return stat and stat.type == 'directory' and dir or nil
end

--- The directory to look for the repository in: the current file's, else the working
--- directory. Call it on the main loop.
---@param buf? integer Defaults to the current buffer.
---@return string
function M.dir(buf)
  return M.buffer_dir(buf) or vim.fn.getcwd()
end

---@param stderr? string
---@param code integer
---@return string
local function git_error(stderr, code)
  local text = vim.trim(stderr or '')
  if text:find('not a git repository', 1, true) then
    return 'not in a git repository'
  end
  if text:find("ambiguous argument 'HEAD'", 1, true) or text:find('unknown revision', 1, true) then
    return 'the git repository has no commits yet'
  end
  local first = vim.split(text, '\n', { plain = true })[1] or ''
  first = first:gsub('^fatal: ', '')
  if first == '' then
    return ('git exited with code %d'):format(code)
  end
  return first
end

--- The current branch of the repository containing `dir`. `callback(err, branch)` runs on the
--- main loop; `err` is a message (e.g. not in a repository, or a detached HEAD).
---@param dir string
---@param callback fun(err?: string, branch?: string)
function M.branch(dir, callback)
  local function finish(err, branch)
    vim.schedule(function()
      callback(err, branch)
    end)
  end
  local ok, proc = pcall(vim.system, { 'git', 'rev-parse', '--abbrev-ref', 'HEAD' }, {
    cwd = dir,
    text = true,
    timeout = M.TIMEOUT,
  }, function(res)
    if res.code ~= 0 then
      return finish(res.code == 124 and 'git timed out' or git_error(res.stderr, res.code))
    end
    local branch = vim.trim(res.stdout or '')
    if branch == 'HEAD' then
      return finish('detached HEAD: not on a branch')
    end
    if branch == '' then
      return finish('git printed no branch name')
    end
    finish(nil, branch)
  end)
  if not ok then
    -- git is not installed, or `dir` does not exist.
    local msg = vim.split(tostring(proc), '\n', { plain = true })[1]
    finish(('cannot run git: %s'):format(msg))
  end
end

--- The story named by the current branch of the repository containing `dir`.
--- `callback(err, id, branch)` runs on the main loop: `err` if there is no branch, `id` `nil`
--- (and `branch` set) if the branch names no story.
---@param dir string
---@param callback fun(err?: string, id?: integer, branch?: string)
function M.branch_story(dir, callback)
  M.branch(dir, function(err, branch)
    if err then
      return callback(err)
    end
    callback(nil, M.story_id(branch --[[@as string]]), branch)
  end)
end

return M

--- Small file helpers shared by the `short` config writer and the lookup-list cache.
---
--- Only libuv calls: everything here also works in fast (libuv callback) contexts.
local M = {}

---@param path string
---@return boolean
function M.exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

--- Create `dir` and any missing parents.
---@param dir string
---@param mode integer Mode of `dir` itself; created parents get 0755 (less the umask).
---@return boolean ok
---@return string? err
function M.mkdir_p(dir, mode)
  if M.exists(dir) then
    return true
  end
  local parent = vim.fs.dirname(dir)
  if parent ~= dir then
    local ok, err = M.mkdir_p(parent, tonumber('755', 8))
    if not ok then
      return false, err
    end
  end
  local ok, err, code = vim.uv.fs_mkdir(dir, mode)
  if not ok and code ~= 'EEXIST' then
    return false, ('cannot create %s: %s'):format(dir, err)
  end
  return true
end

--- Read a whole file.
---@param path string
---@return string? data
---@return string? err
---@return string? code libuv error name, e.g. `ENOENT`.
function M.read_file(path)
  local fd, open_err, code = vim.uv.fs_open(path, 'r', 0)
  if not fd then
    return nil, open_err, code
  end
  local stat = vim.uv.fs_fstat(fd)
  local data, read_err, read_code = vim.uv.fs_read(fd, stat and stat.size or 0, 0)
  vim.uv.fs_close(fd)
  if not data then
    return nil, read_err, read_code
  end
  return data
end

--- Replace `path` with `data` atomically: write a temporary file in the same directory, then
--- rename it over `path`. The file ends up with mode 0600 whatever the umask.
---@param path string
---@param data string
---@return boolean ok
---@return string? err
function M.write_atomic(path, data)
  local dir = vim.fs.dirname(path)
  local tmp = ('%s/.%s.%d.%d.tmp'):format(
    dir,
    vim.fs.basename(path),
    vim.uv.os_getpid(),
    vim.uv.hrtime()
  )
  local fd, err = vim.uv.fs_open(tmp, 'wx', tonumber('600', 8))
  if not fd then
    return false, ('cannot write %s: %s'):format(tmp, err)
  end
  local written, write_err = vim.uv.fs_write(fd, data, 0)
  ---@type boolean?
  local ok = written == #data
  if ok then
    ok, write_err = vim.uv.fs_fsync(fd)
  end
  if ok then
    -- The mode given to open() is reduced by the umask; make it exactly 0600.
    ok, write_err = vim.uv.fs_fchmod(fd, tonumber('600', 8))
  end
  vim.uv.fs_close(fd)
  if ok then
    ok, write_err = vim.uv.fs_rename(tmp, path)
  end
  if not ok then
    write_err = write_err or 'short write'
    vim.uv.fs_unlink(tmp)
    return false, ('cannot write %s: %s'):format(path, write_err)
  end
  return true
end

return M

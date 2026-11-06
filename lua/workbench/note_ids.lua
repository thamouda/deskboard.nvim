-- Monotonic NOTE-001 IDs shared by a vault set. Reservations survive cancelled
-- unsaved buffers and deletion. Lock contention fails closed (never reuses IDs).
local M = {}
local uv = vim.uv or vim.loop
local MAX = 2147483646

local function canonical(root)
  local parent, suffix = root, {}
  while true do
    local real = uv.fs_realpath(parent)
    if real then
      return #suffix > 0 and (real:gsub("/+$", "") .. "/" .. table.concat(suffix, "/")) or real
    end
    local next_parent = vim.fn.fnamemodify(parent, ":h")
    if next_parent == parent then return root end
    table.insert(suffix, 1, vim.fn.fnamemodify(parent, ":t"))
    parent = next_parent
  end
end

function M.paths(opts)
  opts = opts or {}
  local roots = require("workbench.notes").roots(opts)
  local keys, seen = {}, {}
  for _, root in pairs(roots) do
    local key = canonical(root)
    if not seen[key] then keys[#keys + 1] = key; seen[key] = true end
  end
  table.sort(keys)
  local directory = opts.id_state_dir or (require("workbench.config").get().notes.legacy_globals and vim.g.sprint_note_id_state_dir)
    or require("workbench.config").get().notes.id_state_dir or vim.fn.stdpath("state") .. "/workbench/note-ids"
  local path = directory .. "/" .. vim.fn.sha256(vim.json.encode(keys)):sub(1, 24) .. ".json"
  return path, path .. ".lock", roots
end

function M.next(opts)
  if not require("workbench.config").writable() then return nil, "Note writes are disabled; enable notes.allow_writes explicitly" end
  local path, lock, roots = M.paths(opts)
  local made = pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p", 448)
  if not made then return nil, "Cannot create note ID state directory" end
  local fd = uv.fs_open(lock, "wx", 384)
  if not fd then return nil, "Note ID allocator is busy; retry after the other operation finishes" end
  uv.fs_write(fd, tostring(vim.fn.getpid()), 0); uv.fs_close(fd)
  local ok, value = xpcall(function()
    local last = 0
    if uv.fs_lstat(path) then
      local stat = uv.fs_lstat(path)
      if stat.type ~= "file" then error("Unsafe note ID state file") end
      local read, state = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) end)
      if not read or type(state) ~= "table" or type(state.last) ~= "number" or state.last < 0
        or state.last ~= math.floor(state.last) or state.last > MAX then error("Invalid note ID state; repair it before allocating IDs") end
      last = state.last
    end
    local function consider(id)
      local digits = type(id) == "string" and id:match("^NOTE%-(%d+)$")
      if digits then
        local number = tonumber(digits)
        if not number or number > MAX then error("Note ID range exceeded") end
        last = math.max(last, number)
      end
    end
    local function lines_ids(lines)
      if (lines[1] or ""):gsub("\r$", "") ~= "---" then return end
      for i = 2, math.min(64, #lines) do
        local line = lines[i]:gsub("\r$", "")
        if line == "---" or line == "..." then break end
        consider(line:match('^id:%s*["\']?(NOTE%-%d+)["\']?%s*#?.*$'))
      end
    end
    local function scan(dir, depth)
      local entries, _, code = uv.fs_scandir(dir)
      if not entries then
        if code ~= "ENOENT" then error("Cannot scan notes to reserve a unique ID") end
        return
      end
      while true do
        local name, kind = uv.fs_scandir_next(entries)
        if not name then break end
        local file = dir .. "/" .. name
        if kind == "directory" and depth < 12 and (name:sub(1, 1) ~= "." or name == ".trash") then
          scan(file, depth + 1)
        elseif kind == "file" and name:lower():match("%.md$") and name:lower() ~= "index.md" then
          local handle = io.open(file, "r")
          if not handle then error("Cannot read note headers to reserve a unique ID") end
          local text = handle:read(16384) or ""; handle:close()
          lines_ids(vim.split(text, "\n", { plain = true }))
        end
      end
    end
    for _, root in pairs(roots) do scan(root, 0) end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        for _, root in pairs(roots) do
          if name:sub(1, #root + 1) == root .. "/" then
            lines_ids(vim.api.nvim_buf_get_lines(buf, 0, math.min(64, vim.api.nvim_buf_line_count(buf)), false))
            break
          end
        end
      end
    end
    if last >= MAX then error("Note ID range exceeded") end
    last = last + 1
    local temporary = path .. ".tmp-" .. uv.hrtime()
    local out = uv.fs_open(temporary, "wx", 384)
    if not out then error("Cannot reserve note ID") end
    local text = vim.json.encode({ version = 1, last = last }) .. "\n"
    local written = uv.fs_write(out, text, 0)
    local synced = uv.fs_fsync(out)
    uv.fs_close(out)
    if written ~= #text or not synced or not uv.fs_rename(temporary, path) then uv.fs_unlink(temporary); error("Cannot persist note ID reservation") end
    return ("NOTE-%03d"):format(last)
  end, function(err) return tostring(err):gsub("^.-:%d+: ", "") end)
  uv.fs_unlink(lock)
  if not ok then return nil, value end
  return value
end

return M

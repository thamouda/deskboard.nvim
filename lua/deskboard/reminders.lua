-- Explicit checkbox writes to the configured reminder source, never note metadata.
local M = {}
local uv = vim.uv

local function refuse(message)
  vim.notify(message, vim.log.levels.WARN, { title = "Reminders" })
  return false
end

local function stamp(path)
  local stat = uv.fs_lstat(path)
  return stat and { ino = stat.ino, size = stat.size, mtime = stat.mtime }
end

function M.toggle_status(row)
  local cfg = require("deskboard.config").get()
  if cfg.demo or not require("deskboard.config").writable() then
    return refuse("Reminder writes are disabled; enable notes.enabled and notes.allow_writes explicitly")
  end
  local source = cfg.reminders.path or cfg.providers.jira.snapshot
  if not row or type(source) ~= "string" or type(row.path) ~= "string"
    or type(row.lnum) ~= "number" or row.lnum < 1 or row.lnum ~= math.floor(row.lnum)
    or type(row.source_line) ~= "string" then return false end
  local path = vim.fn.fnamemodify(vim.fn.expand(source), ":p")
  if vim.fn.fnamemodify(vim.fn.expand(row.path), ":p") ~= path then return false end
  local stat = uv.fs_lstat(path)
  if not stat or stat.type ~= "file" or not uv.fs_access(path, "w") then
    return refuse("Reminder source is missing, read-only or not a regular file")
  end
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and name ~= "" and uv.fs_realpath(name) == uv.fs_realpath(path) then
      if vim.bo[buf].modified or vim.bo[buf].readonly or not vim.bo[buf].modifiable then
        return refuse("Reminder source has unsaved edits or is read-only; resolve it first")
      end
      buffers[#buffers + 1] = buf
    end
  end
  local before = stamp(path)
  -- Binary reads preserve CRLF and whether the source ends with a newline.
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  if not ok then return refuse("Cannot read reminder source") end
  local line = lines[row.lnum]
  if line ~= row.source_line then return refuse("Reminder source changed; refresh the dashboard before toggling") end
  local prefix, marker, suffix = line:match("^(%s*%-%s*%[)([ xX])(%].*)$")
  if not prefix then return refuse("Only checkbox reminders can be toggled; Enter/o edits the source") end
  if suffix:sub(2):match("^%s*%u[%u%d]*%-%d+") then return false end
  lines[row.lnum] = prefix .. (marker == " " and "x" or " ") .. suffix
  local text = table.concat(lines, "\n")
  local temporary = path .. ".tmp-" .. tostring(uv.hrtime())
  local fd = uv.fs_open(temporary, "wx", stat.mode % 512)
  if not fd then return refuse("Cannot write reminder source") end
  local written = uv.fs_write(fd, text, 0)
  uv.fs_close(fd)
  if written ~= #text or not vim.deep_equal(stamp(path), before) then
    uv.fs_unlink(temporary)
    return refuse("Reminder source changed or could not be written; refresh and retry")
  end
  if not uv.fs_rename(temporary, path) then
    uv.fs_unlink(temporary)
    return refuse("Cannot save reminder source")
  end
  -- checktime can miss same-size toggles within one second. Reload only the
  -- clean, writable buffers verified above, without changing the user's options.
  for _, buf in ipairs(buffers) do
    vim.api.nvim_buf_call(buf, function() vim.cmd("edit!") end)
  end
  return true
end

return M

-- Local Markdown knowledge index. No bodies in dashboard rows, no remote sync.
local M = {}
local metadata = require("workbench.note_metadata")
local cache = {}
local uv = vim.uv or vim.loop

local function clean(value)
  return vim.trim((value or ""):gsub("[%z\1-\31\127]", " "))
end

function M.roots(opts)
  opts = opts or {}
  local cfg = require("workbench.config").get().notes
  if not cfg.enabled and not opts.root and not opts.roots then return {} end
  local roots = opts.roots or (opts.root and { personal = opts.root })
    or (cfg.legacy_globals and vim.g.sprint_note_roots) or cfg.roots or {}
  local result = {}
  for name, path in pairs(roots) do
    result[name] = vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/+$", "")
  end
  return result
end

local function header(path, stat)
  local buf = vim.fn.bufnr(path)
  if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, math.min(64, vim.api.nvim_buf_line_count(buf)), false)
  end
  local stamp = stat.size .. ":" .. stat.mtime.sec .. ":" .. stat.mtime.nsec
  if cache[path] and cache[path].stamp == stamp then return cache[path].lines end
  local file, lines = io.open(path, "r"), {}
  if file then
    local text = file:read(16384) or ""; file:close()
    for line in (text .. "\n"):gmatch("(.-)\n") do
      if #lines == 64 then break end
      lines[#lines + 1] = line:gsub("\r$", "")
    end
  end
  cache[path] = { stamp = stamp, lines = lines }
  return lines
end

local function heading(lines, finish)
  local fence
  for i = (finish or 0) + 1, #lines do
    local line = lines[i]:gsub("\r$", "")
    local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if marker then
      if not fence then fence = marker:sub(1, 1) elseif marker:sub(1, 1) == fence then fence = nil end
    elseif not fence then
      local value = line:match("^#%s+(.+)")
      if value then return clean(value:gsub("%s+#+%s*$", "")) end
    end
  end
end

function M.describe(path, root, scope, stat)
  stat = stat or uv.fs_stat(path)
  if not stat then return nil end
  local lines = header(path, stat)
  local meta = metadata.parse(lines)
  local fallback = clean(vim.fn.fnamemodify(path, ":t:r"):gsub("[_%-]", " "))
  local title = meta.title or heading(lines, meta.finish) or fallback
  local relative = path:sub(#root + 2)
  local category = relative:match("^(.*)/[^/]+$") or "general"
  return {
    id = "note:" .. (meta.valid and meta.uid or path), uid = meta.valid and meta.uid or nil, previous_id = meta.previous_id,
    title = clean(title) ~= "" and clean(title) or "Untitled note", path = path, lnum = 1,
    root = root, scope = scope, category = category, kind = "file", tags = meta.tags or {},
    status = meta.valid and meta.status or "inbox", visibility = meta.valid and meta.visibility or "private",
    note_type = meta.type or "note", reviewed = meta.reviewed, review_due = meta.review_due,
    metadata_error = meta.error, mtime = stat.mtime.sec,
    dirty = vim.fn.bufnr(path) >= 0 and vim.bo[vim.fn.bufnr(path)].modified or false,
  }
end

function M.list(opts)
  opts = opts or {}
  local notes, present, ids = {}, {}, {}
  local reminder_path = vim.fn.fnamemodify(opts.reminder_path or require("workbench.config").get().reminders.path or "", ":p")
  for scope, root in pairs(M.roots(opts)) do
    local function scan(dir, depth)
      local entries = uv.fs_scandir(dir)
      if not entries then return end
      while true do
        local name, kind = uv.fs_scandir_next(entries)
        if not name then break end
        local path = dir .. "/" .. name
        if name:sub(1, 1) ~= "." then
          if kind == "directory" and depth < 8 then scan(path, depth + 1)
          elseif kind == "file" and name:lower():match("%.md$") and name:lower() ~= "index.md" and path ~= reminder_path then
            local note = M.describe(path, root, scope)
            if note and not present[path] then
              present[path] = true; notes[#notes + 1] = note
              if note.uid then ids[note.uid] = ids[note.uid] or {}; table.insert(ids[note.uid], note) end
            end
          end
        end
      end
    end
    scan(root, 0)
  end
  for _, duplicates in pairs(ids) do
    if #duplicates > 1 then
      for _, note in ipairs(duplicates) do
        note.metadata_error, note.id, note.visibility = "Duplicate note ID", "note:" .. note.path, "private"
      end
    end
  end
  for path in pairs(cache) do if not present[path] then cache[path] = nil end end
  for _, value in ipairs(opts.reminders or {}) do
    if type(value.title) == "string" and clean(value.title) ~= "" then
      local note = vim.tbl_extend("force", {}, value)
      note.title, note.kind, note.scope, note.category = clean(note.title), "reminder", "reminders", "inbox"
      note.status, note.visibility, note.tags = note.done and "archived" or "inbox", "private", {}
      notes[#notes + 1] = note
    end
  end
  table.sort(notes, function(a, b)
    if a.title:lower() ~= b.title:lower() then return a.title:lower() < b.title:lower() end
    return a.id < b.id
  end)
  return notes
end

function M.overdue(note, today)
  return note.status ~= "archived" and metadata.date(note.review_due) and note.review_due < (today or os.date("%Y-%m-%d"))
end

function M.needs_review(note, today)
  today = today or os.date("%Y-%m-%d")
  return note.status ~= "archived" and (note.metadata_error ~= nil or note.status == "review"
    or (metadata.date(note.review_due) and note.review_due <= today))
end

function M.ready(note, today)
  today = today or os.date("%Y-%m-%d")
  return note.kind == "file" and not note.dirty and type(note.uid) == "string" and note.uid ~= "" and not note.metadata_error
    and note.status == "ready" and note.visibility == "team"
    and metadata.date(note.reviewed) and note.reviewed <= today
    and metadata.date(note.review_due) and note.review_due > today
end

function M.filter(notes, filters, today)
  filters = filters or {}
  local result = {}
  for _, note in ipairs(notes) do
    local category = (note.scope or "personal") .. "/" .. (note.category or "general")
    local tag = not filters.tag or vim.tbl_contains(note.tags or {}, filters.tag)
    local queue = not filters.queue or filters.queue == "all"
      or filters.queue == "inbox" and note.status == "inbox"
      or filters.queue == "review" and M.needs_review(note, today)
      or filters.queue == "ready" and M.ready(note, today)
      or filters.queue == "overdue" and M.overdue(note, today)
    if tag and queue and (not filters.status or note.status == filters.status)
      and (not filters.category or category == filters.category or category:sub(1, #filters.category + 1) == filters.category .. "/") then
      result[#result + 1] = note
    end
  end
  return result
end

function M.facets(notes, key)
  local seen, result = {}, {}
  for _, note in ipairs(notes) do
    local values = key == "tag" and (note.tags or {}) or { (note.scope or "personal") .. "/" .. (note.category or "general") }
    for _, value in ipairs(values) do
      if key == "category" then
        local path = ""
        for part in value:gmatch("[^/]+") do
          path = path == "" and part or path .. "/" .. part
          if not seen[path] then seen[path] = true; result[#result + 1] = path end
        end
      elseif not seen[value] then seen[value] = true; result[#result + 1] = value end
    end
  end
  table.sort(result)
  return result
end

function M.summary(notes, today)
  local result = { inbox = 0, review = 0, ready = 0, overdue = 0 }
  for _, note in ipairs(notes) do
    result.inbox = result.inbox + (note.status == "inbox" and 1 or 0)
    result.review = result.review + (M.needs_review(note, today) and 1 or 0)
    result.ready = result.ready + (M.ready(note, today) and 1 or 0)
    result.overdue = result.overdue + (M.overdue(note, today) and 1 or 0)
  end
  return result
end

function M.open(note)
  if not note or type(note.path) ~= "string" then return end
  local buf = vim.fn.bufnr(note.path)
  if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_set_current_buf(buf) -- never :edit/reload an unsaved note
  else
    vim.cmd.edit(vim.fn.fnameescape(note.path))
  end
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(note.lnum or 1, vim.api.nvim_buf_line_count(0))), 0 })
  if note.kind == "file" and note.root then require("workbench.note_actions").watch(note) end
end

return M

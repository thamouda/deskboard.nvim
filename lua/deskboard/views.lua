-- Dashboard view/page state and an independent, read-only review queue.
local M = {}
local View = {}
View.__index = View
local ORDER = { "mine", "reviews", "notes", "reminders" }

function M.paginate(rows, page, size)
  size = math.max(1, math.floor(tonumber(size) or 6))
  local pages = math.max(1, math.ceil(#rows / size))
  page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))
  local first, last = (page - 1) * size + 1, math.min(page * size, #rows)
  local result = {}
  for i = first, last do result[#result + 1] = rows[i] end
  return result, { page = page, pages = pages, total = #rows, first = #rows == 0 and 0 or first, last = last }
end

local function redraw()
  if _G.Snacks and Snacks.dashboard then pcall(Snacks.dashboard.update) end
end

local function unknown(value)
  return value == nil or value == vim.NIL
end

local function count(value)
  return type(value) == "number" and value >= 0 and value == math.floor(value)
end

local function threads(value)
  return unknown(value) or (type(value) == "table" and count(value.resolved) and count(value.total) and value.resolved <= value.total)
end

-- Disk snapshots and live responses share validation: malformed cached data
-- must never become an actionable MR row.
local function valid_report(report)
  if type(report) ~= "table" or report.version ~= 1 or report.ok ~= true
    or type(report.user) ~= "table" or type(report.user.username) ~= "string"
    or type(report.rows) ~= "table" or not vim.islist(report.rows) then return false end
  for _, row in ipairs(report.rows) do
    if type(row) ~= "table" or not count(row.iid) or row.iid < 1
      or type(row.title) ~= "string" or type(row.author) ~= "string"
      or type(row.project) ~= "string" or type(row.web_url) ~= "string" or type(row.target_branch) ~= "string"
      or (not unknown(row.commits) and not count(row.commits))
      or (not unknown(row.approved) and not count(row.approved))
      or (not unknown(row.my_approved) and type(row.my_approved) ~= "boolean")
      or (not unknown(row.other_approvals) and not count(row.other_approvals))
      or (not unknown(row.ci) and type(row.ci) ~= "string")
      or (row.state ~= nil and type(row.state) ~= "string")
      or (row.labels ~= nil and type(row.labels) ~= "string")
      or not threads(row.threads) or not threads(row.my_threads) then return false end
  end
  return true
end

function M.fetch(opts, done)
  local github = opts.provider == "github"
  local name = github and "GitHub" or "GitLab"
  local script = opts.script or require("deskboard.config").root() .. "/scripts/" .. (github and "github-sync.py" or "sprint-sync.py")
  if not opts.host or not opts.project then done(nil, "Configure the " .. name .. " provider first"); return function() end end
  local command = github and { "python3", script, "--kind", opts.kind or "reviews", "--project", opts.project }
    or { "python3", script, "--reviews", "--host", opts.host, "--project", opts.project, "--proxy", opts.proxy or "" }
  if not github and opts.token_command then vim.list_extend(command, { "--token-command", vim.json.encode(opts.token_command) }) end
  local cancelled = false
  local function receive(result)
    if cancelled then return end
    local ok, report = pcall(vim.json.decode, result.stdout or "")
    if result.code == 0 and ok and type(report) == "table" and report.version == 1 and report.ok == true then
      if not valid_report(report) then done(nil, name .. " returned invalid review assignments"); return end
      done(report)
    else
      -- Never surface raw CLI output, exception text, tokens, or descriptions.
      local warning = ok and type(report) == "table" and type(report.warnings) == "table" and report.warnings[1]
      done(nil, type(warning) == "string" and warning or result.code == 124 and "Review queue request timed out"
        or "Queue unavailable (" .. name .. " authentication, CLI, or network)")
    end
  end
  local ok, job = pcall(opts.run or vim.system, command, { text = true, timeout = 90000 }, vim.schedule_wrap(receive))
  if not ok then receive({ code = -1 }) end
  return function()
    cancelled = true
    if ok and job then pcall(function() job:kill(15) end) end
  end
end

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    active = opts.local_only and "notes" or "mine", order = opts.local_only and { "notes", "reminders" } or ORDER,
    local_only = opts.local_only == true,
    pages = { mine = 1, reviews = 1, notes = 1, reminders = 1 }, totals = { mine = 0, reviews = 0, notes = 0, reminders = 0 },
    selected = { mine = {}, reviews = {}, notes = {}, reminders = {} }, rows = {}, notes = {}, reminders = {}, note_filter = {},
    size = math.max(1, math.floor(tonumber(opts.page_size) or 6)),
    host = opts.host, project = opts.project, proxy = opts.proxy, token_command = opts.token_command,
    cache_file = opts.cache_file, provider = opts.provider or "gitlab", kind = opts.kind or "reviews",
    remote_enabled = not opts.local_only and (opts.fetch ~= nil or opts.enabled == true),
    fetch = opts.fetch or M.fetch, now = opts.now or os.time,
    changed = opts.changed or redraw,
  }, View)
  if self.remote_enabled and self.cache_file then
    local ok, saved = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(self.cache_file), "\n"))
    end)
    if ok and valid_report(saved) and saved.host == self.host and saved.project == self.project
      and (saved.provider or "gitlab") == self.provider and (saved.kind or "reviews") == self.kind
      and type(saved.fetched_at) == "number" and saved.fetched_at > 0 and saved.fetched_at < math.huge then
      self:set_report(saved, saved.fetched_at, true)
    end
  end
  if not opts.local_only and opts.issues_config then
    self.issues = M.new(vim.tbl_extend("force", {}, opts.issues_config, { kind = "issues", page_size = self.size,
      changed = function() self:set_total("mine", #self.issues.rows); self.changed() end }))
    self:set_total("mine", #self.issues.rows)
  end
  return self
end

function View:set_report(report, fetched_at, from_cache)
  self.rows, self.user, self.fetched_at, self.error = report.rows, report.user, fetched_at, nil
  self.from_cache = from_cache
  local warnings = {}
  for _, value in ipairs(type(report.warnings) == "table" and report.warnings or {}) do
    if type(value) == "string" then warnings[#warnings + 1] = value end
  end
  self.warnings = warnings
  self.warning = #warnings > 0 and table.concat(warnings, " · ") or nil
  self:set_total("reviews", #self:review_rows())
end

function View:save_cache()
  if not self.cache_file then return end
  -- Persist only the displayed snapshot, never provider options, credentials,
  -- raw CLI output, or arbitrary fields from the response.
  pcall(function()
    local rows = {}
    for _, row in ipairs(self.rows) do
      local saved = {}
      for _, key in ipairs({ "iid", "title", "author", "project", "web_url", "target_branch",
        "commits", "approved", "my_approved", "other_approvals", "ci", "state", "labels" }) do saved[key] = row[key] end
      for _, key in ipairs({ "threads", "my_threads" }) do
        local value = row[key]
        saved[key] = type(value) == "table" and { resolved = value.resolved, total = value.total } or value
      end
      rows[#rows + 1] = saved
    end
    local encoded = vim.json.encode({ version = 1, ok = true, host = self.host, project = self.project, provider = self.provider, kind = self.kind,
      fetched_at = self.fetched_at, user = { username = self.user.username }, rows = rows, warnings = self.warnings })
    local dir = vim.fs.dirname(self.cache_file)
    vim.fn.mkdir(dir, "p")
    -- mkstemp uses private permissions; rename keeps the previous snapshot
    -- intact if a write fails or Neovim exits mid-write.
    local fd, path = vim.uv.fs_mkstemp(dir .. "/.reviews-XXXXXX")
    if not fd then return end
    local written = vim.uv.fs_write(fd, encoded, 0)
    vim.uv.fs_close(fd)
    if written ~= #encoded or not vim.uv.fs_rename(path, self.cache_file) then vim.uv.fs_unlink(path) end
  end)
end

function View:set_total(view, total)
  self.totals[view] = total
  local pages = math.max(1, math.ceil(total / self.size))
  self.pages[view] = math.max(1, math.min(self.pages[view], pages))
end

function View:selection()
  return self.selected[self.active][self.pages[self.active]]
end

function View:select(id)
  self.selected[self.active][self.pages[self.active]] = id
end

function View:move(delta)
  local pages = math.max(1, math.ceil(self.totals[self.active] / self.size))
  local next_page = math.max(1, math.min(pages, self.pages[self.active] + delta))
  if next_page ~= self.pages[self.active] then
    self.pages[self.active] = next_page
    self.changed()
  end
end

function View:is_available(view)
  return vim.tbl_contains(self.order, view)
end

function View:switch(view)
  if self.disposed or not self:is_available(view) then return end
  if self.active ~= view then self.previous, self.active = self.active, view end
  if self.active == "reviews" and self:needs_refresh() then
    self:refresh()
  elseif self.active == "mine" and self.issues and self.issues:needs_refresh() then
    self:refresh_mine()
  else
    self.changed()
  end
end

function View:toggle(delta)
  local index = 1
  for i, name in ipairs(self.order) do if name == self.active then index = i; break end end
  self:switch(self.order[(index - 1 + (delta or 1)) % #self.order + 1])
end

function View:review_rows()
  if not self.author then return self.rows end
  local result = {}
  for _, row in ipairs(self.rows) do
    if row.author:lower() == self.author:lower() then result[#result + 1] = row end
  end
  return result
end

function View:authors()
  local seen, result = {}, {}
  for _, row in ipairs(self.rows) do
    local name = row.author
    if name ~= "" and not seen[name:lower()] then
      seen[name:lower()] = true
      result[#result + 1] = name
    end
  end
  table.sort(result, function(a, b) return a:lower() < b:lower() end)
  return result
end

function View:set_author(author)
  author = type(author) == "string" and author:gsub("^@", "") or nil
  if author == "" then author = nil end
  if author == self.author then return end
  self.author, self.pages.reviews, self.selected.reviews = author, 1, {}
  self:set_total("reviews", #self:review_rows())
  self.changed()
end

function View:note_rows()
  if not next(self.note_filter) then return self.notes end
  return require("deskboard.notes").filter(self.notes, self.note_filter)
end

function View:set_notes_filter(key, value)
  if not vim.tbl_contains({ "category", "status", "tag", "queue" }, key) then return end
  if value == "" or value == "all" then value = nil end
  if self.note_filter[key] == value then return end
  self.note_filter[key], self.pages.notes, self.selected.notes = value, 1, {}
  self:set_total("notes", #self:note_rows())
  self.changed()
end

function View:clear_notes_filters()
  self.note_filter, self.pages.notes, self.selected.notes = {}, 1, {}
  self:set_total("notes", #self.notes)
  self.changed()
end

function View:set_notes(notes)
  self.notes, self.notes_loaded = notes, true
  self:set_total("notes", #self:note_rows())
end

function View:set_reminders(reminders)
  self.reminders = reminders
  self:set_total("reminders", #reminders)
end

function View:needs_refresh()
  return self.remote_enabled and not self.disposed and not self.loading and (not self.last_attempt or self.now() - self.last_attempt >= (self.error and 20 or 300))
end

function View:ensure_mine()
  if not self.issues or not self.issues:needs_refresh() or self.mine_scheduled then return end
  self.mine_scheduled = true
  vim.schedule(function()
    self.mine_scheduled = nil
    if not self.disposed and self.active == "mine" and self.issues:needs_refresh() then self:refresh_mine() end
  end)
end

function View:refresh_mine()
  if self.issues then return self.issues:refresh() end
  return false
end

function View:refresh()
  if self.disposed then return false end
  if not self.remote_enabled then self.error = (self.provider == "github" and "GitHub" or "GitLab") .. " provider is disabled"; self.changed(); return false end
  if self.loading then return false end
  self.loading, self.error, self.last_attempt = true, nil, self.now()
  self.generation = (self.generation or 0) + 1
  local generation = self.generation
  self.changed()
  local cancel = self.fetch(self, function(report, err)
    if self.generation ~= generation then return end
    self.loading, self.cancel = false, nil
    if report and valid_report(report) then
      self:set_report(report, self.now(), false)
      self:save_cache()
    else
      self.error, self.warning, self.warnings = err or "Review queue unavailable", nil, nil
    end
    self.changed()
  end)
  if self.loading then self.cancel = cancel end
  return true
end

function View:dispose()
  self.disposed = true
  if self.issues then self.issues:dispose() end
  self.generation = (self.generation or 0) + 1
  if self.cancel then self.cancel() end
  self.cancel, self.loading = nil, false
end

function View:tabs(available_width)
  local limit = available_width or 124
  local labels = limit < 54 and { "M", "R", "N", "D" }
    or limit < 80 and { "Mine", "Reviews", "Notes", "Remind" } or { "My tickets", "Reviews for me", "Notes", "Reminders" }
  if self.issues and limit >= 80 then labels[1] = "My issues" end
  local by_view = {}
  for i, name in ipairs(ORDER) do by_view[name] = labels[i] end
  local function chunk(value, active)
    return { value, hl = "Deskboard" .. (active and "Accent" or "Muted") }
  end
  local parts = {}
  for i, name in ipairs(self.order) do
    local label = by_view[name]
    if limit >= 80 and name == "reviews" and self.fetched_at then
      label = label .. " · " .. #self:review_rows() .. (self.author and ("/" .. #self.rows) or "")
    end
    if i > 1 then parts[#parts + 1] = chunk(limit < 24 and " " or " · ", false) end
    parts[#parts + 1] = chunk(self.active == name and ("[ " .. label .. " ]") or label, self.active == name)
  end
  if limit >= 24 then parts[#parts + 1] = chunk("  ⇄ Tab", false) end
  return { text = parts, align = "center", padding = { 0, 1 } }
end

local default
local instances = {}
function M.release(buf)
  if instances[buf] then instances[buf]:dispose(); instances[buf] = nil end
end
function M.dispose()
  for buf in pairs(instances) do M.release(buf) end
  if default then default:dispose(); default = nil end
end
function M.get(opts)
  opts = opts or {}
  if opts.buf then
    if not instances[opts.buf] then instances[opts.buf] = M.new(opts) end
    return instances[opts.buf]
  end
  if not default then
    opts.page_size = opts.page_size or require("deskboard.config").get().page_size
    default = M.new(opts)
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("deskboard_default_views", { clear = true }),
      callback = function() if default then default:dispose() end end,
    })
  end
  return default
end

return M

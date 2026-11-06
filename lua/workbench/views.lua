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

function M.fetch(opts, done)
  local script = opts.script or vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h") .. "/scripts/sprint-sync.py"
  if not opts.host or not opts.project then done(nil, "Configure the GitLab provider first"); return function() end end
  local command = { "python3", script, "--reviews", "--host", opts.host, "--project", opts.project, "--proxy", opts.proxy or "" }
  if opts.token_command then vim.list_extend(command, { "--token-command", vim.json.encode(opts.token_command) }) end
  local cancelled = false
  local function receive(result)
    if cancelled then return end
    local ok, report = pcall(vim.json.decode, result.stdout or "")
    if result.code == 0 and ok and type(report) == "table" and report.version == 1 and report.ok == true
      and type(report.user) == "table" and type(report.user.username) == "string"
      and type(report.rows) == "table" and vim.islist(report.rows) then
      for _, row in ipairs(report.rows) do
        if type(row) ~= "table" or type(row.iid) ~= "number" or row.iid < 1
          or type(row.title) ~= "string" or type(row.author) ~= "string"
          or type(row.project) ~= "string" or type(row.web_url) ~= "string" or type(row.target_branch) ~= "string"
          or (not unknown(row.commits) and not count(row.commits))
          or (not unknown(row.approved) and not count(row.approved))
          or (not unknown(row.my_approved) and type(row.my_approved) ~= "boolean")
          or (not unknown(row.other_approvals) and not count(row.other_approvals))
          or (not unknown(row.ci) and type(row.ci) ~= "string")
          or not threads(row.threads) or not threads(row.my_threads) then
          done(nil, "GitLab returned invalid review assignments")
          return
        end
      end
      done(report)
    else
      -- Never surface raw CLI output, exception text, tokens, or descriptions.
      local warning = ok and type(report) == "table" and type(report.warnings) == "table" and report.warnings[1]
      done(nil, type(warning) == "string" and warning or result.code == 124 and "Review queue request timed out"
        or "Review queue unavailable (GitLab authentication, CLI, or network)")
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
  return setmetatable({
    active = "mine", pages = { mine = 1, reviews = 1, notes = 1, reminders = 1 }, totals = { mine = 0, reviews = 0, notes = 0, reminders = 0 },
    selected = { mine = {}, reviews = {}, notes = {}, reminders = {} }, rows = {}, notes = {}, reminders = {}, note_filter = {},
    size = math.max(1, math.floor(tonumber(opts.page_size) or 6)),
    host = opts.host, project = opts.project, proxy = opts.proxy, token_command = opts.token_command,
    remote_enabled = opts.fetch ~= nil or opts.enabled == true,
    fetch = opts.fetch or M.fetch, now = opts.now or os.time,
    changed = opts.changed or redraw,
  }, View)
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

function View:switch(view)
  if not self.pages[view] then return end
  if self.active ~= view then self.previous, self.active = self.active, view end
  if self.remote_enabled and self.active == "reviews" and (not self.last_attempt or self.now() - self.last_attempt >= (self.error and 20 or 300)) and not self.loading then
    self:refresh()
  else
    self.changed()
  end
end

function View:toggle(delta)
  local index = 1
  for i, name in ipairs(ORDER) do if name == self.active then index = i; break end end
  self:switch(ORDER[(index - 1 + (delta or 1)) % #ORDER + 1])
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
  return require("workbench.notes").filter(self.notes, self.note_filter)
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

function View:refresh()
  if not self.remote_enabled then self.error = "GitLab provider is disabled"; self.changed(); return false end
  if self.loading then return false end
  self.loading, self.error, self.last_attempt = true, nil, self.now()
  self.generation = (self.generation or 0) + 1
  local generation = self.generation
  self.changed()
  local cancel = self.fetch(self, function(report, err)
    if self.generation ~= generation then return end
    self.loading, self.cancel = false, nil
    if report then
      self.rows, self.user, self.fetched_at, self.error = report.rows, report.user, self.now(), nil
      local warnings = {}
      for _, value in ipairs(type(report.warnings) == "table" and report.warnings or {}) do
        if type(value) == "string" then warnings[#warnings + 1] = value end
      end
      self.warnings = warnings
      self.warning = #warnings > 0 and table.concat(warnings, " · ") or nil
      self:set_total("reviews", #self:review_rows())
    else
      self.error, self.warning, self.warnings = err or "Review queue unavailable", nil, nil
    end
    self.changed()
  end)
  if self.loading then self.cancel = cancel end
  return true
end

function View:dispose()
  self.generation = (self.generation or 0) + 1
  if self.cancel then self.cancel() end
  self.cancel, self.loading = nil, false
end

function View:tabs(available_width)
  local limit = available_width or 124
  local labels = limit < 54 and { "M", "R", "N", "D" }
    or limit < 80 and { "Mine", "Reviews", "Notes", "Remind" } or { "My tickets", "Reviews for me", "Notes", "Reminders" }
  local function chunk(value, active)
    return { value, hl = "Workbench" .. (active and "Accent" or "Muted") }
  end
  local parts = {}
  for i, name in ipairs(ORDER) do
    local label = labels[i]
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
    opts.page_size = opts.page_size or require("workbench.config").get().page_size
    default = M.new(opts)
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("workbench_default_views", { clear = true }),
      callback = function() if default then default:dispose() end end,
    })
  end
  return default
end

return M

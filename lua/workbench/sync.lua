-- Shared startup/manual sync. The backend reports Jira/GitLab independently;
-- successful refreshes also require an atomic reminder-file write.
local M = {}
local Sync = {}
Sync.__index = Sync

local function stamp(path)
  local stat = vim.uv.fs_stat(path)
  return stat and { sec = stat.mtime.sec, nsec = stat.mtime.nsec, size = stat.size } or nil
end

local function age_label(seconds)
  seconds = math.max(0, seconds)
  if seconds < 60 then
    return "just now"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m ago"
  elseif seconds < 86400 then
    local hours, minutes = math.floor(seconds / 3600), math.floor(seconds / 60) % 60
    return hours .. "h" .. (minutes > 0 and (" " .. minutes .. "m") or "") .. " ago"
  end
  local days, hours = math.floor(seconds / 86400), math.floor(seconds / 3600) % 24
  return days .. "d" .. (hours > 0 and (" " .. hours .. "h") or "") .. " ago"
end

local function notice(opts)
  local info = require("workbench.status").format(opts)
  return (info.text:gsub(" · ! details$", " · Dashboard ! details"))
end

local function update_dashboard()
  pcall(function() require("workbench").redraw() end)
end

-- Separate instances keep tests isolated from the real reminder and state.
function M.new(opts)
  opts = opts or {}
  local cfg = require("workbench.config").get()
  local reminder = opts.reminder or cfg.providers.jira.snapshot or vim.fn.stdpath("state") .. "/workbench/snapshot.md"
  local command = opts.command or cfg.providers.jira.command or (opts.script and { opts.script })
  if not command then
    command = { "python3", require("workbench.config").root() .. "/scripts/sprint-sync.py", "--reminder", reminder,
      "--host", cfg.providers.gitlab.host, "--project", cfg.providers.gitlab.project or "", "--proxy", cfg.providers.gitlab.proxy or "" }
    if not cfg.providers.gitlab.enabled then command[#command + 1] = "--no-gitlab" end
    if cfg.providers.gitlab.token_command then vim.list_extend(command, { "--token-command", vim.json.encode(cfg.providers.gitlab.token_command) }) end
  end
  local self = setmetatable({
    script = opts.script or command[1], command = command,
    reminder = reminder,
    state_file = opts.state_file or cfg.providers.jira.state_file or vim.fn.stdpath("state") .. "/workbench/sync.json",
    run = opts.run or vim.system,
    now = opts.now or os.time,
    changed = opts.changed or update_dashboard,
    running = false,
  }, Sync)
  -- Older installs have no sync-state file. Use the existing reminder's
  -- timestamp as an approximate baseline, frozen until an actual refresh.
  local existing = stamp(self.reminder)
  self.cached_at = existing and existing.sec or nil
  local ok, saved = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(self.state_file), "\n"))
  end)
  if
    ok
    and type(saved) == "table"
    and saved.reminder == self.reminder
    and type(saved.last_success) == "number"
    and saved.last_success > 0
  then
    self.last_success = saved.last_success
    self.sources = type(saved.sources) == "table" and saved.sources or nil
  end
  return self
end

function Sync:status()
  local last = self.last_success or self.cached_at
  local age = last and math.max(0, self.now() - last)
  local estimated = not self.last_success and self.cached_at ~= nil
  local label = "Last refresh: " .. (age and ((estimated and "~" or "") .. age_label(age)) or "never")
  local partial = self.sources
      and (self.sources.jira == false and "Jira stale" or self.sources.gitlab == false and "GitLab stale")
    or nil
  return {
    text = label
      .. (partial and (" · " .. partial) or "")
      .. (self.running and " · refreshing…" or " · R refresh"),
    hl = self.running and "Accent" or (partial or self.last_error or not age or age >= 900) and "Warning" or "Muted",
    sources = self.sources,
    running = self.running,
    stale = age ~= nil and age >= 900,
    estimated = estimated,
    age = age,
    warnings = self.warnings,
    error = self.last_error, -- Available for diagnostics, without crowding the card.
  }
end

function Sync:refresh(opts)
  opts = opts or {}
  if self.running then
    if opts.queue then
      self.queued = true
    end
    if not opts.silent then
      vim.notify("Sprint refresh already in progress", vim.log.levels.INFO)
    end
    return false
  end
  self.last_attempt = self.now()
  if vim.fn.executable(self.command[1]) ~= 1 then
    self.last_error = "Sync script is missing or not executable"
    self.changed()
    if not opts.silent then
      vim.notify(notice({ error = self.last_error }), vim.log.levels.WARN, { title = "Sprint board" })
    end
    return false
  end
  local before = stamp(self.reminder)
  self.running, self.last_error = true, nil
  self.changed()
  local function finish(result)
    if self.disposed then return end
    self.running, self.job = false, nil
    local after = stamp(self.reminder)
    local decoded, report = pcall(vim.json.decode, result.stdout or "")
    report = decoded and type(report) == "table" and report.version == 1 and report or nil
    if result.code == 0 and (not report or report.ok == true) and after and not vim.deep_equal(before, after) then
      self.last_success, self.last_error = self.now(), nil
      self.sources = report and type(report.sources) == "table" and report.sources or nil
      if self.sources and not require("workbench.config").get().providers.gitlab.enabled then self.sources.gitlab = nil end
      self.warnings = report and type(report.warnings) == "table" and report.warnings or {}
      -- Persist only metadata, never tokens or ticket contents. A write failure
      -- must not invalidate an otherwise successful Jira refresh.
      pcall(function()
        vim.fn.mkdir(vim.fs.dirname(self.state_file), "p")
        vim.fn.writefile({
          vim.json.encode({
            last_success = self.last_success,
            reminder = self.reminder,
            stamp = after,
            sources = self.sources,
          }),
        }, self.state_file)
      end)
      vim.api.nvim_exec_autocmds("User", { pattern = "SprintBoardRefreshPost", modeline = false })
      if not opts.silent then
        local warning = self.warnings[1]
        vim.notify(
          warning and notice({ warnings = self.warnings, stale = self.sources and (self.sources.jira == false or self.sources.gitlab == false) })
            or "✓ Sprint refreshed",
          warning and vim.log.levels.WARN or vim.log.levels.INFO,
          { title = "Sprint board" }
        )
      end
    else
      local warning = report and type(report.warnings) == "table" and report.warnings[1]
      self.last_error = type(warning) == "string" and warning
        or result.code == 124 and "Refresh timed out"
        or result.code ~= 0 and "Sync command failed"
        or "No new data received (offline, unavailable, or empty sprint)"
      if not opts.silent then
        vim.notify(notice({ error = self.last_error, cached = self.last_success ~= nil or self.cached_at ~= nil }),
          vim.log.levels.WARN, { title = "Sprint board" })
      end
    end
    self.changed()
    if self.queued then
      self.queued = false
      self:refresh({ silent = true })
    end
  end
  local ok, job = pcall(self.run, self.command, { text = true, timeout = 180000 }, vim.schedule_wrap(finish))
  if ok then
    self.job = job
  else
    finish({ code = -1 })
  end
  return ok
end

local default
local generation, startup_timer = 0, nil
local function instance()
  default = default or M.new()
  return default
end

function M.status()
  return instance():status()
end

function M.refresh(opts)
  if not require("workbench.config").get().providers.jira.enabled then return false end
  return instance():refresh(opts)
end

function M.dispose()
  generation = generation + 1
  if startup_timer and not startup_timer:is_closing() then startup_timer:stop(); startup_timer:close() end
  startup_timer = nil
  if default then
    default.disposed = true
    if default.job then pcall(function() default.job:kill(15) end) end
  end
  default = nil
  pcall(vim.api.nvim_del_augroup_by_name, "workbench_sync")
end

function M.setup()
  local cfg = require("workbench.config").get()
  if not cfg.providers.jira.enabled then return end
  generation = generation + 1
  local own_generation = generation
  local group = vim.api.nvim_create_augroup("workbench_sync", { clear = true })
  if cfg.compat_commands then vim.api.nvim_create_user_command("SprintBoardRefresh", function() M.refresh() end, { force = true }) end
  local function startup()
    if startup_timer and not startup_timer:is_closing() then startup_timer:stop(); startup_timer:close() end
    startup_timer = vim.defer_fn(function()
      startup_timer = nil
      if generation ~= own_generation then return end
      -- A manual R during startup should not immediately launch a second sync.
      if not instance().last_attempt then
        M.refresh({ silent = true })
      end
    end, 300)
  end
  if cfg.providers.jira.auto_refresh and vim.v.vim_did_enter == 1 then
    startup()
  elseif cfg.providers.jira.auto_refresh then
    vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = startup })
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    once = true,
    callback = function()
      if default and default.job then
        default.job:kill(15)
      end
    end,
  })
end

return M

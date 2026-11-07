-- On-demand, read-only Jira/GitLab details. No network work during rendering.
local M = {}
local markdown = require("deskboard.markdown")
local auth_cache = {}
local instances = {}
local Preview = {}
Preview.__index = Preview

local function object(value)
  return type(value) == "table" and value or {}
end

local function scalar(value, fallback)
  if type(value) == "string" or type(value) == "number" then
    return (tostring(value):gsub("[\r\n]", " "))
  end
  return fallback or "unknown"
end

-- Commands are argv arrays, never shell strings. Errors deliberately exclude
-- stdout/stderr: credential helpers and CLI errors can contain private data.
function M.fetch(opts, done)
  if opts.provider == "github" then
    if not require("deskboard.config").get().providers.github.enabled and not opts.run then
      done({ fetched_at = os.time(), errors = { "GitHub provider is disabled" } }); return function() end
    end
    return require("deskboard.github").preview(opts, done)
  end
  local run = opts.run or vim.system
  local jobs, data, pending, cancelled = {}, { errors = {} }, 1, false
  local function finished()
    pending = pending - 1
    if pending == 0 and not cancelled then
      data.fetched_at = (opts.now or os.time)()
      done(data)
    end
  end
  local function request(name, cmd, env, valid)
    pending = pending + 1
    local function receive(result)
      if cancelled then
        return
      end
      local ok, value = pcall(vim.json.decode, result.stdout or "")
      if result.code == 0 and ok and type(value) == "table" and valid(value) then
        data[name] = value
      else
        local detail = ((result.stderr or "") .. " " .. (result.stdout or "")):lower()
        local reason = result.code == 124 and "request timed out"
          or (detail:find("401", 1, true) or detail:find("login required", 1, true) or detail:find(
            "unauthorized",
            1,
            true
          )) and "authentication failed (HTTP 401)"
          or (detail:find("403", 1, true) or detail:find("forbidden", 1, true)) and "permission denied (HTTP 403)"
          or result.code == -1 and "CLI unavailable"
          or "unavailable (CLI, authentication, or network)"
        data[name .. "_error"] = name .. ": " .. reason
        data.errors[#data.errors + 1] = data[name .. "_error"]
      end
      finished()
    end
    local ok, job = pcall(run, cmd, { text = true, timeout = 15000, env = env }, vim.schedule_wrap(receive))
    if ok then
      jobs[#jobs + 1] = job
    else
      receive({ code = -1 })
    end
  end
  if opts.ticket and (require("deskboard.config").get().providers.jira.enabled or opts.run) then
    request("jira", { "jira", "issue", "view", opts.ticket, "--raw" }, nil, function(value)
      return type(value.fields) == "table" and value.key == opts.ticket
    end)
  end
  if opts.mr_iid and (require("deskboard.config").get().providers.gitlab.enabled or opts.run) then
    local function gitlab(token)
      if cancelled then
        return
      end
      local env = vim.tbl_extend("force", {}, opts.env or {})
      if token and token ~= "" then
        env.GITLAB_TOKEN = token
      end
      if opts.proxy then
        env.https_proxy = opts.proxy
      end
      local project = opts.project:gsub("([^%w%-%._~])", function(c)
        return ("%%%02X"):format(c:byte())
      end)
      local endpoint = ("projects/%s/merge_requests/%s"):format(project, opts.mr_iid)
      local function cmd(path)
        return { "glab", "api", "--hostname", opts.host, "-X", "GET", path }
      end
      request("mr", cmd(endpoint), env, function(value)
        return tonumber(value.iid) == tonumber(opts.mr_iid)
      end)
      request("approvals", cmd(endpoint .. "/approvals"), env, function(value)
        return type(value.approved_by) == "table" or type(value.approvals_left) == "number"
      end)
    end
    local token_cmd = opts.token_command
    local key = (opts.host or "") .. "\0" .. (opts.project or "") .. "\0"
      .. (type(token_cmd) == "table" and table.concat(token_cmd, "\0") or "")
    local saved = auth_cache[key]
    local now = (opts.now or os.time)()
    if vim.env.GITLAB_TOKEN or vim.env.GITLAB_ACCESS_TOKEN or vim.env.GLAB_TOKEN or object(opts.env).GITLAB_TOKEN then
      gitlab()
    elseif saved and now - saved.at < 300 then
      gitlab(saved.token)
    elseif type(token_cmd) == "table" and vim.fn.executable(token_cmd[1]) == 1 then
      pending = pending + 1
      local function receive(result)
        if cancelled then
          return
        end
        local token = result.code == 0 and vim.trim(result.stdout or "") or nil
        if token and token ~= "" then
          auth_cache[key] = { token = token, at = now }
        end
        gitlab(token) -- Fall back to glab's own configured authentication.
        finished()
      end
      local ok, job = pcall(run, token_cmd, { text = true, timeout = 5000 }, vim.schedule_wrap(receive))
      if ok then
        jobs[#jobs + 1] = job
      else
        receive({ code = -1 })
      end
    else
      gitlab()
    end
  end
  finished()
  return function()
    cancelled = true
    for _, job in ipairs(jobs) do
      pcall(function()
        job:kill(15)
      end)
    end
  end
end

function M.approved_count(approvals)
  if type(approvals) ~= "table" or type(approvals.approved_by) ~= "table" or not vim.islist(approvals.approved_by) then
    return nil
  end
  local seen, count = {}, 0
  for _, entry in ipairs(approvals.approved_by) do
    local user = type(entry) == "table" and entry.user
    if type(user) ~= "table" then
      return nil
    end
    local identity
    for _, key in ipairs({ "id", "username", "name" }) do
      if user[key] ~= nil and user[key] ~= vim.NIL then
        identity = key .. ":" .. tostring(user[key])
        break
      end
    end
    if not identity then
      return nil
    end
    if not seen[identity] then
      seen[identity], count = true, count + 1
    end
  end
  return count
end

-- Keep the same conservative checks as scripts/sprint-sync.py. GitLab's
-- detailed verdict includes project/rule checks; legacy merge_status does not.
function M.merge_readiness(detail, approvals)
  detail = object(detail)
  if detail.state == "merged" then
    return "merged"
  end
  if detail.state == "closed" then
    return "closed"
  end
  if detail.state ~= "opened" then
    return "unknown"
  end
  if detail.draft == true or detail.work_in_progress == true then
    return "draft"
  end
  if detail.has_conflicts == true then
    return "conflict"
  end
  if detail.blocking_discussions_resolved == false then
    return "threads"
  end
  if object(detail.user).can_merge == false then
    return "permissions"
  end
  local status = detail.detailed_merge_status
  local blockers = {
    not_approved = "approvals",
    discussions_not_resolved = "threads",
    ci_must_pass = "ci",
    ci_still_running = "ci",
    conflict = "conflict",
    need_rebase = "rebase",
    draft_status = "draft",
    requested_changes = "changes",
    merge_time = "scheduled",
  }
  if blockers[status] then
    return blockers[status]
  end
  if status == "checking" or status == "unchecked" or status == "preparing" or status == "approvals_syncing" then
    return "checking"
  end
  if status ~= "mergeable" then
    return type(status) == "string" and "blocked" or "unknown"
  end
  if type(approvals) ~= "table" then
    return "unknown"
  end
  local left = approvals.approvals_left
  local valid_left = type(left) == "number" and left >= 0
  if approvals.approved == false or (valid_left and left > 0) then
    return "approvals"
  end
  if approvals.approved == true or (valid_left and left == 0) then
    return "yes"
  end
  return "unknown"
end

function M.lines(data, opts)
  if opts.provider == "github" then return require("deskboard.github").lines(data, opts) end
  local jira, mr, approvals = object(data.jira), object(data.mr), object(data.approvals)
  local age = math.max(0, (opts.now or os.time)() - (data.fetched_at or 0))
  local lines = {
    opts.ticket and ("# Sprint Review · " .. opts.ticket) or ("# MR Review · !" .. opts.mr_iid),
    "",
    ("> Details fetched %s%s"):format(
      age < 60 and "just now" or (math.floor(age / 60) .. "m ago"),
      #data.errors > 0 and " · partial data" or ""
    ),
    "",
  }
  local function body(value, source)
    local text = markdown.to_markdown(value, source)
    if text:match("^%s*$") then
      lines[#lines + 1] = "No description available."
      return
    end
    vim.list_extend(lines, markdown.excerpt(text, 200))
  end
  if opts.ticket then
    local fields = object(jira.fields)
    local live_jira = type(data.jira) == "table"
    local status = scalar(object(fields.status).name, opts.jira_status or "Unavailable")
      .. (not live_jira and opts.jira_status and " (cached board value)" or "")
    local assignee = scalar(object(fields.assignee).displayName, live_jira and "Unassigned" or "Unavailable — Jira request failed")
    vim.list_extend(lines, {
      "## Ticket Details", "", "### " .. scalar(fields.summary, "Ticket details unavailable"), "",
      "- Ticket: " .. opts.ticket, "- Status: " .. status, "- Assignee: " .. assignee, "",
    })
    if data.jira_error then
      lines[#lines + 1] = "> " .. data.jira_error
      if data.jira_error:find("401", 1, true) then
        lines[#lines + 1] = "> Renew the Jira token in work/jira-api-token and update JIRA_API_TOKEN."
      end
      lines[#lines + 1] = ""
    end
    vim.list_extend(lines, { "### Description", "" })
    if live_jira then
      body(fields.description, "jira")
    else
      lines[#lines + 1] = "Description unavailable — the Jira request failed; no description was received."
    end
    vim.list_extend(lines, { "", "---", "" })
  end
  if not opts.mr_iid then
    lines[#lines + 1] = "## Merge Request Details"
    lines[#lines + 1] = "No related MR in the cached board. Press R on the board to refresh associations."
  else
    vim.list_extend(lines, {
      "## Merge Request Details · !" .. opts.mr_iid,
      "",
      scalar(mr.title, "MR details unavailable"),
      "",
      "- State: " .. scalar(mr.state) .. (mr.draft == true and " · Draft" or ""),
      "- Branch: " .. scalar(mr.source_branch) .. " → " .. scalar(mr.target_branch),
      "- Changed files: " .. scalar(mr.changes_count),
    })
    if opts.project then lines[#lines + 1] = "- Project: " .. scalar(opts.project) end
    local readiness = M.merge_readiness(mr, data.approvals)
    local ready_text = {
      yes = "yes",
      merged = "already merged",
      closed = "no (closed)",
      draft = "no (draft)",
      approvals = "no (approval rules not satisfied)",
      threads = "no (blocking discussions)",
      ci = "no (pipeline checks)",
      conflict = "no (conflicts)",
      rebase = "no (rebase required)",
      changes = "no (changes requested)",
      scheduled = "no (scheduled merge time)",
      checking = "checking",
      blocked = "no (GitLab merge checks)",
      permissions = "no (merge permission)",
      unknown = "unknown (GitLab checks unavailable)",
    }
    lines[#lines + 1] = "- Ready to merge: " .. (ready_text[readiness] or "unknown")
    if mr.state == "merged" then
      lines[#lines + 1] = "- Merged into: " .. scalar(mr.target_branch)
      lines[#lines + 1] = "- Merged at: " .. scalar(mr.merged_at)
    else
      lines[#lines + 1] = "- Merged into: " .. (type(data.mr) == "table" and "not merged" or "unavailable")
    end
    local pipeline = object(mr.head_pipeline)
    lines[#lines + 1] = "- Pipeline: "
      .. scalar(pipeline.status, "unavailable")
      .. (pipeline.id and (" (#" .. scalar(pipeline.id) .. ")") or "")
    if data.approvals then
      lines[#lines + 1] = "- Approvals received: " .. scalar(M.approved_count(data.approvals), "unavailable")
      local names = {}
      for _, entry in ipairs(object(approvals.approved_by)) do
        local user = object(object(entry).user)
        names[#names + 1] = scalar(user.name, scalar(user.username))
      end
      lines[#lines + 1] = "- Approved by: " .. (#names > 0 and table.concat(names, ", ") or "none")
      lines[#lines + 1] = "- Approvals still required: " .. scalar(approvals.approvals_left)
    else
      lines[#lines + 1] = "- Approvals: unavailable (not assumed approved)"
    end
    if opts.review_metrics then
      local function ratio(value)
        value = object(value)
        if type(value.resolved) ~= "number" or type(value.total) ~= "number" then return "unavailable" end
        return value.resolved .. "/" .. value.total
      end
      lines[#lines + 1] = "- Threads (resolved/total, queue snapshot): " .. ratio(opts.review_metrics.threads)
      lines[#lines + 1] = "- My threads started by me (resolved/total, queue snapshot): " .. ratio(opts.review_metrics.my_threads)
      local metrics = opts.review_metrics
      if metrics.my_approved ~= nil or metrics.other_approvals ~= nil then
        local mine = metrics.my_approved == true and "yes" or metrics.my_approved == false and "no" or "unknown"
        lines[#lines + 1] = "- My approval (queue snapshot): " .. mine .. " · other approvers: " .. scalar(metrics.other_approvals, "unknown")
      end
    end
    vim.list_extend(lines, { "", "### Description", "" })
    body(mr.description, "markdown")
  end
  if #data.errors > 0 then
    vim.list_extend(lines, { "", "## Data availability", "" })
    for _, err in ipairs(data.errors) do
      lines[#lines + 1] = "- " .. err
    end
  end
  vim.list_extend(lines, { "", "---", "q / Esc close · j/k scroll" })
  return lines
end

function Preview:is_open()
  return self.win and vim.api.nvim_win_is_valid(self.win)
end

function Preview:new_buffer(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, ("sprint-preview://%d/%d"):format(self.dashboard.buf, buf))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  for _, key in ipairs({ "q", "<Esc>", "P" }) do
    vim.keymap.set({ "n", "t" }, key, function()
      self:close()
    end, { buffer = buf, nowait = true, desc = "Close sprint preview" })
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function(event)
      -- Glow replaces display buffers. Only closing the current one should
      -- cancel requests/close the popup; old terminal scrollback is discarded.
      if self.buf ~= event.buf then
        return
      end
      self:stop_requests()
      vim.schedule(function()
        if self.buf == event.buf then
          self:close()
        end
      end)
    end,
  })
  return buf
end

function Preview:plain(lines)
  if not self:is_open() then
    return
  end
  if vim.bo[self.buf].buftype == "terminal" then
    self.buf = self:new_buffer("markdown")
    vim.api.nvim_win_set_buf(self.win, self.buf)
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
end

function Preview:stop_render()
  self.render_sequence = (self.render_sequence or 0) + 1
  if self.render_job then
    pcall(function()
      self.render_job:kill(15)
    end)
    self.render_job = nil
  end
end

function M.glow_style(opts)
  local custom = (opts or {}).glow_style or require("deskboard.config").get().preview.glow_style
    or (require("deskboard.config").get().notes.legacy_globals and vim.g.sprint_preview_glow_style)
  if type(custom) == "string" and custom ~= "" then
    return vim.fn.expand(custom)
  end
  local theme = require("deskboard.config").root() .. "/styles/sprint-preview-" .. vim.o.background .. ".json"
  return vim.fn.filereadable(theme) == 1 and theme or vim.o.background
end

function Preview:write(lines)
  if not self:is_open() or not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
    return
  end
  self:stop_render()
  local sequence = self.render_sequence
  -- Immediate, readable content while Glow runs, and a fallback if it is
  -- missing/fails. No temporary Markdown files or interactive pager needed.
  self:plain(lines)
  local glow = self.opts.glow
  if glow == nil then
    glow = "glow"
  end
  if not glow or vim.fn.executable(glow) ~= 1 then
    return
  end
  local function receive(result)
    if self.render_sequence ~= sequence or not self:is_open() then
      return
    end
    self.render_job = nil
    if result.code ~= 0 or not result.stdout or result.stdout == "" then
      return
    end
    -- A new internal terminal for each render prevents previous details from
    -- lingering in scrollback. This terminal never runs a shell or a pager.
    self.buf = self:new_buffer("glowpreview")
    vim.api.nvim_win_set_buf(self.win, self.buf)
    local channel = vim.api.nvim_open_term(self.buf, { force_crlf = true })
    vim.api.nvim_chan_send(channel, result.stdout)
    vim.bo[self.buf].modifiable = false
    vim.api.nvim_win_set_cursor(self.win, { 1, 0 })
    vim.api.nvim_win_call(self.win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
    end)
  end
  local run = self.opts.render_run or vim.system
  local cmd = {
    glow,
    "--style",
    M.glow_style(self.opts),
    "--width",
    tostring(math.max(10, vim.api.nvim_win_get_width(self.win) - 4)),
    "-",
  }
  local ok, job = pcall(run, cmd, {
    text = true,
    timeout = 5000,
    stdin = table.concat(lines, "\n"):gsub("[%z\1-\8\11\12\14-\31\127]", ""),
  }, vim.schedule_wrap(receive))
  if ok then
    self.render_job = job
  end
end

function Preview:stop_requests()
  self:stop_render()
  self.sequence = self.sequence + 1
  if self.cancel then
    self.cancel()
    self.cancel = nil
  end
end

function Preview:close()
  self:stop_requests()
  local win, buf = self.win, self.buf
  self.win, self.buf, self.current, self.loading = nil, nil, nil, nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

function Preview:update(item, force)
  if not self:is_open() or not item or not (item.ticket or item.mr_iid or item.issue_number) then
    return
  end
  local previous_metrics = self.item and self.item.review_metrics
  self.item = { ticket = item.ticket, mr_iid = item.mr_iid, issue_number = item.issue_number, provider = item.provider or self.opts.provider,
    jira_status = item.jira_status, project = item.mr_project or item.project or self.opts.project, review_metrics = item.review_metrics }
  local key = (self.item.provider or "jira-gitlab") .. ":" .. (self.opts.host or "") .. ":" .. (item.ticket or (item.issue_number and "issue" or "mr"))
    .. ":" .. (self.item.project or "") .. ":" .. (item.issue_number or item.mr_iid or "")
  local saved = self.cache[key]
  local fresh = saved and os.time() - saved.fetched_at < (#saved.errors == 0 and 300 or 20)
  if not force and self.current == key and (self.loading or fresh) then
    if fresh and not self.loading and not vim.deep_equal(previous_metrics, self.item.review_metrics) then
      self:write(M.lines(saved, self.item))
    end
    return
  end
  self.sequence = self.sequence + 1
  local sequence, changed = self.sequence, self.current ~= key
  self.current, self.loading = key, true
  if self.cancel then
    self.cancel()
    self.cancel = nil
  end
  if saved then
    local lines = M.lines(saved, self.item)
    table.insert(lines, 3, "> Cached preview" .. (fresh and "" or " · refreshing…"))
    self:write(lines)
  else
    self:write({ "# " .. (item.ticket or ((self.item.provider == "github" and "#" or "!") .. (item.issue_number or item.mr_iid))), "", "Loading details…", "", "q / Esc close" })
  end
  if changed then
    vim.api.nvim_win_set_cursor(self.win, { 1, 0 })
  end
  if fresh and not force then
    self.loading = false
    return
  end
  vim.defer_fn(function()
    if self.sequence ~= sequence or not self:is_open() then
      return
    end
    local request = vim.tbl_extend("force", {}, self.opts, self.item)
    self.cancel = M.fetch(request, function(data)
      if self.sequence ~= sequence or not self:is_open() then
        return
      end
      self.loading, self.cancel = false, nil
      self.cache[key] = data
      self:write(M.lines(data, self.item))
    end)
  end, 150)
end

function Preview:open_window()
  local dashboard = self.dashboard
  if not (dashboard.win and vim.api.nvim_win_is_valid(dashboard.win)) then
    return false
  end
  if not self:is_open() then
    self.buf = self:new_buffer("markdown")
    local w, h = math.max(1, math.min(120, vim.o.columns - 4)), math.max(1, math.min(36, vim.o.lines - 6))
    self.win = vim.api.nvim_open_win(self.buf, true, {
      relative = "editor",
      width = w,
      height = h,
      row = math.max(0, math.floor((vim.o.lines - h - 2) / 2)),
      col = math.max(0, math.floor((vim.o.columns - w) / 2)),
      border = "rounded",
      style = "minimal",
      title = self.opts.title or " Sprint preview · q close ",
      title_pos = "center",
    })
    for option, value in pairs({
      wrap = true,
      linebreak = true,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      spell = false,
      winfixwidth = true,
    }) do
      vim.wo[self.win][option] = value
    end
  end
  vim.api.nvim_set_current_win(self.win)
  return true
end

function Preview:show(item)
  if not item or not (item.ticket or item.mr_iid or item.issue_number) then
    vim.notify("Select an issue, ticket or review first", vim.log.levels.INFO)
    return
  end
  if self:open_window() then
    self:update(item)
  end
end

-- A standalone read-only renderer for local drafts. No API loader, cache,
-- dashboard selection-following, or refresh hooks are attached to this popup.
function M.popup(owner, lines, opts)
  local self = setmetatable({ dashboard = owner, opts = opts or {}, cache = {}, sequence = 0 }, Preview)
  if not self:open_window() then
    return nil
  end
  self:write(lines)
  return self
end

function Preview:toggle(item)
  if self:is_open() then
    self:close()
  else
    self:show(item)
  end
end

function Preview:invalidate()
  self.cache = {}
  if self:is_open() then
    self:update(self.item, true)
  end
end

function M.attach(dashboard, opts)
  local old = instances[dashboard.buf]
  if old and old.dashboard.win == dashboard.win then
    old.dashboard, old.opts = dashboard, vim.tbl_extend("force", old.opts or {}, opts or {})
    return old
  end
  if old then
    old:close()
  end
  local self = setmetatable({ dashboard = dashboard, opts = opts, cache = {}, sequence = 0 }, Preview)
  instances[dashboard.buf] = self
  local group = vim.api.nvim_create_augroup("deskboard_preview_" .. dashboard.buf, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "SprintBoardRefreshPost",
    callback = function()
      self:invalidate()
    end,
  })
  vim.api.nvim_create_autocmd("BufHidden", {
    group = group,
    buffer = dashboard.buf,
    callback = function()
      self:stop_requests()
      vim.schedule(function()
        self:close()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = dashboard.buf,
    once = true,
    callback = function()
      self:stop_requests()
      vim.schedule(function()
        self:close()
      end)
      instances[dashboard.buf] = nil
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
  return self
end

function M.dispose()
  for buf, instance in pairs(instances) do
    instance:close()
    pcall(vim.api.nvim_del_augroup_by_name, "deskboard_preview_" .. buf)
  end
  instances, auth_cache = {}, {}
end
return M

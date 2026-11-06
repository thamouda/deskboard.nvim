-- Jira drafts are original wiki text, never the Markdown/ANSI shown by Glow.
-- Only an explicit, confirmed publish can invoke `jira issue edit`.
local M = {}
local Editor = {}
Editor.__index = Editor
local editors = {}
local ns = vim.api.nvim_create_namespace("sprint_jira_draft_title")
local PUBLISH = "Publish to Jira"

local function notify(text, level)
  vim.notify(text, level or vim.log.levels.INFO, { title = "Jira draft" })
end

local function failure(result)
  local text = ((result.stderr or "") .. " " .. (result.stdout or "")):lower()
  if text:find("401", 1, true) or text:find("login required", 1, true) or text:find("unauthorized", 1, true) then
    return "Jira authentication failed (HTTP 401); check JIRA_API_TOKEN"
  elseif text:find("403", 1, true) or text:find("forbidden", 1, true) then
    return "Jira permission denied (HTTP 403)"
  elseif result.code == 124 then
    return "Jira request timed out"
  elseif result.code == -1 then
    return "Jira CLI could not start"
  end
  return "Jira request failed"
end

local function fields(value, key)
  if type(value) ~= "table" or value.key ~= key or type(value.fields) ~= "table" then
    return nil, "Invalid Jira response; no editable draft loaded"
  end
  local f = value.fields
  if type(f.summary) ~= "string" then
    return nil, "Jira response has no title"
  end
  if f.description ~= nil and f.description ~= vim.NIL and type(f.description) ~= "string" then
    return nil, "ADF/rich-text descriptions are not editable here; use Jira in the browser"
  end
  return { summary = f.summary, description = type(f.description) == "string" and f.description or "" }
end

local function draft_lines(value)
  local lines = { value.summary, "" }
  vim.list_extend(lines, vim.split(value.description, "\n", { plain = true }))
  return lines
end

function M.parse(lines)
  if type(lines[1]) ~= "string" or vim.trim(lines[1]) == "" then
    return nil, "Line 1 must contain the ticket title"
  end
  if lines[1]:find("[%z\1-\31\127]") or vim.fn.strchars(lines[1]) > 255 then
    return nil, "Title must be one line, at most 255 characters, without control characters"
  end
  if type(lines[2]) ~= "string" or not lines[2]:match("^%s*$") then
    return nil, "Keep line 2 blank; the original Jira description starts on line 3"
  end
  local body = table.concat(lines, "\n", 3)
  if body:find("%z") then
    return nil, "Description contains a NUL character"
  end
  return { summary = lines[1], description = body }
end

function Editor:valid()
  return self.buf and vim.api.nvim_buf_is_valid(self.buf)
end

function Editor:busy()
  return self.phase == "confirming"
    or self.phase == "checking"
    or self.phase == "publishing"
    or self.phase == "verifying"
end

function Editor:request(cmd, opts, done)
  local ok, job = pcall(
    self.opts.run or vim.system,
    cmd,
    vim.tbl_extend("force", { text = true, timeout = 15000 }, opts or {}),
    vim.schedule_wrap(done)
  )
  if ok then
    self.job = job
  else
    vim.schedule(function()
      done({ code = -1 })
    end)
  end
end

function Editor:get(done)
  self:request({ "jira", "issue", "view", self.ticket, "--raw" }, {}, function(result)
    self.job = nil
    if result.code ~= 0 then
      done(nil, failure(result))
      return
    end
    local ok, value = pcall(vim.json.decode, result.stdout or "")
    if not ok then
      done(nil, "Invalid JSON from Jira; draft retained")
      return
    end
    local parsed, err = fields(value, self.ticket)
    done(parsed, err, value)
  end)
end

function Editor:highlight()
  if not self:valid() then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(self.buf, ns, 0, 0, { end_row = 1, hl_group = "Title", hl_eol = true })
end

function Editor:replace(lines, modified)
  if not self:valid() then
    return
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modified = modified or false
  self:highlight()
end

-- Only explicit local saves/closing/publishing write drafts. No token, CLI
-- output, or Glow rendering is persisted. Private directory + atomic 0600 file.
function Editor:save(silent)
  if not self.base or not self:valid() then
    return false
  end
  local current = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local parsed = M.parse(current)
  if parsed and parsed.summary == self.base.summary and parsed.description == self.base.description then
    pcall(vim.uv.fs_unlink, self.path)
    vim.bo[self.buf].modified = false
    if not silent then
      notify("No local changes; nothing was published")
    end
    return true
  end
  local path = self.path
  local temp = self.dir .. "/." .. self.ticket .. "." .. tostring(vim.uv.hrtime()) .. ".tmp"
  local ok = pcall(function()
    vim.fn.mkdir(self.dir, "p", 448)
    assert(vim.uv.fs_chmod(self.dir, 448))
    local value = { version = 1, ticket = self.ticket, base = self.base, lines = current }
    assert(vim.fn.writefile({ vim.json.encode(value) }, temp) == 0)
    assert(vim.uv.fs_chmod(temp, 384))
    assert(vim.uv.fs_rename(temp, path))
  end)
  if not ok then
    pcall(vim.uv.fs_unlink, temp)
    notify("Could not save private draft; keep this buffer open", vim.log.levels.ERROR)
    return false
  end
  vim.bo[self.buf].modified = false
  if not silent then
    notify("Draft saved locally, not published: " .. path)
  end
  return true
end

function Editor:saved()
  local ok, value = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(self.path), "\n"))
  end)
  if
    not ok
    or type(value) ~= "table"
    or value.version ~= 1
    or value.ticket ~= self.ticket
    or type(value.base) ~= "table"
    or type(value.base.summary) ~= "string"
    or type(value.base.description) ~= "string"
    or type(value.lines) ~= "table"
    or not vim.islist(value.lines)
  then
    return nil
  end
  for _, line in ipairs(value.lines) do
    if type(line) ~= "string" then
      return nil
    end
  end
  if #value.lines < 2 then
    return nil
  end
  return value
end

function Editor:window()
  if not self:valid() then
    return false
  end
  if not (self.win and vim.api.nvim_win_is_valid(self.win)) then
    local w, h = math.max(1, math.min(120, vim.o.columns - 4)), math.max(1, math.min(36, vim.o.lines - 6))
    self.win = vim.api.nvim_open_win(self.buf, true, {
      relative = "editor",
      width = w,
      height = h,
      row = math.max(0, math.floor((vim.o.lines - h - 2) / 2)),
      col = math.max(0, math.floor((vim.o.columns - w) / 2)),
      style = "minimal",
      border = "rounded",
      title = " Jira draft · " .. self.ticket .. " ",
      title_pos = "center",
      footer = " :w local · <leader>jp preview · Ctrl-s publish · q close ",
      footer_pos = "center",
    })
    for key, value in pairs({
      wrap = true,
      linebreak = true,
      number = true,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      spell = false,
    }) do
      vim.wo[self.win][key] = value
    end
  end
  vim.api.nvim_set_current_win(self.win)
  return true
end

function Editor:install()
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(self.buf, "jira-draft://" .. self.ticket)
  vim.bo[self.buf].buftype = "acwrite"
  vim.bo[self.buf].bufhidden = "hide"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].undofile = false
  vim.bo[self.buf].filetype = "jira"
  local commands = {
    JiraPublish = function()
      self:publish()
    end,
    JiraDraftPreview = function()
      self:preview()
    end,
    JiraDraftClose = function()
      self:close()
    end,
  }
  for name, callback in pairs(commands) do
    vim.api.nvim_buf_create_user_command(self.buf, name, callback, { desc = name })
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    self:publish()
  end, { buffer = self.buf, desc = "Confirm and publish Jira draft" })
  vim.keymap.set("n", "<leader>js", function()
    self:publish()
  end, { buffer = self.buf, desc = "Publish Jira draft" })
  vim.keymap.set("n", "<leader>jp", function()
    self:preview()
  end, { buffer = self.buf, desc = "Preview Jira draft" })
  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = self.buf, nowait = true, desc = "Keep draft and close" })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = self.buf,
    callback = function()
      self:save()
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    buffer = self.buf,
    callback = function()
      if self.base then
        self:save(true)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = self.buf,
    callback = function()
      self:highlight()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = self.buf,
    once = true,
    callback = function()
      self.buf, self.win = nil, nil
      if self.popup then
        local popup = self.popup
        self.popup = nil
        popup:stop_requests()
        vim.schedule(function()
          popup:close()
        end)
      end
      if self.phase ~= "publishing" and self.phase ~= "verifying" then
        self.sequence = self.sequence + 1
        if self.job then
          pcall(function()
            self.job:kill(15)
          end)
        end
        if editors[self.ticket] == self then
          editors[self.ticket] = nil
        end
      end
    end,
  })
end

function Editor:load()
  self.phase = "loading"
  self.sequence = self.sequence + 1
  local sequence = self.sequence
  self:replace({ "Loading " .. self.ticket .. "…", "", "No update will be sent until JiraPublish is confirmed." })
  vim.bo[self.buf].modifiable = false
  self:get(function(remote, err, record)
    if self.sequence ~= sequence or not self:valid() then
      return
    end
    if not remote then
      self.phase = "error"
      self:replace({ "Could not load " .. self.ticket, "", err, "", "q closes; E on the board retries." })
      vim.bo[self.buf].modifiable = false
      notify(err, vim.log.levels.WARN)
      return
    end
    self.record = record
    local function use(base, lines)
      if self.sequence ~= sequence or not self:valid() then
        return
      end
      self.base, self.phase = base, "ready"
      self:replace(lines)
      if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_set_cursor(self.win, { 1, 0 })
      end
      notify("Line 1: title · blank line 2 · line 3 onward: original Jira wiki description. :w is local only.")
    end
    local saved = self:saved()
    if not saved then
      use(remote, draft_lines(remote))
      return
    end
    self.phase = "resuming"
    local choose = self.opts.select or vim.ui.select
    choose({ "Resume local draft", "Discard saved draft; load Jira", "Cancel" }, {
      prompt = "Saved draft for " .. self.ticket .. " (nothing is published automatically)",
    }, function(choice)
      if self.sequence ~= sequence or not self:valid() then
        return
      end
      if choice == "Resume local draft" then
        use(saved.base, saved.lines)
      elseif choice == "Discard saved draft; load Jira" then
        pcall(vim.uv.fs_unlink, self.path)
        use(remote, draft_lines(remote))
      else
        self:close()
      end
    end)
  end)
end

function Editor:preview()
  if self.phase ~= "ready" or not self:valid() then
    notify("Wait for the draft to load")
    return
  end
  local value, err = M.parse(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false))
  if not value then
    notify(err, vim.log.levels.WARN)
    return
  end
  local md = require("deskboard.markdown")
  local lines = {
    "# Draft · " .. self.ticket,
    "",
    "> NOT PUBLISHED — preview only. Close with q to return to the editor.",
    "",
    "## " .. value.summary,
    "",
    "### Description",
    "",
  }
  vim.list_extend(lines, md.excerpt(md.to_markdown(value.description, "jira"), 1000))
  if self.popup then
    self.popup:close()
  end
  local opts =
    vim.tbl_extend("force", { title = " Jira draft preview · NOT PUBLISHED " }, self.opts.preview_opts or {})
  self.popup = require("deskboard.preview").popup({ buf = self.buf, win = self.win }, lines, opts)
end

function Editor:failed(message)
  self.phase, self.job = "ready", nil
  if self:valid() then
    self:save(true)
  end
  notify(message .. "; local draft retained", vim.log.levels.WARN)
  if not self:valid() and editors[self.ticket] == self then
    editors[self.ticket] = nil
  end
end

function Editor:success(remote, record, tick, changed)
  self.phase, self.job, self.base, self.record = "ready", nil, remote, record
  if self:valid() and vim.api.nvim_buf_get_changedtick(self.buf) == tick then
    self:replace(draft_lines(remote))
    pcall(vim.uv.fs_unlink, self.path)
  elseif self:valid() then
    -- Keystrokes entered while publishing are a new local draft, not part of
    -- the confirmed snapshot. Preserve them against the newly verified base.
    self:save(true)
  else
    pcall(vim.uv.fs_unlink, self.path)
    if editors[self.ticket] == self then
      editors[self.ticket] = nil
    end
  end
  notify(changed and ("Updated " .. self.ticket .. " in Jira") or (self.ticket .. " is already up to date"))
  if self.opts.on_success then
    local ok = pcall(self.opts.on_success, self.ticket)
    if not ok then
      notify("Jira updated, but board refresh failed; press R", vim.log.levels.WARN)
    end
  end
end

function Editor:publish()
  if self:busy() then
    notify("A Jira publication is already in progress")
    return false
  end
  if self.phase ~= "ready" or not self.base or not self:valid() then
    notify("Load a valid Jira draft first")
    return false
  end
  local value, err = M.parse(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false))
  if not value then
    notify(err, vim.log.levels.WARN)
    return false
  end
  local changed =
    { summary = value.summary ~= self.base.summary, description = value.description ~= self.base.description }
  if not changed.summary and not changed.description then
    notify("No changes to publish")
    return false
  end
  if changed.description and vim.trim(value.description) == "" then
    notify(
      "Empty descriptions are not published by this editor. Clear the description explicitly in Jira if intended.",
      vim.log.levels.WARN
    )
    return false
  end
  if not self:save(true) then
    return false
  end
  local sequence, tick = self.sequence, vim.api.nvim_buf_get_changedtick(self.buf)
  self.phase = "confirming"
  local labels = {}
  if changed.summary then
    labels[#labels + 1] = "title"
  end
  if changed.description then
    labels[#labels + 1] = "full description (replaces the existing description)"
  end
  local choose = self.opts.select or vim.ui.select
  choose({ "Cancel", PUBLISH }, {
    prompt = "Publish " .. self.ticket .. " to Jira? Fields: " .. table.concat(labels, ", "),
  }, function(choice)
    if self.sequence ~= sequence or not self:valid() then
      return
    end
    if choice ~= PUBLISH then
      self.phase = "ready"
      return
    end
    if vim.api.nvim_buf_get_changedtick(self.buf) ~= tick then
      self:failed("Draft changed after confirmation; confirm it again")
      return
    end
    self.phase = "checking"
    self:get(function(remote, get_error, record)
      if self.sequence ~= sequence then
        return
      end
      if not remote then
        self:failed(get_error)
        return
      end
      if not self:valid() or vim.api.nvim_buf_get_changedtick(self.buf) ~= tick then
        self:failed("Draft changed or closed during the remote check; no update sent")
        return
      end
      local updates = {}
      for _, field in ipairs({ "summary", "description" }) do
        if changed[field] and remote[field] ~= value[field] then
          if remote[field] ~= self.base[field] then
            self:failed(
              "Conflict: "
                .. field
                .. " was edited in Jira since this draft was loaded. Reopen with E and compare your saved draft"
            )
            return
          end
          updates[field] = true
        end
      end
      if not updates.summary and not updates.description then
        self:success(remote, record, tick, false)
        return
      end
      local cmd = { "jira", "issue", "edit", self.ticket, "--no-input" }
      if updates.summary then
        vim.list_extend(cmd, { "--summary", value.summary })
      end
      local options = { timeout = 30000 }
      if updates.description then
        options.stdin = value.description
      end
      self.phase = "publishing"
      self:request(cmd, options, function(result)
        -- Never retry a mutation automatically, even on a timeout: Jira may
        -- already have accepted it. Read back the fields to establish outcome.
        self.phase, self.job = "verifying", nil
        self:get(function(verified, verify_error, verified_record)
          if verified then
            local matches = true
            for _, field in ipairs({ "summary", "description" }) do
              if changed[field] and verified[field] ~= value[field] then
                matches = false
              end
            end
            if matches then
              self:success(verified, verified_record, tick, true)
              return
            end
          end
          self:failed(
            (result.code == 0 and "Update sent, but read-back did not confirm it" or failure(result))
              .. (verify_error and (" · " .. verify_error) or "")
              .. ". Check Jira before retrying"
          )
        end)
      end)
    end)
  end)
  return true
end

function Editor:close()
  if self.phase == "publishing" or self.phase == "verifying" then
    notify("Publication has been sent; wait for its result before closing", vim.log.levels.WARN)
    return false
  end
  if self.base and self:valid() and not self:save(true) then
    return false
  end
  self.sequence = self.sequence + 1
  if self.job then
    pcall(function()
      self.job:kill(15)
    end)
    self.job = nil
  end
  if self.popup then
    self.popup:close()
    self.popup = nil
  end
  local win, buf = self.win, self.buf
  self.win = nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  self.buf = nil
  if editors[self.ticket] == self then
    editors[self.ticket] = nil
  end
  return true
end

function M.open(item, opts)
  if not require("deskboard.config").get().actions.jira_edit or not require("deskboard.config").get().providers.jira.enabled then notify("Jira editing is disabled", vim.log.levels.WARN); return nil end
  local key = type(item) == "table" and item.ticket
  if type(key) ~= "string" or not key:match("^%u[%u%d]*%-%d+$") then
    notify("Select a sprint ticket first", vim.log.levels.WARN)
    return nil
  end
  local existing = editors[key]
  if existing then
    if existing:valid() then
      existing:window()
      if existing.phase == "error" then
        existing:load()
      end
      return existing
    elseif existing:busy() then
      notify("Publication for " .. key .. " is still in progress")
      return existing
    end
  end
  opts = opts or {}
  local dir = opts.draft_dir or (vim.fn.stdpath("state") .. "/deskboard/jira-drafts")
  local self =
    setmetatable({ ticket = key, opts = opts, dir = dir, path = dir .. "/" .. key .. ".json", sequence = 0 }, Editor)
  editors[key] = self
  self:install()
  self:window()
  self:load()
  return self
end

return M

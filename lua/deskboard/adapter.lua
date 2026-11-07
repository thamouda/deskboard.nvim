local M = {}
local instances = {}

function M.sections(self)
  local cfg = require("deskboard.config").get()
  local github = cfg.providers.github.enabled
  local remote = github and cfg.providers.github or cfg.providers.gitlab
  local GITLAB_HOST, GITLAB_PROJECT, REPO = remote.host, remote.project, cfg.actions.repo
  -- Parse ~/.notes/reminder.md into: an optional sprint (name +
  -- date range, for the progress bar), a heading (free-text lines),
  -- and a todo list (markdown checkbox lines: `- [ ]` / `- [x]`).
  local ticket_todos, personal_notes, sprint = {}, {}, nil
  local reminder = cfg.reminders.path or cfg.providers.jira.snapshot
  local function read_snapshot(path, tickets, personal)
    local f = path and io.open(vim.fn.expand(path), "r") or nil
    if not f then return end
    local lnum = 0
    for line in f:lines() do
      lnum = lnum + 1
      line = line:match("^%s*(.-)%s*$")
      if line ~= "" then
        local name, start, stop = line:match("^SPRINT|(.-)|(.-)|(.-)$")
        local done, text = line:match("^%-%s*%[([ xX])%]%s*(.*)$")
        local ticket = text and text:match("^(%u[%u%d]*%-%d+)")
        if name then
          if tickets then sprint = { name = name, start = start, stop = stop } end
        elseif ticket then
          if tickets then ticket_todos[#ticket_todos + 1] = { ticket = ticket, text = text, done = done == "x" or done == "X" } end
        elseif personal and not line:match("^synced %d%d:%d%d$") then
          personal_notes[#personal_notes + 1] = { id = "reminder:" .. lnum, title = (text or line):gsub("^#+%s*", ""),
            path = path, lnum = lnum, done = done == "x" or done == "X" }
        end
      end
    end
    f:close()
  end
  if cfg.repo_config.enabled then
    if cfg.providers.jira.enabled then read_snapshot(cfg.providers.jira.snapshot, true, false) end
    read_snapshot(reminder, false, true)
  else read_snapshot(reminder, true, true) end
  if cfg.demo then ticket_todos, sprint, personal_notes = require("deskboard.demo").snapshot() end
  local board = require("deskboard.board")
  local sync = cfg.providers.jira.enabled and require("deskboard.sync") or { status = function() return {} end,
    refresh = function() vim.notify("Jira provider is disabled", vim.log.levels.INFO) end }
  local views = require("deskboard.views").get({ buf = self.buf, host = GITLAB_HOST, project = GITLAB_PROJECT,
    proxy = cfg.providers.gitlab.proxy, token_command = cfg.providers.gitlab.token_command,
    provider = github and "github" or "gitlab", enabled = remote.enabled, page_size = cfg.page_size, cache_file = remote.cache_file,
    local_only = cfg.repo_config.enabled and not cfg.demo and not cfg.repo_config_path,
    issues_config = github and { provider = "github", enabled = true, host = remote.host, project = remote.project, cache_file = remote.issues_cache_file } or nil,
    changed = function() if self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_buf(self.win) == self.buf
      and type(self.update) == "function" then self:update() else require("deskboard").redraw() end end })
  instances[self.buf] = self
  if cfg.demo then
    views.rows, views.user, views.fetched_at = require("deskboard.demo").reviews(), { username = "demo" }, os.time()
    views:set_total("reviews", #views.rows)
  end
  views:set_total("mine", views.issues and #views.issues.rows or #ticket_todos)
  views:set_reminders(personal_notes)
  local active = views.active
  if active == "mine" then views:ensure_mine() end
  local selected_attr = active == "reviews" and "_review_selected" or active == "notes" and "_note_selected" or active == "reminders" and "_reminder_selected" or "_sprint_selected"
  if active == "notes" then
    views:set_notes(cfg.demo and require("deskboard.demo").notes()
      or cfg.notes.enabled and require("deskboard.notes").list({ reminders = {} }) or {})
  end
  local preview = require("deskboard.preview").attach(self, {
    provider = github and "github" or "gitlab", host = GITLAB_HOST,
    project = GITLAB_PROJECT,
    proxy = cfg.providers.gitlab.proxy,
    token_command = cfg.providers.gitlab.token_command,
    glow = cfg.preview.glow,
    glow_style = cfg.preview.glow_style,
  })
  self._deskboard_preview = preview
  local function close_previews()
    preview:close()
    if self._note_popup then self._note_popup:close(); self._note_popup = nil end
    if self._status_popup then self._status_popup:close(); self._status_popup = nil end
  end
  local function selected_note()
    local item = self:find(vim.api.nvim_win_get_cursor(self.win))
    return item and item.note_data
  end
  local function note_details()
    local note = selected_note()
    if not note then return end
    close_previews()
    self._note_popup = require("deskboard.note_actions").details(note, self)
  end
  if not self._deskboard_lifecycle then
    self._deskboard_lifecycle = true
    self._deskboard_generation = (self._deskboard_generation or 0) + 1
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = self.buf, once = true,
      group = vim.api.nvim_create_augroup("deskboard_owner_" .. self.buf, { clear = true }),
      callback = function() close_previews(); require("deskboard.views").release(self.buf); instances[self.buf] = nil end })
  end
  board.setup_highlights()
  local branch = active == "mine" and not github and cfg.providers.jira.enabled and REPO and vim.fn.systemlist({ "git", "-C", REPO, "branch", "--show-current" }) or {}
  local current_ticket = vim.v.shell_error == 0
      and branch[1]
      and branch[1]:match("(%u[%u%d]*%-%d+)")
    or nil
  local board_width = math.min(cfg.width, vim.api.nvim_win_get_width(self.win))
  -- Snacks also needs the narrower pane width to center the card correctly.
  -- Recompute from the preferred width on each update so growing works too.
  if self.opts then
    self.opts.width = board_width
  end
  -- The shared date/time component belongs to each panel header.
  local sections = { views:tabs(board_width) }
  local frame = board.frame({ width = board_width, page_size = views.size })
  local board_items, _page_info, panel_status -- luacheck: ignore 231
  if active == "reviews" then
    board_items, _page_info, panel_status = board.render_reviews({ state = views, width = board_width, frame = frame, on_open = vim.ui.open })
  elseif active == "reminders" then
    board_items, _page_info, panel_status = board.render_reminders({ state = views, width = board_width, frame = frame, on_open = require("deskboard.notes").open })
  elseif active == "notes" then
    board_items, _page_info, panel_status = board.render_notes({ state = views, width = board_width, frame = frame, on_open = require("deskboard.notes").open })
  elseif views.issues then
    board_items, _page_info, panel_status = board.render_issues({ state = views, width = board_width, frame = frame, on_open = vim.ui.open })
  else
    local sync_status = sync.status()
    if cfg.repo_error then sync_status.error = cfg.repo_error end
    board_items, _page_info, panel_status = board.render({
      project = GITLAB_PROJECT,
      page = views.pages.mine,
      page_size = views.size,
      frame = frame,
      sprint = sprint,
      ticket_todos = ticket_todos,
      show_notes = false,
      current_ticket = current_ticket,
      width = board_width,
      sync = sync_status,
      on_checkout = function(ticket)
        if not cfg.actions.checkout then
          vim.notify("Checkout is disabled; enable actions.checkout explicitly", vim.log.levels.INFO); return
        end
        require("deskboard.checkout").checkout(ticket, {
          repo = REPO,
          on_success = function()
            Snacks.dashboard.update()
          end,
        })
      end,
    })
  end
  vim.list_extend(sections, board_items)
  self._panel_status = panel_status
  vim.keymap.set("n", "!", function()
    close_previews()
    self._status_popup = require("deskboard.status").show(self._panel_status, self)
  end, { buffer = self.buf, nowait = true, desc = "Show full panel status / warnings" })
  for lhs, delta in pairs({ ["<Tab>"] = 1, ["<S-Tab>"] = -1 }) do
    vim.keymap.set("n", lhs, function()
      close_previews()
      views:toggle(delta)
    end, { buffer = self.buf, nowait = true, desc = views.local_only and "Switch notes / reminders" or "Switch tickets / reviews / notes / reminders" })
  end
  vim.keymap.set("n", "a", function()
    if views.active ~= "reviews" then return end
    local authors = { { label = "All authors" } }
    for _, author in ipairs(views:authors()) do authors[#authors + 1] = { label = "@" .. author, author = author } end
    vim.ui.select(authors, { prompt = "Filter reviews by author", format_item = function(item) return item.label end }, function(choice)
      if choice and views.active == "reviews" then
        preview:close()
        views:set_author(choice.author)
      end
    end)
  end, { buffer = self.buf, nowait = true, desc = "Filter reviews by author" })
  vim.keymap.set("n", "A", function()
    if views.active == "reviews" then close_previews(); views:set_author(nil)
    elseif views.active == "notes" then close_previews(); views:clear_notes_filters() end
  end, { buffer = self.buf, nowait = true, desc = "Clear active board filters" })
  for lhs, key in pairs({ C = "category", S = "status", t = "tag", Q = "queue" }) do
    vim.keymap.set("n", lhs, function()
      if views.active ~= "notes" then return end
      local values = key == "status" and require("deskboard.note_metadata").statuses
        or key == "queue" and { "inbox", "review", "ready", "overdue" }
        or require("deskboard.notes").facets(views.notes, key)
      local options = { { label = "All", value = false } }
      local queue_labels = { inbox = "Inbox", review = "Needs review", ready = "Ready to publish (saved, reviewed, team)", overdue = "Overdue" }
      for _, value in ipairs(values) do
        options[#options + 1] = { label = key == "queue" and queue_labels[value] or value, value = value }
      end
      vim.ui.select(options, { prompt = "Notes: " .. key, format_item = function(item) return item.label end }, function(choice)
        if choice and views.active == "notes" then
          close_previews()
          views:set_notes_filter(key, choice.value or nil)
        end
      end)
    end, { buffer = self.buf, nowait = true, desc = "Notes: filter " .. key })
  end
  for lhs, method in pairs({ M = "status", v = "reviewed", V = "visibility", D = "delete", B = "browser" }) do
    vim.keymap.set("n", lhs, function()
      if views.active ~= "notes" then return end
      local note = selected_note()
      if note then close_previews(); require("deskboard.note_actions")[method](note) end
    end, { buffer = self.buf, nowait = true, desc = "Notes: " .. method })
  end
  vim.keymap.set("n", "+", function()
    if views.active == "notes" then close_previews(); require("deskboard.note_actions").new_prompt() end
  end, { buffer = self.buf, nowait = true, desc = "Notes: new structured draft" })
  vim.keymap.set("n", "F", function()
    if views.active == "notes" then close_previews(); require("deskboard.note_actions").search(views:note_rows()) end
  end, { buffer = self.buf, nowait = true, desc = "Notes: full-text search" })
  for lhs, delta in pairs({ ["[p"] = -1, ["]p"] = 1, ["<PageUp>"] = -1, ["<PageDown>"] = 1 }) do
    vim.keymap.set("n", lhs, function()
      close_previews()
      views:move(delta)
    end, { buffer = self.buf, nowait = true, desc = delta < 0 and "Previous board page" or "Next board page" })
  end
  if package.loaded["lazy"] then table.insert(sections, { section = "startup" }) end

  -- Classic dashboard shortcuts kept functional but not rendered.
  -- `hidden = true` tells Snacks to register the keymap without
  -- drawing the item in the buffer.
  local hidden_keys = {
    { key = "f", action = ":lua Snacks.dashboard.pick('files')" },
    { key = "n", action = ":ene | startinsert" },
    { key = "g", action = ":lua Snacks.dashboard.pick('live_grep')" },
    { key = "r", action = ":lua Snacks.dashboard.pick('oldfiles')" },
    { key = "c", action = ":lua Snacks.dashboard.pick('files', {cwd = vim.fn.stdpath('config')})" },
    { key = "s", section = "session" },
    { key = "L", action = ":Lazy" },
    { key = "X", action = ":LazyExtras" }, -- moved off `x`: see `o`/`x` below
    { key = "q", action = ":" .. cfg.quit },
  }
  if reminder then hidden_keys[#hidden_keys + 1] = { key = "e", action = ":edit " .. vim.fn.fnameescape(reminder) } end
  for _, k in ipairs(hidden_keys) do
    k.hidden = true
    table.insert(sections, k)
  end

  -- `o`: open the ticket under the cursor in Jira. `x`: open its
  -- related GitLab merge request, if any. `K`/`P`: show/toggle details.
  -- All mirror the dashboard's own `<cr>` handling to find
  -- the item at the cursor.
  vim.keymap.set("n", "o", function()
    local item = self:find(vim.api.nvim_win_get_cursor(self.win))
    if item and (item.personal_note or item.reminder) then
      item.action()
    elseif item and (item.review or item.issue_number) then
      vim.ui.open(item.web_url)
    elseif item and item.ticket then
      vim.fn.jobstart({ "jira", "open", item.ticket })
      vim.notify("Opening " .. item.ticket .. " in Jira", vim.log.levels.INFO)
    end
  end, { buffer = self.buf, nowait = true, desc = active == "reminders" and "Edit reminder source" or active == "notes" and "Open personal note" or github and "Open in GitHub" or active == "reviews" and "Open MR in GitLab" or "Open ticket in Jira" })
  vim.keymap.set("n", "x", function()
    local item = self:find(vim.api.nvim_win_get_cursor(self.win))
    if not item or not (item.ticket or item.review) then
      return
    end
    if not item.mr_iid then
      vim.notify("No merge request found for " .. item.ticket, vim.log.levels.WARN)
      return
    end
    local url = item.web_url or ("https://%s/%s/-/merge_requests/%s"):format(GITLAB_HOST, item.mr_project or GITLAB_PROJECT, item.mr_iid)
    vim.ui.open(url)
    vim.notify("Opening " .. (github and "#" or "!") .. item.mr_iid .. (github and " in GitHub" or " in GitLab"), vim.log.levels.INFO)
  end, { buffer = self.buf, nowait = true, desc = "Open related MR in GitLab" })

  -- `p`: trigger pipeline run for the related MR.
  -- Gets the MR's source branch and runs a new pipeline on it.
  vim.keymap.set("n", "p", function()
    if not cfg.actions.pipeline or not cfg.providers.gitlab.enabled then return end
    local item = self:find(vim.api.nvim_win_get_cursor(self.win))
    if not item or not item.ticket then
      return
    end
    if not item.mr_iid then
      vim.notify("No merge request found for " .. item.ticket, vim.log.levels.WARN)
      return
    end

    local project = item.mr_project or GITLAB_PROJECT
    local owner_generation = self._deskboard_generation
    local proj = project:gsub("/", "%%2F")
    local function authorized()
      local current = require("deskboard.config").get()
      return current.actions.pipeline and current.providers.gitlab.enabled
        and current.providers.gitlab.host == GITLAB_HOST and current.providers.gitlab.project == GITLAB_PROJECT
        and vim.api.nvim_buf_is_valid(self.buf) and self._deskboard_lifecycle and self._deskboard_generation == owner_generation
    end
    vim.fn.jobstart({ "glab", "api", "--hostname", GITLAB_HOST, "-X", "GET",
      ("projects/%s/merge_requests/%s"):format(proj, item.mr_iid) }, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        vim.schedule(function()
          if not authorized() then return end
          local ok, mr_data = pcall(vim.json.decode, table.concat(data or {}, ""))
          if not ok or type(mr_data) ~= "table" or tonumber(mr_data.iid) ~= tonumber(item.mr_iid)
            or type(mr_data.source_branch) ~= "string" then
            vim.notify("Failed to verify MR details", vim.log.levels.ERROR); return
          end
          local mr_branch = mr_data.source_branch
          vim.ui.select({ "Cancel", "Run pipeline" }, { prompt = "Run pipeline for " .. project .. " !" .. item.mr_iid .. "?" }, function(choice)
            if choice ~= "Run pipeline" or not authorized() then return end
            vim.fn.jobstart({ "glab", "pipeline", "run", "-b", mr_branch, "-R", "https://" .. GITLAB_HOST .. "/" .. project }, {
              on_exit = function(_, code)
                vim.schedule(function() vim.notify(code == 0 and "✓ Pipeline started" or "Pipeline failed",
                  code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR) end)
              end,
            })
          end)
        end)
      end,
    })
  end, { buffer = self.buf, nowait = true, desc = "Run pipeline for MR" })

  vim.keymap.set("n", "K", function()
    if active == "reminders" then return end
    if active == "notes" then note_details(); return end
    preview:show(self:find(vim.api.nvim_win_get_cursor(self.win)))
  end, { buffer = self.buf, nowait = true, desc = active == "notes" and "Note workflow details" or active == "reviews" and "Preview MR" or "Preview ticket and MR" })
  vim.keymap.set("n", "P", function()
    if active == "reminders" then return end
    if active == "notes" then
      if self._note_popup and self._note_popup:is_open() then close_previews() else note_details() end
      return
    end
    preview:toggle(self:find(vim.api.nvim_win_get_cursor(self.win)))
  end, { buffer = self.buf, nowait = true, desc = active == "notes" and "Toggle note details" or active == "reviews" and "Toggle MR preview" or "Toggle sprint preview" })
  vim.keymap.set("n", "R", function()
    if views.active == "reviews" then
      preview:invalidate()
      views:refresh()
    elseif views.active == "notes" or views.active == "reminders" then
      Snacks.dashboard.update()
    elseif views.issues then
      preview:invalidate()
      views:refresh_mine()
    else
      sync.refresh()
    end
  end, { buffer = self.buf, nowait = true, desc = active == "reminders" and "Refresh reminders" or active == "notes" and "Refresh personal notes" or active == "reviews" and "Refresh review queue" or "Refresh sprint board" })
  vim.keymap.set("n", "E", function()
    if not cfg.actions.jira_edit or not cfg.providers.jira.enabled then return end
    local item = self:find(vim.api.nvim_win_get_cursor(self.win))
    if not item or not item.ticket then return end
    preview:close()
    require("deskboard.jira_edit").open(item, {
      on_success = function()
        preview:invalidate()
        sync.refresh({ silent = true, queue = true })
      end,
    })
  end, { buffer = self.buf, nowait = true, desc = "Edit Jira title and description" })

  -- The dashboard buffer is already `modifiable = false`, but `i`
  -- would still visibly drop you into Insert mode (erroring only on
  -- the first keystroke). Disable it outright.
  vim.keymap.set("n", "i", "<Nop>", { buffer = self.buf, nowait = true, desc = "Disabled on dashboard" })

  -- Highlight the ticket line the cursor is currently resting on.
  -- Shared, cleared augroup: sections() reruns on every dashboard
  -- open/update (e.g. our jira-sync refresh), so autocmds must be
  -- replaced, not accumulated.
  local augroup = vim.api.nvim_create_augroup("deskboard_dashboard_" .. self.buf, { clear = true })
  local cursor_ns = vim.api.nvim_create_namespace("deskboard_cursor")
  local function update_ticket_hl()
    if
      views.active ~= active
      or not (self.win and vim.api.nvim_win_is_valid(self.win))
      or not vim.api.nvim_buf_is_valid(self.buf)
      or vim.api.nvim_win_get_buf(self.win) ~= self.buf
    then
      return
    end
    vim.api.nvim_buf_clear_namespace(self.buf, cursor_ns, 0, -1)
    local cursor = vim.api.nvim_win_get_cursor(self.win)
    local row = cursor[1]
    local item = self:find(cursor)
    local id = item and (item.id or item.ticket)
    if not id or (item._ and item._.row ~= row) then
      return
    end
    self[selected_attr] = id
    views:select(id)
    if not item.personal_note and not item.reminder then preview:update(item) end
    local line = vim.api.nvim_buf_get_lines(self.buf, row - 1, row, false)[1] or ""
    pcall(vim.api.nvim_buf_set_extmark, self.buf, cursor_ns, row - 1, 0, {
      end_col = #line,
      hl_group = "DeskboardCursor",
      hl_mode = "combine",
      hl_eol = true,
    })
  end

  -- `N`: quick jump to notes, or back to the previous panel.
  vim.keymap.set("n", "N", function()
    close_previews()
    local previous = views.previous or "mine"
    if not views:is_available(previous) then previous = "reminders" end
    views:switch(views.active == "notes" and previous or "notes")
  end, { buffer = self.buf, nowait = true, desc = "Switch to personal notes / back" })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = self.buf,
    callback = function()
      vim.schedule(update_ticket_hl)
    end,
  })
  -- The dashboard snaps the cursor onto the first item right after
  -- layout, via a direct API call that does not itself fire
  -- CursorMoved. Without this, the very first ticket would only get
  -- highlighted after the first real keypress.
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "SnacksDashboardUpdatePost",
    callback = function()
      vim.schedule(function()
        if views.active ~= active or not (self.win and vim.api.nvim_win_is_valid(self.win)) then
          return
        end
        -- Each view/page remembers its own stable ticket or MR identity.
        local selected = views:selection() or self[selected_attr]
        for _, item in ipairs(self.items or {}) do
          local id = item.id or item.ticket
          if id and id == selected and item._ then
            local line = self.lines[item._.row] or ""
            local label = item.ticket or (item.issue_number and ("#" .. item.issue_number))
              or (item.review and ((item.provider == "github" and "#" or "!") .. item.mr_iid)) or item.note_title
            local col = (line:find(label, 1, true) or 1) - 1
            vim.api.nvim_win_set_cursor(self.win, { item._.row, col })
            break
          end
        end
        update_ticket_hl()
      end)
    end,
  })

  return sections
end

function M.refresh()
  local owner = instances[vim.api.nvim_get_current_buf()]
  if not owner then M.redraw(); return end
  local cfg = require("deskboard.config").get()
  local view = require("deskboard.views").get({ buf = owner.buf })
  if view.active == "reviews" then view:refresh()
  elseif view.active == "mine" and view.issues then view:refresh_mine()
  elseif view.active == "mine" and cfg.providers.jira.enabled then require("deskboard.sync").refresh()
  elseif type(owner.update) == "function" then owner:update() end
end
function M.redraw()
  for _, owner in pairs(instances) do
    if owner.win and vim.api.nvim_win_is_valid(owner.win) and vim.api.nvim_win_get_buf(owner.win) == owner.buf and type(owner.update) == "function" then
      owner:update()
    end
  end
end
function M.reset()
  local owners = {}
  for _, owner in pairs(instances) do owners[#owners + 1] = owner end
  M.dispose()
  return owners
end
function M.dispose()
  for buf, owner in pairs(instances) do
    require("deskboard.views").release(buf)
    if owner._deskboard_preview then owner._deskboard_preview:close(); owner._deskboard_preview = nil end
    for _, name in ipairs({ "_note_popup", "_status_popup" }) do if owner[name] then owner[name]:close(); owner[name] = nil end end
    pcall(vim.api.nvim_del_augroup_by_name, "deskboard_owner_" .. buf)
    pcall(vim.api.nvim_del_augroup_by_name, "deskboard_dashboard_" .. buf)
    owner._deskboard_lifecycle = nil
  end
  instances = {}
end
return M

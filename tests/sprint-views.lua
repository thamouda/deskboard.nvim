dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/sprint-views.lua
-- Mocked review requests only; no real Jira, GitLab, checkout, or credential calls.
vim.opt.rtp:prepend(vim.fn.getcwd())
local views = require("workbench.views")
local board = require("workbench.board")
local count = 0
local function test(name, fn)
  fn()
  count = count + 1
  print("PASS: " .. name)
end
local function contains(value, wanted)
  assert(value:find(wanted, 1, true), "Missing " .. wanted .. " in " .. value)
end
local function text(item)
  if type(item.text) == "string" then return item.text end
  local parts = {}
  for _, part in ipairs(item.text or {}) do parts[#parts + 1] = part[1] end
  return table.concat(parts)
end
local function report(n)
  local rows = {}
  for i = 1, n do
    rows[i] = { iid = i, title = "MR without a Jira key " .. i, author = i % 2 == 0 and "alice" or "colleague", project = "team/repo",
      draft = i == 2, commits = i + 2, target_branch = "main", ci = i == 2 and "failed" or "success",
      approved = i - 1 + (i % 2 == 0 and 1 or 0), my_approved = i % 2 == 0, other_approvals = i - 1,
      threads = { resolved = 1, total = 3 }, my_threads = { resolved = 0, total = 1 },
      web_url = "https://gitlab.example.invalid/team/repo/-/merge_requests/" .. i }
  end
  return { version = 1, ok = true, user = { id = 7, username = "me" }, rows = rows }
end

test("pagination clamps boundaries, handles empty lists, and never mutates input", function()
  local rows = { 1, 2, 3, 4, 5 }
  local page, meta = views.paginate(rows, 99, 2)
  assert(vim.deep_equal(page, { 5 }) and meta.page == 3 and meta.pages == 3 and meta.total == 5)
  assert(meta.first == 5 and meta.last == 5 and #rows == 5)
  page, meta = views.paginate({}, -1, 0)
  assert(#page == 0 and meta.page == 1 and meta.pages == 1 and meta.first == 0 and meta.last == 0)
end)

test("views preserve independent pages/selections and fetch only when needed", function()
  local now, calls, changes = 1000, {}, 0
  local state = views.new({ page_size = 2, now = function() return now end, changed = function() changes = changes + 1 end,
    fetch = function(_, done) calls[#calls + 1] = done; return function() end end })
  state:set_total("mine", 5)
  state:move(1); state:select("TEST-3")
  assert(#calls == 0 and state.pages.mine == 2)
  state:toggle()
  assert(state.active == "reviews" and state.loading and #calls == 1 and not state:refresh())
  local partial = report(5)
  partial.rows[1].commits = vim.NIL
  partial.warnings = { "Commit counts unavailable for 1 MR(s)" }
  calls[1](partial)
  assert(#state.rows == 5 and not state.error and state.warning == partial.warnings[1])
  state:move(1); state:select("team/repo!3")
  state:toggle(-1)
  assert(state.active == "mine" and state.pages.mine == 2 and state:selection() == "TEST-3")
  state:toggle()
  assert(state.pages.reviews == 2 and state:selection() == "team/repo!3" and #calls == 1)
  now = now + 301
  state:toggle(-1); state:toggle()
  assert(#calls == 2 and #state.rows == 5)
  calls[2](nil, "GitLab authentication failed (HTTP 401)")
  assert(#state.rows == 5 and state.error and state.pages.reviews == 2)
  state:toggle(-1); state:toggle()
  assert(#calls == 2, "Failed requests must have a retry backoff")
  assert(state:refresh()) -- explicit R can retry immediately
  calls[3](report(0))
  assert(#state.rows == 0 and state.pages.reviews == 1 and state.pages.mine == 2)
  assert(changes > 0)
end)

test("four panels cycle in both directions and retain their own selection", function()
  local calls = 0
  local state = views.new({ page_size = 1, changed = function() end, fetch = function(_, done)
    calls = calls + 1; done(report(2)); return function() end
  end })
  state:set_total("mine", 3); state:move(1); state:select("TEST-2")
  state:toggle(); assert(state.active == "reviews" and calls == 1)
  state:move(1); state:select("team/repo!2")
  state:toggle(); assert(state.active == "notes" and calls == 1)
  state:set_notes({ { id = "n1", title = "First" }, { id = "n2", title = "Second" } })
  state:move(1); state:select("n2")
  state:toggle(); assert(state.active == "reminders" and calls == 1)
  state:set_reminders({ { id = "r1", title = "Capture" } }); state:select("r1")
  state:toggle(); assert(state.active == "mine" and state.pages.mine == 2 and state:selection() == "TEST-2")
  state:toggle(-1); assert(state.active == "reminders" and state:selection() == "r1")
  state:toggle(-1); assert(state.active == "notes" and state.pages.notes == 2 and state:selection() == "n2")
  state:toggle(-1); assert(state.active == "reviews" and state.pages.reviews == 2 and state:selection() == "team/repo!2")
end)

test("author filtering is local, exact, paginated, and independent of other panels", function()
  local requests = 0
  local state = views.new({ page_size = 2, changed = function() end, fetch = function() requests = requests + 1 end })
  state.rows, state.active = report(6).rows, "reviews"
  state:set_total("reviews", 6); state.pages.reviews = 3; state:select("old selection")
  state:set_total("mine", 8); state.pages.mine = 3
  state:set_notes({ { title = "Note", id = "n1" } }); state.selected.notes[1] = "n1"
  assert(vim.deep_equal(state:authors(), { "alice", "colleague" }))
  state:set_author("@ALICE")
  assert(#state:review_rows() == 3 and #state.rows == 6 and state.pages.reviews == 1 and not state:selection())
  assert(state.totals.reviews == 3 and state.pages.mine == 3 and state.selected.notes[1] == "n1")
  state:move(1); assert(state.pages.reviews == 2)
  local items, page = board.render_reviews({ state = state, width = 124 })
  local rows = {}; for _, item in ipairs(items) do if item.review then rows[#rows + 1] = item end end
  assert(page.total == 3 and page.pages == 2 and #rows == 1)
  assert(rows[1].text[8][1] == "@alice")
  state:set_author("missing-author")
  assert(state.totals.reviews == 0 and state.pages.reviews == 1 and #state:review_rows() == 0)
  state:set_author(nil)
  assert(#state:review_rows() == 6 and state.totals.reviews == 6 and state.pages.reviews == 1 and requests == 0)
end)

test("late review results cannot revive a disposed request", function()
  local done, cancelled
  local state = views.new({ changed = function() end, fetch = function(_, callback)
    done = callback
    return function() cancelled = true end
  end })
  state:refresh(); state:dispose(); done(report(3))
  assert(cancelled and not state.loading and #state.rows == 0)
end)

test("review fetch uses a bounded read-only argv command and validates its report", function()
  local callback, command, result, killed
  local opts = { host = "gitlab.example.invalid", project = "team/repo", proxy = "http://proxy.invalid:3128",
    run = function(cmd, options, done)
      command, callback = cmd, done
      assert(options.timeout == 90000 and options.text)
      return { kill = function() killed = true end }
    end }
  local cancel = views.fetch(opts, function(value) result = value end)
  assert(command[1] == "python3" and command[3] == "--reviews")
  assert(command[2]:match("/scripts/sprint%-sync%.py$"))
  local payload = report(3)
  payload.rows[1].commits = vim.NIL
  callback({ code = 0, stdout = vim.json.encode(payload) })
  assert(vim.wait(100, function() return result ~= nil end))
  assert(#result.rows == 3 and result.rows[1].commits == vim.NIL)
  cancel(); assert(killed)
  local error
  views.fetch(opts, function(_, err) error = err end)
  callback({ code = 124, stdout = "SECRET credential output", stderr = "SECRET" })
  assert(vim.wait(100, function() return error ~= nil end))
  assert(error == "Review queue request timed out" and not error:find("SECRET", 1, true))
end)

local todos = {}
for i = 1, 9 do
  todos[i] = { ticket = "TEST-" .. i, done = i > 7,
    text = "TEST-" .. i .. "|In Progress|Task|1d|!" .. i .. (i == 6 and " [FAIL]" or " [OK]") .. "|✅|1|yes|–" }
end
local function actionable(items)
  local result = {}
  for _, item in ipairs(items) do if item.ticket or item.review or item.personal_note or item.reminder then result[#result + 1] = item end end
  return result
end

test("main-board pagination follows priority ordering and preserves all actions", function()
  local all = actionable(board.render({ ticket_todos = todos }))
  local seen = {}
  for page = 1, 3 do
    local items, meta = board.render({ ticket_todos = todos, page = page, page_size = 3 })
    assert(meta.page == page and meta.pages == 3 and meta.total == 9)
    for i, item in ipairs(actionable(items)) do
      assert(item.ticket == all[(page - 1) * 3 + i].ticket and type(item.action) == "function")
      assert(not seen[item.ticket]); seen[item.ticket] = true
    end
  end
  assert(all[1].ticket == "TEST-6", "Failing CI must remain first across pages")
  assert(todos[1].ticket == "TEST-1")
end)

test("review rows are responsive, MR-addressable, and never ticket checkout actions", function()
  local state = views.new({ page_size = 2, changed = function() end })
  state.rows, state.user, state.fetched_at = report(5).rows, report(5).user, os.time()
  state.rows[1].title = "TEST-420 " .. string.rep("長い review title ", 20)
  state.rows[1].target_branch = "feature/TEST-1824_relations"
  state.rows[1].commits = 13
  state:set_total("reviews", 5)
  for _, width in ipairs({ 16, 24, 40, 60, 80, 124 }) do
    local opened
    local items, meta = board.render_reviews({ state = state, width = width, on_open = function(url) opened = url end })
    assert(meta.total == 5 and meta.pages == 3)
    local rows = actionable(items)
    assert(#rows == 2 and rows[1].ticket == nil and rows[1].review and rows[1].id == "team/repo!1")
    assert(rows[1].mr_project == "team/repo" and rows[1].mr_iid == "1" and rows[1].review_label == "TEST-420")
    if width == 124 then
      local value = text(rows[1])
      contains(value, "TEST-420"); contains(value, "@colleague"); contains(value, "13")
      contains(value, "TEST-1824")
      assert(not value:find("feature/TEST-1824_relations", 1, true))
      assert(not value:find("長い", 1, true))
      assert(rows[1].text[2][1] == "!1", "MR must be the first column")
    end
    rows[1].action(); assert(opened == state.rows[1].web_url)
    for _, item in ipairs(items) do assert(vim.api.nvim_strwidth(text(item)) <= width, text(item)) end
  end
  state.error = "GitLab unavailable"
  local items = board.render_reviews({ state = state })
  local lines = {}; for _, item in ipairs(items) do lines[#lines + 1] = text(item) end
  contains(table.concat(lines, "\n"), "cached")
  assert(not table.concat(lines, "\n"):find("showing cached list", 1, true))
end)

test("review columns show compact target, threads, CI, unique approvals and my threads", function()
  local state = views.new({ changed = function() end })
  state.rows, state.user, state.fetched_at = report(3).rows, report(3).user, os.time()
  state.rows[1].title = "TEST-420 full title must stay in the popup"
  state.rows[1].target_branch = "feature/TEST-1824_relations"
  state.rows[1].commits = 13
  state.rows[2].source_branch = "feature/TEST-555_source"
  state.rows[2].commits = 0
  state.rows[3].commits = vim.NIL
  state.warning = "Commit counts unavailable for 1 MR(s)"
  local items = board.render_reviews({ state = state, width = 124 })
  local rows = actionable(items)
  assert(rows[1].review_label == "TEST-420" and rows[2].review_label == "TEST-555" and rows[3].review_label == "!3")
  assert(rows[1].text[10][1] == "13" and rows[2].text[10][1] == "0" and rows[3].text[10][1] == "?")
  local value = {}; for _, item in ipairs(items) do value[#value + 1] = text(item) end
  value = table.concat(value, "\n")
  for _, name in ipairs({ "TICKET", "AUTHOR", "COMMITS", "TARGET", "THREADS", "CI", "APPROVED", "MY THREADS", "@colleague", "TEST-1824" }) do contains(value, name) end
  assert(not value:find("feature/TEST-1824_relations", 1, true))
  assert(rows[1].text[2][1] == "!1" and rows[1].text[4][1] == "TEST-420")
  assert(rows[1].text[6][1] == "repo" and rows[1].mr_project == "team/repo")
  assert(rows[1].text[14][1] == "1/3" and rows[1].text[14].hl == "WorkbenchWarning")
  assert(rows[1].text[16][1] == "✓ pass" and rows[1].text[16].hl == "WorkbenchSuccess")
  assert(rows[2].text[16][1] == "✗ fail" and rows[2].text[16].hl == "WorkbenchError")
  assert(rows[1].text[18][1] == "— (0)" and rows[2].text[18][1] == "✓ (1)")
  assert(rows[1].text[20][1] == "0/1" and rows[1].text[20].hl == "WorkbenchWarning")
  assert(rows[1].review_metrics.my_threads.total == 1)
  assert(not value:find("TITLE", 1, true) and not value:find("full title", 1, true) and not value:find("Draft:", 1, true))
  contains(value, "Metadata incomplete")
  local _, _, info = board.render_reviews({ state = state, width = 124 })
  contains(table.concat(info.details, "\n"), "Commit counts unavailable")
  assert(rows[1].ticket == nil, "A displayed Jira key must never enable checkout/edit actions in reviews")
end)

test("targets are shortened without inventing ticket associations", function()
  assert(board.target_label("main") == "main")
  assert(board.target_label("refs/heads/main") == "main")
  assert(board.target_label("feature/TEST-1824_relations") == "TEST-1824")
  assert(board.target_label("refs/heads/feature/TEST-42_fix") == "TEST-42")
  assert(board.target_label("release/6.0") == "release/6.0")
  assert(board.target_label("") == "?" and board.target_label(vim.NIL) == "?")
end)

test("unknown review metadata never becomes zero, all-clear or passed", function()
  local state = views.new({ changed = function() end })
  state.rows, state.user, state.fetched_at = report(3).rows, report(3).user, os.time()
  for _, name in ipairs({ "threads", "my_threads", "ci", "approved", "my_approved", "other_approvals" }) do state.rows[1][name] = vim.NIL end
  state.rows[2].threads, state.rows[2].my_threads = { resolved = 0, total = 0 }, { resolved = 0, total = 0 }
  state.rows[2].ci, state.rows[2].approved, state.rows[2].my_approved, state.rows[2].other_approvals = "none", 0, false, 0
  state.rows[3].threads, state.rows[3].my_threads = { resolved = 2, total = 2 }, { resolved = 1, total = 1 }
  state.rows[3].ci = "running"
  local rows = actionable(board.render_reviews({ state = state, width = 124 }))
  for _, index in ipairs({ 14, 16, 20 }) do
    assert(rows[1].text[index][1] == "?" and rows[1].text[index].hl == "WorkbenchMuted")
  end
  assert(rows[1].text[18][1] == "? (?)" and rows[1].text[18].hl == "WorkbenchMuted")
  assert(rows[2].text[14][1] == "0/0" and rows[2].text[16][1] == "—" and rows[2].text[18][1] == "— (0)")
  assert(rows[3].text[14][1] == "2/2" and rows[3].text[14].hl == "WorkbenchSuccess")
  assert(rows[3].text[16].hl == "WorkbenchWarning" and rows[3].text[20][1] == "1/1")
end)

test("malformed review statistics are rejected before replacing the cached queue", function()
  local callback, message
  local opts = { host = "host", project = "team/repo", run = function(_, _, done)
    callback = done; return { kill = function() end }
  end }
  views.fetch(opts, function(_, err) message = err end)
  local payload = report(1)
  payload.rows[1].my_threads = { resolved = 3, total = 2 }
  callback({ code = 0, stdout = vim.json.encode(payload) })
  assert(vim.wait(100, function() return message ~= nil end))
  assert(message == "GitLab returned invalid review assignments")
end)

test("all three panels keep identical fixed dimensions on every page and data state", function()
  local sprint = { name = "Sprint 26", start = "2026-11-01 09:00:00", stop = "2026-11-30 09:00:00" }
  for _, width in ipairs({ 16, 24, 40, 80, 124 }) do
    for _, size in ipairs({ 1, 2, 6 }) do
      local frame = board.frame({ width = width, page_size = size })
      local function same_size(items)
        assert(#items == frame.height, ("width %d size %d: height %d, wanted %d"):format(width, size, #items, frame.height))
        for _, item in ipairs(items) do assert(vim.api.nvim_strwidth(text(item)) == frame.width, text(item)) end
      end
      for page = 1, math.ceil(#todos / size) do
        same_size(board.render({ width = width, frame = frame, page_size = size, page = page,
          sprint = sprint, sync = { text = "Last refresh: just now" }, ticket_todos = todos }))
      end
      same_size(board.render({ width = width, frame = frame, page_size = size, ticket_todos = {} }))
      local state = views.new({ page_size = size, changed = function() end })
      same_size(board.render_reviews({ state = state, width = width, frame = frame }))
      state.loading = true
      same_size(board.render_reviews({ state = state, width = width, frame = frame }))
      state.rows, state.user, state.fetched_at, state.loading = report(5).rows, report(5).user, os.time(), false
      for page = 1, math.ceil(#state.rows / size) do
        state.pages.reviews = page
        same_size(board.render_reviews({ state = state, width = width, frame = frame }))
      end
      state.error, state.warning = "GitLab unavailable", "Commit counts unavailable"
      same_size(board.render_reviews({ state = state, width = width, frame = frame }))
      state:set_author("alice")
      same_size(board.render_reviews({ state = state, width = width, frame = frame }))
      state.rows = {}
      same_size(board.render_reviews({ state = state, width = width, frame = frame }))
      same_size(board.render_notes({ state = state, width = width, frame = frame }))
      local notes = {}; for i = 1, 5 do notes[i] = { id = "n" .. i, title = "Personal note " .. i } end
      state:set_notes(notes)
      for page = 1, math.ceil(#notes / size) do
        state.pages.notes = page
        same_size(board.render_notes({ state = state, width = width, frame = frame }))
      end
    end
  end
end)

test("notes show ID/title/status/category without bodies or ticket/MR actions", function()
  local state = views.new({ page_size = 2, changed = function() end })
  state:set_notes({
    { id = "n1", uid = "NOTE-001", title = "First title", status = "draft", scope = "personal", category = "home", tags = { "project", "perl" },
      path = "/private/one.md", body = "PRIVATE_BODY" },
    { id = "n2", title = "Second title", path = "/private/two.md", body = "PRIVATE_BODY" },
    { id = "n3", title = "Third title", path = "/private/three.md", body = "PRIVATE_BODY" },
  })
  for _, width in ipairs({ 16, 40, 80, 124 }) do
    local opened
    local frame = board.frame({ width = width, page_size = state.size })
    local items, page = board.render_notes({ state = state, width = width, frame = frame, on_open = function(note) opened = note.id end })
    local rows = actionable(items)
    assert(#items == frame.height and #rows == 2 and page.total == 3 and page.pages == 2)
    assert(rows[1].personal_note and not rows[1].ticket and not rows[1].review and not rows[1].mr_iid)
    if width == 124 then
      assert(rows[1].text[2][1] == "NOTE-001" and rows[1].text[4][1] == "First title")
      assert(rows[1].text[6][1] == "draft" and rows[1].text[8][1] == "personal/home")
      assert(rows[1].text[10][1] == "project, perl")
    end
    rows[1].action(); assert(opened == "n1")
    for _, item in ipairs(items) do
      local value = text(item)
      assert(vim.api.nvim_strwidth(value) == frame.width)
      assert(not value:find("PRIVATE_BODY", 1, true) and not value:find("/private/", 1, true))
    end
  end
  state.pages.notes = 2
  assert(actionable(board.render_notes({ state = state }))[1].id == "n3")
end)

test("MR-only preview never requests Jira and renders MR details without a fake ticket", function()
  local preview = require("workbench.preview")
  local calls, result = {}, nil
  preview.fetch({ mr_iid = "12", host = "gitlab.example.invalid", project = "team/repo", env = { GITLAB_TOKEN = "fixture" },
    run = function(cmd, _, done)
      assert(cmd[1] == "glab" and cmd[6] == "GET")
      calls[#calls + 1] = cmd
      done({ code = 0, stdout = vim.json.encode(cmd[#cmd]:match("/approvals$")
        and { approved_by = {}, approvals_left = 1 } or { iid = 12, title = "Review me", description = "MR description", state = "opened" }) })
      return { kill = function() end }
    end }, function(value) result = value end)
  assert(vim.wait(200, function() return result ~= nil end))
  assert(#calls == 2 and not result.jira_error)
  local lines = table.concat(preview.lines(result, { mr_iid = "12" }), "\n")
  contains(lines, "MR Review · !12"); contains(lines, "MR description")
  assert(not lines:find("Ticket Details", 1, true) and not lines:find("Jira request failed", 1, true))
end)

test("MR-only popups load without tickets and cache identical iids by project", function()
  local preview = require("workbench.preview")
  local fetch = preview.fetch
  local calls = {}
  preview.fetch = function(opts, done)
    calls[#calls + 1] = opts.project
    done({ errors = {}, fetched_at = os.time(), mr = { iid = 12, title = "MR in " .. opts.project, state = "opened" } })
    return function() end
  end
  local source = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  local owner = { buf = buf, win = vim.api.nvim_get_current_win() }
  local pane = preview.attach(owner, { project = "team/repo", glow = false })
  local ok, err = xpcall(function()
    pane:show({ mr_iid = "12", mr_project = "team/repo", review = true,
      review_metrics = { threads = { resolved = 1, total = 3 }, my_threads = { resolved = 0, total = 1 } } })
    assert(vim.wait(500, function() return #calls == 1 end))
    contains(table.concat(vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false), "\n"), "MR in team/repo")
    pane:update({ mr_iid = "12", mr_project = "team/repo", review = true,
      review_metrics = { threads = { resolved = 2, total = 3 }, my_threads = { resolved = 1, total = 2 } } })
    assert(#calls == 1, "Updated queue statistics should reuse fresh MR details")
    local value = table.concat(vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false), "\n")
    contains(value, "Threads (resolved/total, queue snapshot): 2/3")
    contains(value, "My threads started by me (resolved/total, queue snapshot): 1/2")
    pane:close()
    pane:show({ mr_iid = "12", mr_project = "another/repo", review = true })
    assert(vim.wait(500, function() return #calls == 2 end))
    contains(table.concat(vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false), "\n"), "MR in another/repo")
    pane:close()
    pane:show({ mr_iid = "12", mr_project = "team/repo", review = true })
    assert(#calls == 2)
    contains(table.concat(vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false), "\n"), "Cached preview")
  end, debug.traceback)
  pane:close()
  preview.fetch = fetch
  vim.api.nvim_set_current_win(owner.win)
  vim.api.nvim_set_current_buf(source)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.wait(20, function() return false end)
  assert(ok, err)
end)

test("dashboard Tab/page mappings preserve selection and keep review actions read-only", function()
  local real_notes = require("workbench.notes")
  local saved, names = {}, { "workbench.preview", "workbench.sync", "workbench.checkout", "workbench.notes", "workbench.note_actions", "lazyvim.config" }
  for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  local open, systemlist, jobstart, ui_open, get, snacks = io.open, vim.fn.systemlist, vim.fn.jobstart, vim.ui.open, views.get, _G.Snacks
  local ui_select = vim.ui.select
  local calls, opened, closed, refreshes, fetches, checkout = {}, {}, 0, 0, 0, 0
  local opened_note, detailed_note, note_actions = nil, nil, {}
  local render, sections, state
  local owner = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(), opts = {} }
  local selected_preview, status_lines
  local pane = { close = function() closed = closed + 1 end, update = function() end, invalidate = function() end,
    show = function(_, item) selected_preview = item end, toggle = function(_, item) selected_preview = item end }
  package.loaded["workbench.preview"] = { attach = function() return pane end,
    popup = function(owner, lines)
      status_lines = lines
      return { buf = owner.buf, close = function() end }
    end }
  package.loaded["workbench.sync"] = { status = function() return { text = "Cached sprint" } end,
    refresh = function() refreshes = refreshes + 1 end }
  package.loaded["workbench.checkout"] = { checkout = function() checkout = checkout + 1 end }
  package.loaded["lazyvim.config"] = { icons = { kinds = {} } }
  package.loaded["workbench.notes"] = vim.tbl_extend("force", {}, real_notes, {
    list = function(opts)
      local result = vim.list_extend({}, opts.reminders)
      for _, row in ipairs(result) do row.status, row.tags, row.scope, row.category = "inbox", {}, "reminders", "general" end
      result[#result + 1] = { id = "note:one", title = "First note", path = "/fake/one.md", body = "PRIVATE_BODY",
        status = "review", scope = "work", category = "development", tags = { "project" }, visibility = "private", kind = "file" }
      result[#result + 1] = { id = "note:two", title = "Second note", path = "/fake/two.md", body = "PRIVATE_BODY",
        status = "draft", scope = "personal", category = "general", tags = {}, visibility = "private", kind = "file" }
      result[#result + 1] = { id = "note:three", title = "Third note", path = "/fake/three.md", status = "draft", scope = "personal", category = "general", tags = {} }
      return result
    end,
    open = function(note) opened_note = note end,
  })
  package.loaded["workbench.note_actions"] = {
    details = function(note)
      detailed_note = note
      return { open = true, is_open = function(self) return self.open end, close = function(self) self.open = false end }
    end,
    status = function(note) note_actions.status = note.id end,
    reviewed = function(note) note_actions.reviewed = note.id end,
    visibility = function(note) note_actions.visibility = note.id end,
    delete = function(note) note_actions.delete = note.id end,
    browser = function(note) note_actions.browser = note.id end,
    search = function(rows) note_actions.search = #rows end,
    new_prompt = function() note_actions.new = true end,
  }
  io.open = function(path, mode)
    if path == require("workbench.config").get().reminders.path then
      return { close = function() end, lines = function()
        local i = 0
        return function()
          i = i + 1
          if i == 1 then return "Personal focus" end
          return todos[i - 1] and ("- [ ] " .. todos[i - 1].text)
        end
      end }
    end
    return open(path, mode)
  end
  vim.fn.systemlist = function() return {} end
  vim.fn.jobstart = function(cmd) calls[#calls + 1] = cmd end
  vim.ui.open = function(url) opened[#opened + 1] = url end
  state = views.new({ page_size = 2, changed = function() render() end, fetch = function(_, done)
    fetches = fetches + 1; done(report(3)); return function() end
  end })
  views.get = function() return state end
  _G.Snacks = { dashboard = { update = function() render() end } }
  local function key(lhs) return vim.fn.maparg(lhs, "n", false, true).callback() end
  owner.find = function(_, pos)
    for _, item in ipairs(owner.items or {}) do if item._ and item._.row == pos[1] then return item end end
  end
  local function select_item(item)
    vim.api.nvim_win_set_cursor(owner.win, { item._.row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = owner.buf })
    vim.wait(10, function() return false end)
  end
  local ok, err = xpcall(function()
    sections = require("workbench.adapter").sections
    render = function()
      owner.items, owner.lines = sections(owner), {}
      local first
      for _, item in ipairs(owner.items) do
        if item.text then
          owner.lines[#owner.lines + 1] = text(item)
          item._ = { row = #owner.lines, col = 0 }
          if not first and (item.ticket or item.review or item.personal_note or item.reminder) then first = item end
        end
      end
      vim.api.nvim_buf_set_lines(owner.buf, 0, -1, false, owner.lines)
      if first then vim.api.nvim_win_set_cursor(owner.win, { first._.row, 0 }) end
      vim.api.nvim_exec_autocmds("User", { pattern = "SnacksDashboardUpdatePost" })
      vim.wait(10, function() return false end)
    end
    render()
    assert(fetches == 0 and #actionable(owner.items) == 2)
    key("!"); assert(type(status_lines) == "table" and status_lines[1] == "# My tickets")
    key("]p"); assert(state.pages.mine == 2)
    local mine = actionable(owner.items)[2]; select_item(mine)
    assert(state:selection() == mine.ticket)
    local stable_height = #owner.lines
    key("N")
    assert(state.active == "notes" and #owner.lines == stable_height and state.totals.notes == 3)
    local note = actionable(owner.items)[1]
    assert(note.personal_note and not note.ticket and not note.mr_iid)
    note.action(); key("o"); key("K"); key("R")
    assert(opened_note.id == note.id and #opened == 0 and #calls == 0 and refreshes == 0 and fetches == 0)
    assert(not table.concat(owner.lines, "\n"):find("PRIVATE_BODY", 1, true))
    assert(detailed_note.id == note.id)
    local choose = "work/development"
    vim.ui.select = function(options, _, done)
      for _, option in ipairs(options) do if option.value == choose then done(option); return end end
      error("Missing note filter option: " .. choose)
    end
    key("C"); assert(state.note_filter.category == choose and #actionable(owner.items) == 1)
    choose = "review"; key("S"); key("Q")
    choose = "project"; key("t")
    assert(state.note_filter.status == "review" and state.note_filter.queue == "review" and state.note_filter.tag == "project")
    key("K"); assert(detailed_note.id == "note:one")
    key("M"); key("v"); key("V"); key("F"); key("+"); key("D"); key("B")
    assert(note_actions.status == "note:one" and note_actions.reviewed == "note:one" and note_actions.visibility == "note:one")
    assert(note_actions.search == 1 and note_actions.new and note_actions.delete == "note:one" and note_actions.browser == "note:one")
    key("A"); assert(not next(state.note_filter) and #actionable(owner.items) == 2)
    key("]p"); assert(state.pages.notes == 2)
    local selected_note = state:selection()
    key("N")
    assert(state.active == "mine" and state.pages.mine == 2 and state:selection() == mine.ticket)
    key("<Tab>")
    assert(state.active == "reviews" and fetches == 1 and #actionable(owner.items) == 2)
    assert(#owner.lines == stable_height, "All three panels must keep the same dimensions")
    local mr = actionable(owner.items)[1]
    mr.action(); key("o"); key("x")
    assert(#opened == 3 and #calls == 0 and checkout == 0)
    key("p"); key("E")
    assert(#calls == 0 and checkout == 0)
    key("K"); assert(selected_preview.review and not selected_preview.ticket)
    key("R"); assert(fetches == 2 and refreshes == 0)
    vim.ui.select = function(options, opts, done)
      assert(opts.prompt == "Filter reviews by author" and options[2].author == "alice")
      assert(opts.format_item(options[2]) == "@alice")
      done(options[2])
    end
    key("a")
    assert(state.author == "alice" and state.pages.reviews == 1 and #actionable(owner.items) == 1 and fetches == 2)
    key("A"); assert(not state.author and #actionable(owner.items) == 2 and fetches == 2)
    vim.ui.select = function(_, _, done) done(nil) end
    key("a"); assert(not state.author)
    key("<PageDown>"); assert(state.pages.reviews == 2 and #actionable(owner.items) == 1)
    assert(#owner.lines == stable_height, "A short last page must keep the same board height")
    local selected_mr = state:selection()
    key("<S-Tab>")
    assert(state.active == "mine" and state.pages.mine == 2 and state:selection() == mine.ticket)
    assert(#owner.lines == stable_height)
    assert(owner.find(owner, vim.api.nvim_win_get_cursor(owner.win)).ticket == mine.ticket)
    key("R"); assert(refreshes == 1)
    key("<Tab>")
    assert(state.pages.reviews == 2 and state:selection() == selected_mr and fetches == 2)
    key("<Tab>")
    assert(state.active == "notes" and state.pages.notes == 2 and state:selection() == selected_note)
    assert(#owner.lines == stable_height and fetches == 2 and refreshes == 1)
    key("<Tab>")
    assert(state.active == "reminders" and #actionable(owner.items) == 1 and #owner.lines == stable_height)
    local reminder = actionable(owner.items)[1]
    assert(reminder.reminder and not reminder.personal_note and not reminder.note_data)
    key("o"); key("R"); key("M"); key("D"); key("B")
    assert(opened_note.id == reminder.id and fetches == 2 and refreshes == 1)
    key("<S-Tab>"); assert(state.active == "notes")
    key("<S-Tab>"); assert(state.active == "reviews" and state.pages.reviews == 2)
    assert(closed > 0)
  end, debug.traceback)
  state:dispose()
  io.open, vim.fn.systemlist, vim.fn.jobstart, vim.ui.open, views.get, _G.Snacks = open, systemlist, jobstart, ui_open, get, snacks
  vim.ui.select = ui_select
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  assert(ok, err)
end)

print(string.format("%d sprint view / pagination tests passed", count))

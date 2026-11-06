dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/panel-layout.lua
-- Pure panel/status fixtures; no plugins, CLI calls, browser or network.
vim.opt.rtp:prepend(vim.fn.getcwd())
os.setlocale("C", "time")
local board = require("workbench.board")
local views = require("workbench.views")
local status = require("workbench.status")
local now = os.time({ year = 2026, month = 11, day = 5, hour = 9, min = 4, sec = 0 })
local count = 0
local function test(name, fn) fn(); count = count + 1; print("PASS: " .. name) end
local function text(item)
  local parts = {}; for _, part in ipairs(item.text or {}) do parts[#parts + 1] = part[1] end
  return table.concat(parts)
end
local function contains(value, wanted) assert(value:find(wanted, 1, true), "Missing " .. wanted .. " in " .. value) end
local function fixture(size)
  local state = views.new({ page_size = size, now = function() return now end, changed = function() end })
  state.user, state.fetched_at = { username = "me" }, now - 60
  local todos, notes = {}, {}
  for i = 1, 7 do
    todos[i] = { ticket = "TEST-" .. i, done = i > 5, text = "TEST-" .. i .. "|To review|Task|1d|!" .. i .. " [OK]|1/2|1|yes|–" }
    state.rows[i] = { iid = i, title = "TEST-" .. i, author = "colleague", project = "team/repository", commits = i,
      target_branch = "feature/TEST-42_target", threads = { resolved = 1, total = 2 }, my_threads = { resolved = 0, total = 1 },
      ci = "success", my_approved = false, other_approvals = 2, web_url = "https://example.invalid/" .. i }
    notes[i] = { id = "n" .. i, uid = ("NOTE-%03d"):format(i), title = "Knowledge note " .. i,
      scope = "work", category = "development/testing", status = "draft", kind = "file", visibility = "private", tags = { "project", "perl" } }
  end
  state:set_notes(notes); state:set_total("reviews", #state.rows)
  state:set_reminders({ { id = "reminder:1", title = "Quick capture", done = false }, { id = "reminder:2", title = "Done capture", done = true } })
  return todos, state
end
local function render(todos, state, width, page)
  local frame = board.frame({ width = width, page_size = state.size })
  state.pages.reviews, state.pages.notes = page, page
  local mine = { width = width, frame = frame, page_size = state.size, page = page, now = now,
    project = "team/repository", ticket_todos = todos,
    sprint = { name = "Sprint 26", start = "2026-11-01 09:00:00", stop = "2026-11-20 09:00:00" }, sync = { age = 60 } }
  return {
    board.render(mine),
    board.render_reviews({ state = state, width = width, frame = frame, now = now }),
    board.render_notes({ state = state, width = width, frame = frame, now = now }),
    (board.render_reminders({ state = state, width = width, frame = frame, now = now })),
  }, frame
end

test("all panels reserve identical clock-bearing headers and aligned table headings", function()
  local todos, state = fixture(3)
  local panels, frame = render(todos, state, 124, 1)
  local header_positions = {}
  for panel_index, items in ipairs(panels) do
    assert(#items == frame.height)
    local headers, clocks = 0, 0
    for i, item in ipairs(items) do
      assert(vim.api.nvim_strwidth(text(item)) == frame.width)
      if item.panel_header then
        headers = headers + 1; assert(item.header_slot == headers and i == headers + 1)
      end
      if item.header_clock then clocks = clocks + 1; assert(i == 1 and not item.panel_header) end
      if panel_index < 3 and not item.panel_header and text(item):find("PROJECT", 1, true) then header_positions[panel_index] = i end
      if panel_index == 3 and text(item):find("TAGS", 1, true) then header_positions[panel_index] = i end
      if panel_index == 4 and text(item):find("TITLE", 1, true) then header_positions[panel_index] = i end
    end
    assert(headers == board.header_rows and clocks == 1)
    contains(text(items[1]), "09:04")
    contains(text(items[1]), "Thu 05 Nov 2026")
  end
  assert(header_positions[1] == 9 and header_positions[2] == 9 and header_positions[3] == 9 and header_positions[4] == 9)
end)

test("header geometry never changes with page, width, loading, failures or empty data", function()
  for _, width in ipairs({ 16, 24, 40, 80, 124 }) do
    for _, size in ipairs({ 1, 2, 6 }) do
      local todos, state = fixture(size)
      for _, phase in ipairs({ "normal", "loading", "error", "empty" }) do
        state.loading = phase == "loading"
        state.error = phase == "error" and "GitLab authentication failed (HTTP 401)" or nil
        if phase == "empty" then state.rows = {}; state:set_notes({}); state:set_reminders({}); todos = {} end
        for page = 1, 3 do
          local panels, frame = render(todos, state, width, page)
          for _, items in ipairs(panels) do
            assert(#items == frame.height, "Frame overflow at " .. width .. "/" .. size .. "/" .. phase)
            local headers = 0
            for _, item in ipairs(items) do
              assert(vim.api.nvim_strwidth(text(item)) == frame.width, text(item))
              if item.panel_header then headers = headers + 1 end
            end
            assert(headers == 5)
          end
        end
      end
    end
  end
end)

test("project names are compact while MR metadata keeps the authoritative full path", function()
  local todos, state = fixture(2)
  todos[1].project = "different/team/cms"
  local panels = render(todos, state, 124, 1)
  local main_row, review_row
  for _, item in ipairs(panels[1]) do if item.ticket == "TEST-1" then main_row = item end end
  for _, item in ipairs(panels[2]) do if item.review then review_row = item; break end end
  contains(text(main_row), "cms"); assert(main_row.mr_project == "different/team/cms")
  contains(text(review_row), "repository"); assert(review_row.mr_project == "team/repository")
  assert(not text(review_row):find("team/repository", 1, true))
end)

test("note tags are visible without changing privacy, actions or metadata", function()
  local todos, state = fixture(2)
  local panels = render(todos, state, 124, 1)
  local note
  for _, item in ipairs(panels[3]) do if item.personal_note then note = item; break end end
  contains(text(note), "project, perl")
  assert(note.note_data.tags[1] == "project" and not note.ticket and not note.mr_iid)
end)

test("status badges are short and semantic, with full safe diagnostics retained", function()
  for _, case in ipairs({
    { "GitLab authentication failed (HTTP 401)", "Sign-in needed" },
    { "Jira permission denied (HTTP 403)", "Access denied" },
    { "Review queue request timed out", "Timed out" },
    { "Service query unavailable", "Refresh unavailable" },
  }) do
    local info = status.format({ title = "Reviews", error = case[1], cached = true })
    contains(info.text, case[2]); contains(info.text, "cached"); contains(info.text, "! details")
    assert(info.hl == "Warning" and vim.api.nvim_strwidth(info.text) < 70)
    contains(table.concat(info.details, "\n"), case[1])
    assert(not info.text:find("HTTP", 1, true))
  end
  local partial = status.format({ warnings = { "Commit counts unavailable for 12 MR(s)", "Other approvals unavailable for 3 MR(s)" } })
  contains(partial.text, "Partial data")
  contains(table.concat(partial.details, "\n"), "Other approvals unavailable")
  local local_note = status.format({ local_only = true, warnings = { "Authentication guide: review due" }, warning_label = "1 note needs review" })
  contains(local_note.text, "1 note needs review")
  assert(not local_note.text:find("Sign-in", 1, true))
end)

test("successful/refreshing/local states do not invent errors", function()
  contains(status.format({ age = 0 }).text, "Updated just now")
  contains(status.format({ age = 180 }).text, "Updated 3m ago")
  assert(status.format({ running = true }).hl == "Accent")
  contains(status.format({ local_only = true }).text, "Local only")
  contains(status.format({}).text, "Not refreshed")
end)

print(string.format("%d shared panel/header/status tests passed", count))

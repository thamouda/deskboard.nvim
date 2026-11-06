dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/sprint-board.lua
-- No network, plugins, reminder file, or Git worktree required.
vim.opt.rtp:prepend(vim.fn.getcwd())
os.setlocale("C", "time")
local board = require("deskboard.board")
local count = 0

local function test(name, fn)
  fn()
  count = count + 1
  print("PASS: " .. name)
end

local function todo(key, status, done, mr, threads, kind)
  return {
    ticket = key,
    done = done or false,
    text = table.concat({ key, status, kind or "🧩 Task", "1d↓", mr or "—", threads or "—" }, "|"),
  }
end

local function fixture(overrides)
  local opts = {
    width = 86,
    now = os.time({ year = 2026, month = 10, day = 25, hour = 9 }),
    sprint = { name = "Sprint 25", start = "2026-10-19 09:00:00", stop = "2026-11-09 09:00:00" },
    ticket_todos = {
      todo("TEST-42", "👀 To review", false, "🔀 !502 [FAIL]", "🔴 2/15"),
      todo("TEST-43", "🚧 In Progress", false, "🔀 !503 [RUN]", "✅ 1/1"),
      todo("TEST-44", "✅ Done", true, "🔀 !504 [OK]", "✅"),
    },
  }
  return vim.tbl_extend("force", opts, overrides or {})
end

local function text(item)
  local parts = {}
  for _, part in ipairs(item.text) do
    parts[#parts + 1] = part[1]
  end
  return table.concat(parts)
end

local function all_text(items)
  return table.concat(vim.tbl_map(text, items), "\n")
end

local function find(items, key)
  for _, item in ipairs(items) do
    if item.ticket == key then
      return item
    end
  end
  error("Missing ticket " .. key)
end

local function has_chunk(item, value, hl)
  for _, part in ipairs(item.text) do
    if part[1] == value and part.hl == "Deskboard" .. hl then
      return true
    end
  end
  return false
end

local function check_width(items, maximum)
  local card_width
  for _, item in ipairs(items) do
    local line = text(item)
    -- Match Snacks' context-independent cell widths, not CJK wrap padding at
    -- the headless window edge. Each compact card may have its own width.
    local actual = vim.api.nvim_strwidth(line)
    if line:sub(1, #"╭") == "╭" then
      card_width = actual
    end
    assert(actual <= maximum, "Too wide: " .. line)
    assert(actual == card_width, "Misaligned card border: " .. line)
    assert(not line:find("\n", 1, true))
  end
end

test("clear hierarchy, completion count, columns and one action per ticket", function()
  local selected = {}
  local items = board.render(fixture({
    on_checkout = function(key)
      selected[#selected + 1] = key
    end,
  }))
  local output = all_text(items)
  for _, label in ipairs({
    "SPRINT REVIEW",
    "Sprint 25",
    "1/3 complete · 33%",
    "IN FLIGHT · 2",
    "COMPLETED · 1",
    "MR / CI",
    "THREADS",
  }) do
    assert(output:find(label, 1, true), "Missing " .. label)
  end
  for _, item in ipairs(items) do
    assert((item.action ~= nil) == (item.ticket ~= nil), "Only ticket rows should be navigable")
    if item.action then
      item.action()
    end
  end
  assert(vim.deep_equal(selected, { "TEST-42", "TEST-43", "TEST-44" }))
  assert(find(items, "TEST-42").mr_iid == "502")
  assert(find(items, "TEST-42").jira_status == "To review")
  check_width(items, 86)
end)

test("status, pipeline and unresolved thread colours", function()
  local items = board.render(fixture())
  local failed = find(items, "TEST-42")
  assert(has_chunk(failed, "To review", "Warning"))
  assert(has_chunk(failed, " ✗", "Error"))
  assert(has_chunk(failed, "2/15", "Warning"))
  assert(has_chunk(find(items, "TEST-43"), " ◷", "Warning"))
  assert(has_chunk(find(items, "TEST-44"), " ✓", "Success"))
  assert(has_chunk(find(items, "TEST-44"), "TEST-44", "Muted"))
end)

test("current branch marker is exclusive and alignment stays fixed", function()
  local items = board.render(fixture({ current_ticket = "TEST-43" }))
  assert(text(find(items, "TEST-43")):find("▸ TEST-43", 1, true))
  assert(not text(find(items, "TEST-42")):find("▸", 1, true))
  assert(not text(find(items, "TEST-44")):find("▸", 1, true))
  check_width(items, 86)
end)

test("responsive widths retain ticket actions and MR metadata", function()
  for _, w in ipairs({ 120, 86, 80, 68, 60, 48, 36, 28, 20, 16 }) do
    local items = board.render(fixture({ width = w }))
    check_width(items, w)
    assert(find(items, "TEST-42").mr_iid == "502")
    if w >= 36 then
      assert(text(find(items, "TEST-42")):find("TEST-42", 1, true))
    end
  end
  local narrow = all_text(board.render(fixture({ width = 48 })))
  assert(not narrow:find("TYPE", 1, true))
  assert(narrow:find("MR / CI", 1, true))
end)

test("Unicode labels and long personal notes stay inside the card", function()
  local items = board.render(fixture({
    width = 36,
    show_notes = true,
    heading = "💡 Café 修复 " .. string.rep("長", 40),
    note_todos = {
      { done = false, text = "https://example.invalid/" .. string.rep("界", 40) },
      { done = true, text = "Done é ✅" },
    },
    ticket_todos = { todo("TEST-42", "👀 修复 审查", false, "🔀 !502 [OK]", "✅", "📖 故事") },
  }))
  check_width(items, 36)
  assert(all_text(items):find("PERSONAL NOTES", 1, true))
  assert(not text(find(items, "TEST-42")):find("👀", 1, true))
  -- At full width, non-ASCII labels survive icon removal unchanged.
  local wide = board.render(fixture({ ticket_todos = { todo("TEST-42", "👀 修复 审查") } }))
  assert(text(find(wide, "TEST-42")):find("修复 审查", 1, true))
end)

test("notes are hidden by default and have no checkout actions", function()
  local opts =
    { heading = "Personal focus", note_todos = { { text = "Buy coffee" } }, sprint = false, ticket_todos = {} }
  assert(#board.render(fixture(opts)) == 0)
  opts.show_notes = true
  local items = board.render(fixture(opts))
  assert(all_text(items):find("Personal focus", 1, true))
  for _, item in ipairs(items) do
    assert(not item.action)
  end
  opts.note_todos = { { text = "Finished note", done = true }, { text = "Open note", done = false } }
  local output = all_text(board.render(fixture(opts)))
  assert(output:find("Open note", 1, true) < output:find("Finished note", 1, true))
end)

test("sprint time progress handles future, live and ended sprints", function()
  local live = all_text(board.render(fixture()))
  assert(live:find("28% · 15 days left", 1, true))
  local future = all_text(board.render(fixture({ now = 0 })))
  assert(future:find("0% · not started", 1, true))
  local ended = all_text(board.render(fixture({ now = os.time({ year = 2027, month = 1, day = 1 }) })))
  assert(ended:find("100% · ended", 1, true))
end)

test("elapsed percentage and remaining days sit above a full-width progress bar", function()
  local items = board.render(fixture())
  local label_row, bar_row
  for i, item in ipairs(items) do
    local line = text(item)
    if line:find("28% · 15 days left", 1, true) then
      label_row = i
    end
    if line:find("━", 1, true) then
      bar_row = i
      assert(not line:find("%%") and not line:find("days left", 1, true))
      local content = line:match("^│  (.-)  │$")
      assert(content and vim.api.nvim_strwidth(content) == vim.api.nvim_strwidth(line) - 6)
    end
  end
  assert(label_row and bar_row and label_row + 1 == bar_row)
  check_width(items, 86)
end)

test("invalid dates omit the time bar without hiding the sprint", function()
  for _, sprint in ipairs({
    { name = "No dates" },
    { name = "Bad dates", start = "invalid", stop = "invalid" },
    { name = "Reversed", start = "2026-11-09 09:00:00", stop = "2026-10-19 09:00:00" },
  }) do
    local output = all_text(board.render(fixture({ sprint = sprint })))
    assert(output:find(sprint.name, 1, true))
    assert(not output:find("Time", 1, true))
  end
end)

test("cross-year sprint date labels include both years", function()
  local items = board.render(fixture({
    sprint = { name = "Winter", start = "2026-12-28 09:00:00", stop = "2027-01-11 09:00:00" },
  }))
  assert(all_text(items):find("28 Dec 2026 → 11 Jan 2027", 1, true))
end)

test("missing sprint, missing metadata and empty ticket list are safe", function()
  local items = board.render(fixture({ sprint = false, ticket_todos = { { text = "TEST-42", ticket = "TEST-42" } } }))
  assert(find(items, "TEST-42").mr_iid == nil)
  check_width(items, 86)
  local empty = all_text(board.render(fixture({ ticket_todos = {} })))
  assert(empty:find("No tickets synced yet", 1, true))
  assert(not empty:find("IN FLIGHT", 1, true))
  local done = all_text(board.render(fixture({ ticket_todos = { todo("TEST-42", "Done", true) } })))
  assert(done:find("1/1 complete · 100%", 1, true))
  assert(not done:find("IN FLIGHT", 1, true))
end)

test("pending/skipped and legacy emoji pipeline indicators", function()
  for _, case in ipairs({
    { "[WAIT]", " ◷", "Warning" },
    { "[SKIP]", " −", "Muted" },
    { "✅", " ✓", "Success" },
    { "❌", " ✗", "Error" },
    { "⏳", " ◷", "Warning" },
  }) do
    local items =
      board.render(fixture({ ticket_todos = { todo("TEST-42", "🚫 Blocked", false, "🔀 !5 " .. case[1]) } }))
    assert(has_chunk(find(items, "TEST-42"), case[2], case[3]))
    assert(has_chunk(find(items, "TEST-42"), "Blocked", "Error"))
  end
end)

test("smart priority sorts active work without reordering completed rows or inputs", function()
  local todos = {
    todo("TEST-1", "To Do"),
    todo("TEST-2", "To review"),
    todo("TEST-3", "To review", false, "!3 [OK]", "2/5"),
    todo("TEST-4", "Blocked"),
    todo("TEST-5", "To review", false, "!5 [FAIL]"),
    todo("TEST-6", "To review", false, "!6 [OK]", "1/9"),
    todo("TEST-7", "To review", false, "!7 [FAIL]"),
    todo("TEST-8", "Done", true, "!8 [FAIL]"),
    todo("TEST-9", "Done", true),
  }
  local before = vim.deepcopy(todos)
  local items = board.render(fixture({ ticket_todos = todos }))
  local keys = {}
  for _, item in ipairs(items) do
    if item.ticket then
      keys[#keys + 1] = item.ticket
    end
  end
  assert(
    vim.deep_equal(keys, { "TEST-5", "TEST-7", "TEST-4", "TEST-6", "TEST-3", "TEST-2", "TEST-1", "TEST-8", "TEST-9" })
  )
  assert(vim.deep_equal(before, todos))
  assert(all_text(items):find("CI 2 · blocked 1 · threads 11", 1, true))
end)

test("freshness remains visible even before the first sync", function()
  for _, w in ipairs({ 86, 60, 28, 16 }) do
    local items = board.render(fixture({
      width = w,
      sprint = false,
      ticket_todos = {},
      sync = { text = "Last refresh: never · R refresh", hl = "Warning" },
    }))
    check_width(items, w)
    assert(#items > 0)
  end
  local items = board.render(fixture({ sync = { age = 180, text = "Last refresh: 3m ago · R refresh", hl = "Muted" } }))
  assert(all_text(items):find("Updated 3m ago", 1, true))
end)

test("approval/readiness/merged columns are distinct, coloured and backward compatible", function()
  local function review(key, done, approved, ready, merged)
    local t = todo(key, done and "Done" or "To review", done, "!502 [OK]", "✅")
    t.text = t.text .. "|" .. approved .. "|" .. ready .. "|" .. merged
    return t
  end
  local items = board.render(fixture({
    width = 150,
    ticket_todos = {
      review("TEST-42", false, "2", "yes", "–"),
      review("TEST-43", true, "1", "merged", "feature/TEST-1313_Refactor_datasources_on_CMS6"),
      review("TEST-44", true, "3", "merged", "main"),
      review("TEST-45", false, "0", "approvals", "–"),
      review("TEST-46", false, "~2", "unknown", "–"),
      review("TEST-47", true, "1", "yes", "–"),
      todo("TEST-48", "Done", true, "!503 [OK]", "✅"),
    },
  }))
  for _, label in ipairs({ "APPROVED", "READY", "MERGED INTO" }) do
    assert(all_text(items):find(label, 1, true), label)
  end
  assert(has_chunk(find(items, "TEST-42"), "2", "Success"))
  assert(has_chunk(find(items, "TEST-42"), "✓ yes", "Success"))
  assert(has_chunk(find(items, "TEST-43"), "TEST-1313", "Success"))
  assert(has_chunk(find(items, "TEST-44"), "main", "Success"))
  assert(not text(find(items, "TEST-43")):find("feature/", 1, true))
  assert(has_chunk(find(items, "TEST-45"), "appr.", "Warning"))
  assert(has_chunk(find(items, "TEST-46"), "~2", "Warning"))
  assert(has_chunk(find(items, "TEST-46"), "?", "Muted"))
  -- Jira Done is not proof that the MR was merged; legacy six-column data
  -- must remain renderable without inventing approvals or readiness.
  assert(not text(find(items, "TEST-47")):find("main", 1, true))
  assert(not text(find(items, "TEST-48")):find("✓ yes", 1, true))
  check_width(items, 150)
end)

test("merged target keeps main, extracts ticket keys and preserves branches without a key", function()
  for _, case in ipairs({
    { "main", "main" },
    { "refs/heads/main", "main" },
    { "feature/TEST-1234_long_branch_name", "TEST-1234" },
    { "hotfix/TEST-42_fix", "TEST-42" },
    { "release/6.0", "release/6.0" },
    { "release/修复", "release/修复" },
  }) do
    local t = todo("TEST-99", "Done", true, "!502 [OK]", "✅")
    t.text = t.text .. "|1|merged|" .. case[1]
    local items = board.render(fixture({ width = 124, ticket_todos = { t } }))
    assert(has_chunk(find(items, "TEST-99"), case[2], "Success"), case[1])
    assert(t.text:find(case[1], 1, true), "Do not abbreviate the underlying snapshot")
    check_width(items, 124)
  end
end)

test("new metadata columns stay inside every responsive card and retain actions", function()
  local t = todo("TEST-42", "In Progress", false, "!502 [OK]", "✅ 1/1")
  t.text = t.text .. "|2|yes|feature/TEST-1234_very_long_branch_name"
  for _, w in ipairs({ 180, 150, 124, 120, 100, 86, 80, 68, 60, 48, 36, 28, 20, 16 }) do
    local items = board.render(fixture({ width = w, ticket_todos = { t } }))
    check_width(items, w)
    assert(find(items, "TEST-42").mr_iid == "502")
    assert(type(find(items, "TEST-42").action) == "function")
  end
end)

test("cards hug the text instead of filling the configured maximum", function()
  local items = board.render(fixture({ width = 180 }))
  local actual = vim.api.nvim_strwidth(text(items[1]))
  assert(actual < 124, "Wide ceiling must not force a wide frame")
  local header
  for _, item in ipairs(items) do
    local line = text(item)
    if line:find("APPROVED", 1, true) then
      header = line
      -- No surplus right-hand blank space beyond the intentional 2-cell inset.
      assert(line:sub(-#"MERGED INTO  │") == "MERGED INTO  │")
    end
    if line:find("━", 1, true) then
      assert(vim.api.nvim_strwidth(line) == actual)
    end
  end
  assert(header)
  check_width(items, 180)
end)

test("palette follows the theme without accumulating autocmds", function()
  board.setup_highlights()
  board.setup_highlights()
  assert(#vim.api.nvim_get_autocmds({ group = "deskboard_colors" }) == 1)
  vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xab1234 })
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test" })
  assert(vim.api.nvim_get_hl(0, { name = "DeskboardError", link = false }).fg == 0xab1234)
  assert(vim.api.nvim_get_hl(0, { name = "DeskboardError", link = false }).bold)
  assert(not vim.api.nvim_get_hl(0, { name = "DeskboardCursor", link = false }).fg)
end)

print(("All %d sprint board tests passed"):format(count))

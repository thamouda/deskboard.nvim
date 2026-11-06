dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/sprint-notes.lua
-- Disposable note fixtures only; never reads/writes the real personal vault.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.hidden = true
local notes = require("workbench.notes")
local root = vim.fn.tempname() .. " personal notes"
vim.fn.mkdir(root .. "/nested", "p")
local count = 0
local function test(name, fn)
  fn(); count = count + 1; print("PASS: " .. name)
end
local function write(path, lines) vim.fn.writefile(lines, path) end
write(root .. "/alpha.md", { "# Alpha title", "", "PRIVATE_BODY_ALPHA" })
write(root .. "/nested/beta.md", { "---", "# Not a YAML title", "---", "```md", "# Code example", "```", "# Beta title", "PRIVATE_BODY_BETA" })
write(root .. "/fallback-name.md", { "PRIVATE_BODY_WITHOUT_HEADING" })
write(root .. "/index.md", { "# Personal index" })
write(root .. "/.hidden.md", { "# Hidden note" })
local function find(rows, name)
  for _, row in ipairs(rows) do if row.title == name then return row end end
end

test("lists only titles, with heading/filename fallbacks and no index or hidden files", function()
  local rows = notes.list({ root = root })
  assert(#rows == 3 and rows[1].title == "Alpha title" and rows[2].title == "Beta title")
  assert(rows[3].title == "fallback name")
  assert(not vim.json.encode(rows):find("PRIVATE_BODY", 1, true))
  assert(rows[1].id == "note:" .. root .. "/alpha.md")
end)

test("existing reminders join the title list without expanding their content", function()
  local rows = notes.list({ root = root, reminders = {
    { id = "reminder:3", title = "Shopping\nlist", path = root .. "/reminder.md", lnum = 3, done = false },
    { id = "reminder:4", title = "   ", path = root .. "/reminder.md", lnum = 4 },
  } })
  assert(#rows == 4)
  local reminder = find(rows, "Shopping list")
  assert(reminder and reminder.id == "reminder:3" and reminder.lnum == 3)
end)

test("changed titles refresh without changing stable note identity", function()
  local before = find(notes.list({ root = root }), "Alpha title")
  write(root .. "/alpha.md", { "# A renamed longer title", "PRIVATE_BODY_UPDATED" })
  local after = find(notes.list({ root = root }), "A renamed longer title")
  assert(after and before.id == after.id)
end)

test("unsaved headings in loaded notes are visible without publishing changes", function()
  notes.open({ path = root .. "/alpha.md" })
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "# Unsaved local title" })
  assert(find(notes.list({ root = root }), "Unsaved local title"))
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "Heading removed locally" })
  assert(find(notes.list({ root = root }), "alpha"), "An unsaved heading removal must not reuse the disk heading")
  assert(vim.fn.readfile(root .. "/alpha.md")[1] == "# A renamed longer title")
  vim.api.nvim_buf_delete(0, { force = true })
end)

test("symlinks are not followed outside the personal vault", function()
  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside, "p")
  write(outside .. "/outside.md", { "# Outside vault title" })
  assert(vim.uv.fs_symlink(outside, root .. "/external-dir"))
  assert(vim.uv.fs_symlink(outside .. "/outside.md", root .. "/external.md"))
  assert(#notes.list({ root = root }) == 3)
  vim.fn.delete(outside, "rf")
end)

test("Enter opens literal filenames safely and clamps reminder line numbers", function()
  local path = root .. "/literal | harmless.md"
  write(path, { "# Literal filename", "second", "third" })
  notes.open({ path = path, lnum = 999 })
  assert(vim.api.nvim_buf_get_name(0) == path and vim.api.nvim_win_get_cursor(0)[1] == 3)
  assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "# Literal filename")
  vim.api.nvim_buf_delete(0, { force = true })
end)

test("the dedicated reminder snapshot is excluded even from a broad configured vault", function()
  local snapshot = root .. "/capture-snapshot.md"
  write(snapshot, { "SPRINT|Sprint 26|start|end", "- [ ] TEST-42|private ticket snapshot" })
  local rows = notes.list({ root = root, reminder_path = snapshot })
  for _, note in ipairs(rows) do assert(note.path ~= snapshot) end
  vim.fn.delete(snapshot)
end)

test("missing vault is safe and still permits reminder-only notes", function()
  local rows = notes.list({ root = root .. "/missing", reminders = {
    { id = "reminder:1", title = "Focus", path = root .. "/reminder.md", lnum = 1 },
  } })
  assert(#rows == 1 and rows[1].title == "Focus")
end)

vim.fn.delete(root, "rf")
print(string.format("%d personal note index tests passed", count))

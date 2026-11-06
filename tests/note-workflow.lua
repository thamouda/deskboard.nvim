dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/note-workflow.lua
-- Disposable vaults only. No real notes, remote services, or Git writes.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.hidden = true
local meta = require("workbench.note_metadata")
local notes = require("workbench.notes")
local workflow = require("workbench.note_actions")
local root = vim.fn.tempname() .. " knowledge"
local roots = { personal = root .. "/personal", work = root .. "/work" }
local old_roots, old_index, old_ids = vim.g.sprint_note_roots, vim.g.sprint_note_index_root, vim.g.sprint_note_id_state_dir
vim.g.sprint_note_roots, vim.g.sprint_note_index_root, vim.g.sprint_note_id_state_dir = roots, root, root .. "/id-state"
vim.fn.mkdir(roots.personal, "p"); vim.fn.mkdir(roots.work, "p")
local count, notices = 0, {}
vim.notify = function(value) notices[#notices + 1] = value end
local function test(name, fn) fn(); count = count + 1; print("PASS: " .. name) end
local function write(path, lines) vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p"); vim.fn.writefile(lines, path) end
local function find(rows, title)
  for _, note in ipairs(rows) do if note.title == title then return note end end
end
local function content(path) return table.concat(vim.fn.readfile(path), "\n") end

local ok, err = xpcall(function()
  test("legacy notes are private inbox entries without rewrites", function()
    local value = meta.parse({ "# Legacy", "body" })
    assert(value.valid and value.status == "inbox" and value.visibility == "private" and #value.tags == 0)
  end)

  test("frontmatter supports quoted scalars, comments, inline/block tags and dates", function()
    local value = meta.parse({ "---", "id: KB-12", 'title: "A: title # literal" # comment', "status: to-review",
      "visibility: team", "reviewed: 2026-11-01", "review_due: 2026-12-01", "tags: [perl, 'project', perl, \"with,comma\"]", "---" })
    assert(value.valid and value.title == "A: title # literal" and value.status == "review")
    assert(vim.deep_equal(value.tags, { "perl", "project", "with,comma" }))
    local block = meta.parse({ "---", "tags:", "  - Perl", "  - project", "status: draft", "---" })
    assert(block.valid and vim.deep_equal(block.tags, { "perl", "project" }))
    assert(meta.date("2024-02-29") and not meta.date("2026-02-29") and not meta.date("2026-11-31"))
  end)

  test("malformed/unsupported workflow metadata fails closed", function()
    for _, lines in ipairs({
      { "---", "status: ready", "status: draft", "---" },
      { "---", "status: !execute something", "---" },
      { "---", "visibility: public", "---" },
      { "---", "tags: [ok] trailing invalid data", "---" },
      { "---", 'tags: ["two\\nlines"]', "---" },
      { "---", "title: |", "  multiline", "---" },
      { "---", 'title: ""', "---" },
      { "---", "review_due: 2026-02-31", "---" },
      { "---", "status: ready" },
    }) do assert(not meta.parse(lines).valid) end
  end)

  test("metadata changes preserve unknown fields and the entire Markdown body", function()
    local lines = { "---", "status: draft", "visibility: private", "confluence:", "  page_id: 123", "---", "", "# Existing", "body", "```", "status: literal", "```" }
    local result = assert(meta.update(lines, { status = "review", reviewed = "2026-11-05" }))
    assert(meta.parse(result).status == "review")
    assert(table.concat(result, "\n"):find("confluence:\n  page_id: 123", 1, true))
    assert(table.concat(result, "\n"):find("# Existing\nbody\n```\nstatus: literal\n```", 1, true))
    assert(not meta.update({ "---", "status: bad", "---", "body" }, { status = "draft" }))
  end)

  test("category/status/tag filters and review/ready queues exclude private or unreviewed content", function()
    local today = "2026-11-05"
    local rows = {
      { id = "a", uid = "KB-a", kind = "file", title = "Ready", scope = "work", category = "development/testing", status = "ready", visibility = "team",
        tags = { "project" }, reviewed = "2026-11-01", review_due = "2026-12-01" },
      { id = "b", kind = "file", title = "Private", scope = "personal", category = "general", status = "ready", visibility = "private",
        tags = {}, reviewed = "2026-11-01", review_due = "2026-12-01" },
      { id = "c", kind = "file", title = "Overdue", scope = "work", category = "operations", status = "published", visibility = "team",
        tags = { "docker" }, reviewed = "2026-01-01", review_due = "2026-11-04" },
      { id = "d", kind = "file", title = "Unreviewed", scope = "work", category = "development", status = "ready", visibility = "team", tags = {} },
      { id = "e", title = "Inbox", scope = "reminders", category = "reminders", status = "inbox", tags = {} },
    }
    assert(#notes.filter(rows, { queue = "ready" }, today) == 1)
    assert(#notes.filter(rows, { queue = "review" }, today) == 1)
    assert(#notes.filter(rows, { category = "work/development", status = "ready", tag = "project" }, today) == 1)
    assert(#notes.filter(rows, { queue = "inbox" }, today) == 1)
    local summary = notes.summary(rows, today)
    assert(summary.inbox == 1 and summary.ready == 1 and summary.overdue == 1 and summary.review == 1)
    assert(vim.tbl_contains(notes.facets(rows, "category"), "work/development/testing"))
  end)

  test("index reads metadata without bodies and detects duplicate IDs", function()
    for _, path in ipairs({ roots.work .. "/development/a.md", roots.personal .. "/b.md" }) do
      write(path, { "---", "id: KB-duplicate", "title: Duplicate", "status: ready", "visibility: team", "reviewed: 2026-11-01", "review_due: 2099-12-01", "---", "BODY_NEVER_IN_ROWS" })
    end
    local rows = notes.list()
    assert(#rows == 2 and rows[1].metadata_error == "Duplicate note ID" and rows[2].metadata_error)
    assert(rows[1].id ~= rows[2].id and not notes.ready(rows[1]))
    assert(not vim.json.encode(rows):find("BODY_NEVER_IN_ROWS", 1, true))
  end)

  local path
  test("new structured notes require explicit save and update folder/vault/unified indexes", function()
    workflow.setup(); workflow.setup()
    assert(vim.fn.exists(":NotesNew") == 2 and vim.fn.exists(":NotesStatus") == 2)
    path = assert(workflow.create({ scope = "work", category = "development/testing", title = "Safe testing", tags = { "project", "perl" } }))
    assert(not vim.uv.fs_stat(path), "Creating a draft buffer must not save it")
    local value = meta.parse(vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert(value.valid and value.status == "inbox" and value.visibility == "private" and value.uid == "NOTE-001")
    vim.cmd("write")
    assert(vim.uv.fs_stat(path))
    assert(content(roots.work .. "/development/testing/index.md"):find("](safe-testing.md)", 1, true))
    assert(content(roots.work .. "/index.md"):find("](development/testing/safe-testing.md)", 1, true))
    assert(content(root .. "/index.md"):find("](work/development/testing/safe-testing.md)", 1, true))
    local before = content(root .. "/index.md")
    assert(workflow.index(workflow.current()))
    assert(content(root .. "/index.md") == before, "Index retries must not duplicate links")
  end)

  test("status/review metadata changes stay in the buffer until :w", function()
    local note = workflow.current()
    local before = content(path)
    assert(workflow.edit(note, { status = "review" }))
    assert(meta.parse(vim.api.nvim_buf_get_lines(0, 0, -1, false)).status == "review")
    assert(content(path) == before and vim.bo.modified)
    vim.cmd("write")
    assert(content(path) ~= before)
  end)

  test("modified index buffers are never overwritten", function()
    local index = roots.work .. "/index.md"
    vim.cmd.edit(vim.fn.fnameescape(index))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Unsaved index work" })
    local index_buf = vim.api.nvim_get_current_buf()
    local before = content(index)
    vim.cmd.edit(vim.fn.fnameescape(path))
    assert(not workflow.index(workflow.current()))
    assert(content(index) == before and vim.api.nvim_buf_get_lines(index_buf, 0, -1, false)[1] == "Unsaved index work")
    vim.api.nvim_buf_delete(index_buf, { force = true })
  end)

  test("creation refuses collisions, traversal and category symlinks", function()
    local _, error = workflow.create({ scope = "work", category = "development/testing", title = "Safe testing" })
    assert(error and error:find("already exists", 1, true))
    assert(not workflow.create({ scope = "work", category = "../escape", title = "Bad" }))
    assert(not workflow.create({ scope = "work", category = "/escape", title = "Bad" }))
    local outside = root .. "/outside"; vim.fn.mkdir(outside, "p")
    assert(vim.uv.fs_symlink(outside, roots.work .. "/linked"))
    assert(not workflow.create({ scope = "work", category = "linked", title = "Bad" }))
    assert(not vim.uv.fs_stat(outside .. "/bad.md"))
  end)

  test("reminder entries cannot be silently converted into YAML articles", function()
    local before = content(path)
    assert(not workflow.edit({ kind = "reminder", title = "Reminder", path = path }, { status = "ready" }))
    assert(content(path) == before)
  end)

  test("ready status and team visibility require separate explicit confirmations", function()
    vim.cmd.edit(vim.fn.fnameescape(path))
    local select = vim.ui.select
    local answers = { "ready", "Cancel" }
    vim.ui.select = function(_, _, done) done(table.remove(answers, 1)) end
    local note = workflow.current()
    workflow.status(note)
    assert(meta.parse(vim.api.nvim_buf_get_lines(0, 0, -1, false)).status == "review")
    answers = { "ready", "I checked context, examples, links, duplicates, and secrets" }
    workflow.status(note)
    local current = workflow.current()
    assert(current.status == "ready" and current.reviewed and current.review_due and current.visibility == "private")
    assert(not notes.ready(current))
    answers = { "team", "Allow this note in the team publication queue" }
    workflow.visibility(current)
    assert(workflow.current().dirty and not notes.ready(workflow.current()), "Unsaved notes are not ready to publish")
    vim.ui.select = select
    assert(content(path):find('status: "review"', 1, true), "Confirmations still must not auto-save")
    vim.cmd("write")
    assert(notes.ready(workflow.current()))
  end)

  test("details are read-only metadata and retain duplicate-ID publication warnings", function()
    local duplicate = find(notes.list(), "Duplicate")
    assert(duplicate and duplicate.metadata_error)
    local run = vim.system
    vim.system = function() error("Note details must not execute a remote/local process") end
    local owner = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win() }
    local popup = workflow.details(duplicate, owner)
    assert(popup and popup:is_open() and not vim.bo[popup.buf].modifiable)
    local value = table.concat(vim.api.nvim_buf_get_lines(popup.buf, 0, -1, false), "\n")
    assert(value:find("Duplicate note ID", 1, true) and value:find("Ready to publish locally: no", 1, true))
    assert(not value:find("BODY_NEVER_IN_ROWS", 1, true))
    popup:close()
    vim.system = run
  end)

  test("explicit title saves refresh indexes without duplicating or losing other entries", function()
    local before = content(root .. "/index.md")
    assert(workflow.edit(workflow.current(), { title = "A better title" }))
    vim.cmd("write")
    local after = content(root .. "/index.md")
    assert(after:find("[A better title]", 1, true) and not after:find("[Safe testing]", 1, true))
    local _, matches = after:gsub("safe%-testing%.md", "")
    assert(matches == 1 and #before > 0)
  end)

  test("full-text search uses filtered local paths and literal patterns only", function()
    local saved = package.loaded["telescope.builtin"]
    local options
    package.loaded["telescope.builtin"] = { live_grep = function(value) options = value end }
    workflow.search({ { path = path }, { path = path }, { path = roots.personal .. "/b.md" } })
    assert(#options.search_dirs == 2 and options.additional_args[1] == "--fixed-strings")
    package.loaded["telescope.builtin"] = saved
  end)

  test("cancelled note creation does not create any file or directory", function()
    local select, input = vim.ui.select, vim.ui.input
    vim.ui.select = function(_, _, done) done("work") end
    local answers = { "Cancelled draft", "new-category" }
    vim.ui.input = function(_, done) done(table.remove(answers, 1)) end
    workflow.new_prompt() -- nil tag prompt cancels before create()
    assert(not vim.uv.fs_stat(roots.work .. "/new-category"))
    vim.ui.select, vim.ui.input = select, input
  end)
end, debug.traceback)

for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):sub(1, #root) == root then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end
vim.g.sprint_note_roots, vim.g.sprint_note_index_root, vim.g.sprint_note_id_state_dir = old_roots, old_index, old_ids
vim.fn.delete(root, "rf")
assert(ok, err)
print(string.format("%d local note workflow tests passed", count))

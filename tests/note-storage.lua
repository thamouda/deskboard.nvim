dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/note-storage.lua
-- Disposable vaults/state; browser launch is stubbed. No real notes/services.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.hidden = true
local notes = require("workbench.notes")
local workflow = require("workbench.note_actions")
local ids = require("workbench.note_ids")
local metadata = require("workbench.note_metadata")
local uv = vim.uv
local root = vim.fn.tempname() .. " note storage"
local roots = { personal = root .. "/personal", work = root .. "/work" }
local old = { roots = vim.g.sprint_note_roots, index = vim.g.sprint_note_index_root,
  state = vim.g.sprint_note_id_state_dir, exposed = vim.g.mkdp_open_to_the_world }
vim.g.sprint_note_roots, vim.g.sprint_note_index_root, vim.g.sprint_note_id_state_dir = roots, root, root .. "/id-state"
vim.fn.mkdir(roots.personal, "p"); vim.fn.mkdir(roots.work, "p")
local count, notices = 0, {}
vim.notify = function(value) notices[#notices + 1] = value end
local function test(name, fn) fn(); count = count + 1; print("PASS: " .. name) end
local function write(path, lines) vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p"); vim.fn.writefile(lines, path) end
local function content(path) return table.concat(vim.fn.readfile(path), "\n") end
local function info(path)
  local scope = path:sub(1, #roots.personal + 1) == roots.personal .. "/" and "personal" or "work"
  return notes.describe(path, roots[scope], scope)
end
local function answer(value)
  vim.ui.select = function(options, _, done)
    assert(options[1] == "Cancel")
    done(value)
  end
end
local select, rename = vim.ui.select, uv.fs_rename
local first, second
local ok, err = xpcall(function()
  test("NOTE IDs are sequential across work/personal and unsaved buffers", function()
    workflow.setup()
    first = assert(workflow.create({ scope = "personal", title = "First article", category = "inbox" }))
    local first_buf = vim.api.nvim_get_current_buf()
    assert(metadata.parse(vim.api.nvim_buf_get_lines(0, 0, -1, false)).uid == "NOTE-001")
    assert(not uv.fs_stat(first))
    second = assert(workflow.create({ scope = "work", title = "Second article", category = "inbox" }))
    assert(metadata.parse(vim.api.nvim_buf_get_lines(0, 0, -1, false)).uid == "NOTE-002")
    vim.cmd("write")
    vim.api.nvim_buf_call(first_buf, function() vim.cmd("write") end)
    assert(info(first).uid == "NOTE-001" and info(second).uid == "NOTE-002")
  end)

  test("allocator seeds from disk and never reuses a reserved ID", function()
    write(roots.work .. "/seed.md", { "---", "id: NOTE-010", "---", "# Existing" })
    assert(ids.next() == "NOTE-011")
    assert(ids.next() == "NOTE-012")
    write(roots.work .. "/seed.md", { "---", "id: NOTE-999", "---", "# Existing" })
    assert(ids.next() == "NOTE-1000", "Padding is at least three digits, not a 999 limit")
  end)

  test("counter identity is stable for vault aliases and newly created roots", function()
    local alias = root .. "/personal-alias"
    assert(uv.fs_symlink(roots.personal, alias))
    assert(ids.paths({ roots = { personal = alias } }) == ids.paths({ roots = { personal = roots.personal } }))
    local future = root .. "/new-parent/future-vault"
    local before = ids.paths({ roots = { work = future } })
    vim.fn.mkdir(future, "p")
    assert(ids.paths({ roots = { work = future } }) == before)
  end)

  test("busy/corrupt ID state fails closed without overwriting reservations", function()
    local path, lock = ids.paths()
    local before = content(path)
    write(lock, { "another allocator" })
    local value, reason = ids.next()
    assert(not value and reason:find("busy", 1, true) and content(path) == before)
    uv.fs_unlink(lock)
    write(path, { "invalid state" })
    value, reason = ids.next()
    assert(not value and reason:find("Invalid note ID state", 1, true) and content(path) == "invalid state")
    write(path, vim.split(before, "\n", { plain = true }))
  end)

  test("delete cancellation changes neither files, indexes nor trash", function()
    local before, index = content(first), content(root .. "/index.md")
    local called
    answer("Cancel")
    workflow.delete(info(first), function(success) called = success end)
    assert(called == false and content(first) == before and content(root .. "/index.md") == index)
    assert(not uv.fs_stat(roots.personal .. "/.trash"))
    answer(nil)
    workflow.delete(info(first))
    assert(content(first) == before)
  end)

  test("unsaved buffers block deletion instead of losing local edits", function()
    notes.open(info(first))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "UNSAVED_LOCAL_WORK" })
    vim.ui.select = function() error("Dirty notes should not even show a delete dialog") end
    local done
    workflow.delete(info(first), function(success) done = success end)
    assert(done == false and uv.fs_stat(first) and vim.bo[buf].modified)
    assert(vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] == "UNSAVED_LOCAL_WORK")
    vim.api.nvim_buf_delete(buf, { force = true }) -- discard test-only edits
  end)

  test("a file changed during confirmation is not deleted", function()
    local before = content(first)
    vim.ui.select = function(_, _, done)
      write(first, vim.split(before .. "\nExternal change", "\n", { plain = true }))
      done("Move note to trash")
    end
    local deleted
    workflow.delete(info(first), function(success) deleted = success end)
    assert(deleted == false and content(first):find("External change", 1, true))
    assert(not uv.fs_stat(roots.personal .. "/.trash"))
  end)

  test("modified indexes block deletion without touching the note", function()
    local index = roots.personal .. "/index.md"
    vim.cmd.edit(vim.fn.fnameescape(index))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "UNSAVED_INDEX_WORK" })
    local before = content(first)
    answer("Move note to trash")
    local deleted
    workflow.delete(info(first), function(success) deleted = success end)
    assert(deleted == false and content(first) == before and vim.bo[buf].modified)
    assert(not uv.fs_stat(roots.personal .. "/.trash"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test("confirmed deletion is recoverable and removes only managed index links", function()
    local before = content(first)
    local moved
    answer("Move note to trash")
    workflow.delete(info(first), function(success, path) assert(success); moved = path end)
    assert(moved and not uv.fs_stat(first) and content(moved) == before)
    local manifest = vim.json.decode(content(vim.fn.fnamemodify(moved, ":h") .. "/recovery.json"))
    assert(manifest.original_path == first and manifest.uid == "NOTE-001")
    assert(not content(root .. "/index.md"):find("personal/inbox/first-article.md", 1, true))
    assert(content(root .. "/index.md"):find("work/inbox/second-article.md", 1, true))
    for _, note in ipairs(notes.list()) do assert(note.path ~= first and note.path ~= moved) end
    local value = assert(ids.next())
    assert(tonumber(value:match("(%d+)$")) > 1000)
  end)

  test("trash IDs remain reserved if a new allocator reconstructs its state", function()
    local new_roots = { personal = root .. "/separate" }
    write(new_roots.personal .. "/.trash/old/deleted.md", { "---", "id: NOTE-050", "---", "# Deleted" })
    assert(ids.next({ roots = new_roots }) == "NOTE-051")
  end)

  test("index write failure restores the note and already-updated index content", function()
    local before = content(second)
    local paths = { roots.work .. "/inbox/index.md", roots.work .. "/index.md", root .. "/index.md" }
    local originals = {}; for _, path in ipairs(paths) do originals[path] = content(path) end
    uv.fs_rename = function(from, to)
      if to == roots.work .. "/index.md" and from:find(".tmp-", 1, true) then return nil, "simulated write failure" end
      return rename(from, to)
    end
    answer("Move note to trash")
    local deleted
    workflow.delete(info(second), function(success) deleted = success end)
    uv.fs_rename = rename
    assert(deleted == false and content(second) == before)
    for _, path in ipairs(paths) do assert(content(path) == originals[path]) end
  end)

  test("custom multi-link index rows are never removed as a whole", function()
    local index = roots.work .. "/index.md"
    local original, source = content(index), content(second)
    write(index, { "# Notes", "- [Other](unrelated.md) and [Second](inbox/second-article.md)" })
    local custom = content(index)
    answer("Move note to trash")
    local deleted
    workflow.delete(info(second), function(success) deleted = success end)
    assert(deleted == false and content(second) == source and content(index) == custom)
    write(index, vim.split(original, "\n", { plain = true }))
  end)

  test("indexes, reminders and external/symlink files cannot be deleted", function()
    answer("Move note to trash")
    local outside = root .. "/outside.md"; write(outside, { "# Not managed" })
    local index = roots.work .. "/index.md"
    local fake = { kind = "file", path = outside, root = roots.work, title = "External" }
    local deleted
    workflow.delete(fake, function(success) deleted = success end)
    assert(deleted == false and uv.fs_stat(outside))
    workflow.delete({ kind = "file", path = index, root = roots.work, title = "Index" })
    assert(uv.fs_stat(index))
    workflow.delete({ kind = "reminder", path = outside, title = "Reminder" })
    assert(uv.fs_stat(outside))
    assert(uv.fs_symlink(outside, roots.work .. "/linked.md"))
    workflow.delete({ kind = "file", path = roots.work .. "/linked.md", root = roots.work, title = "Linked" })
    assert(uv.fs_stat(outside))
  end)

  test("browser preview uses the existing local plugin without saving unsaved text", function()
    vim.g.mkdp_open_to_the_world = 0
    notes.open(info(second))
    local before, opened = content(second), 0
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "UNSAVED_BROWSER_PREVIEW" })
    vim.api.nvim_create_user_command("MarkdownPreview", function()
      opened = opened + 1
      assert(vim.bo.filetype == "markdown")
      assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("UNSAVED_BROWSER_PREVIEW", 1, true))
    end, {})
    assert(workflow.browser(info(second)) and opened == 1 and content(second) == before and vim.bo.modified)
    vim.g.mkdp_open_to_the_world = 1
    assert(not workflow.browser(info(second)) and opened == 1)
    vim.g.mkdp_open_to_the_world = 0
    vim.api.nvim_del_user_command("MarkdownPreview")
    assert(not workflow.browser(info(second)))
  end)

  test("legacy ID conversion is explicit, buffered, and retains the previous ID", function()
    local path = roots.personal .. "/legacy.md"
    write(path, { "---", "id: KB-existing", "status: draft", "visibility: private", "---", "# Legacy", "KEEP_BODY" })
    local note = info(path)
    answer("Cancel"); workflow.assign_id(note)
    assert(content(path):find("KB-existing", 1, true))
    answer("Assign new NOTE ID"); workflow.assign_id(note)
    local data = metadata.parse(vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert(data.uid:match("^NOTE%-%d%d%d%d$") and data.previous_id == "KB-existing" and vim.bo.modified)
    assert(content(path):find("id: KB-existing", 1, true))
    assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("KEEP_BODY", 1, true))
    vim.cmd("write")
    assert(info(path).uid == data.uid and info(path).previous_id == "KB-existing")
  end)
end, debug.traceback)

uv.fs_rename, vim.ui.select = rename, select
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):sub(1, #root) == root then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end
vim.g.sprint_note_roots, vim.g.sprint_note_index_root, vim.g.sprint_note_id_state_dir = old.roots, old.index, old.state
vim.g.mkdp_open_to_the_world = old.exposed
vim.fn.delete(root, "rf")
assert(ok, err)
print(string.format("%d note ID/trash/browser tests passed", count))

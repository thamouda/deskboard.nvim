-- Local-only checkbox and dashboard keymap regression tests; no real notes/CLI.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.hidden = true
local cfg = require("deskboard.config")
local reminders = require("deskboard.reminders")
local uv = vim.uv
local root = vim.fn.tempname() .. " reminders"
vim.fn.mkdir(root, "p")
local path = root .. "/reminder.md"
local count, notices = 0, {}
local notify = vim.notify
vim.notify = function(message) notices[#notices + 1] = message end
local function test(name, fn) fn(); count = count + 1; print("PASS: " .. name) end
local function write(lines) vim.fn.writefile(lines, path, "b") end
local function read() return vim.fn.readfile(path, "b") end
local function row(lnum)
  return { path = path, lnum = lnum or 1, source_line = read()[lnum or 1] }
end
local function configure(notes)
  cfg.set({ reminders = { path = path }, notes = notes or { enabled = true, allow_writes = true } })
end
local ok, err = xpcall(function()
  test("default, disabled notes and demo refuse reminder writes", function()
    write({ "- [ ] Focus", "" })
    for _, policy in ipairs({ {}, { allow_writes = true }, { enabled = true } }) do
      configure(policy)
      assert(not reminders.toggle_status(row()))
      assert(read()[1] == "- [ ] Focus")
    end
    cfg.set({ demo = true, reminders = { path = path } })
    assert(not reminders.toggle_status(row()))
  end)

  test("toggle changes only the selected marker and preserves whitespace, CRLF and permissions", function()
    configure()
    local original = { "# Captures\r", "  - [ ]  Focus ✓  \r", "- [X] Other\r", "" }
    write(original)
    uv.fs_chmod(path, 416) -- 0640
    assert(reminders.toggle_status(row(2)))
    local expected = vim.deepcopy(original); expected[2] = "  - [x]  Focus ✓  \r"
    assert(vim.deep_equal(read(), expected))
    assert(uv.fs_stat(path).mode % 512 == 416)
    assert(reminders.toggle_status(row(2)))
    assert(vim.deep_equal(read(), original))
    assert(reminders.toggle_status(row(3)))
    assert(read()[3] == "- [ ] Other\r")
  end)

  test("duplicate titles use line identity and missing final newline stays missing", function()
    write({ "- [ ] Same", "- [ ] Same" })
    assert(reminders.toggle_status(row(2)))
    assert(vim.deep_equal(read(), { "- [ ] Same", "- [x] Same" }))
  end)

  test("stale rows, text, tickets, invalid lines and other paths cannot be toggled", function()
    write({ "- [ ] Old", "# Heading", "Plain capture", "- [ ] TEST-42|To Do" })
    local stale = row()
    write({ "- [ ] New", "# Heading", "Plain capture", "- [ ] TEST-42|To Do" })
    local before = read()
    assert(not reminders.toggle_status(stale))
    for _, lnum in ipairs({ 2, 3, 4 }) do assert(not reminders.toggle_status(row(lnum))) end
    assert(not reminders.toggle_status({ path = path, lnum = 0, source_line = before[1] }))
    assert(not reminders.toggle_status({ path = root .. "/other.md", lnum = 1, source_line = before[1] }))
    assert(not reminders.toggle_status(nil))
    assert(vim.deep_equal(read(), before))
  end)

  test("unsaved and read-only source buffers are protected; clean buffers refresh", function()
    write({ "- [ ] Focus", "" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    local selected = row()
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "UNSAVED" })
    assert(not reminders.toggle_status(selected))
    assert(vim.bo[buf].modified and vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "UNSAVED")
    assert(read()[1] == "- [ ] Focus")
    vim.cmd("edit!")
    vim.bo[buf].readonly = true
    assert(not reminders.toggle_status(selected))
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = false
    assert(not reminders.toggle_status(selected))
    vim.bo[buf].modifiable = true
    vim.bo[buf].autoread = false
    assert(reminders.toggle_status(selected))
    assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "- [x] Focus")
    assert(not vim.bo[buf].modified and not vim.bo[buf].autoread)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test("symlink sources, failed saves and concurrent writes leave source data safe", function()
    write({ "- [ ] Focus", "" })
    local alias = root .. "/alias.md"
    assert(uv.fs_symlink(path, alias))
    cfg.set({ reminders = { path = alias }, notes = { enabled = true, allow_writes = true } })
    assert(not reminders.toggle_status({ path = alias, lnum = 1, source_line = "- [ ] Focus" }))
    configure()
    local rename, fs_write = uv.fs_rename, uv.fs_write
    uv.fs_rename = function() return nil, "fixture failure" end
    assert(not reminders.toggle_status(row()))
    uv.fs_rename = rename
    assert(read()[1] == "- [ ] Focus")
    uv.fs_write = function(...)
      local result = fs_write(...)
      write({ "- [ ] Concurrent update", "" })
      return result
    end
    assert(not reminders.toggle_status(row()))
    uv.fs_write = fs_write
    assert(read()[1] == "- [ ] Concurrent update")
    assert(#vim.fn.glob(path .. ".tmp-*", false, true) == 0)
  end)

  test("dashboard x toggles the selected reminder, refreshes counts and keeps page/selection", function()
    configure()
    write({ "# Captures", "- [ ] One", "- [ ] Two", "- [x] Three", "" })
    local adapter = require("deskboard.adapter")
    local views = require("deskboard.views")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local owner = { buf = buf, win = vim.api.nvim_get_current_win(), opts = {} }
    function owner:find(pos)
      for _, item in ipairs(self.items or {}) do if item._ and item._.row == pos[1] then return item end end
    end
    function owner:update()
      self.items, self.lines = adapter.sections(self), {}
      for _, item in ipairs(self.items) do
        if item.text then
          local chunks = {}; for _, part in ipairs(item.text) do chunks[#chunks + 1] = part[1] end
          self.lines[#self.lines + 1] = table.concat(chunks)
          item._ = { row = #self.lines }
        end
      end
      vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, self.lines)
      vim.api.nvim_exec_autocmds("User", { pattern = "SnacksDashboardUpdatePost" })
      vim.wait(10, function() return false end)
    end
    local state = views.get({ buf = buf, page_size = 2 })
    state:switch("reminders")
    state.pages.reminders = 2
    owner:update()
    local selected
    for _, item in ipairs(owner.items) do if item.reminder then selected = item; break end end
    assert(selected.reminder_data.lnum == 3 and not selected.note_data)
    vim.api.nvim_win_set_cursor(owner.win, { selected._.row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    vim.wait(10, function() return false end)
    local function key() vim.fn.maparg("x", "n", false, true).callback() end
    key()
    assert(read()[3] == "- [x] Two" and read()[2] == "- [ ] One")
    assert(state.pages.reminders == 2 and state:selection() == selected.id)
    assert(owner:find(vim.api.nvim_win_get_cursor(owner.win)).id == selected.id)
    assert(table.concat(owner.lines, "\n"):find("2 open · 2 done", 1, true))
    key()
    assert(read()[3] == "- [ ] Two")
    configure({ enabled = true, allow_writes = false })
    key(); assert(read()[3] == "- [ ] Two")
    adapter.dispose(); require("deskboard.preview").dispose()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end, debug.traceback)
vim.notify = notify
vim.fn.delete(root, "rf")
assert(ok, err)
print(string.format("%d reminder toggle tests passed", count))

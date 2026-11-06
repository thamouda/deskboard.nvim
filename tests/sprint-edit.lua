dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/sprint-edit.lua
-- ALL Jira commands, including edits, are mocked. Never touches real tickets.
vim.opt.rtp:prepend(vim.fn.getcwd())
local edit = require("workbench.jira_edit")
local root, serial, count = vim.fn.tempname() .. " Jira draft tests", 0, 0
local fixtures, messages = {}, {}
vim.notify = function(message)
  messages[#messages + 1] = message
end

local function wait()
  vim.wait(15, function()
    return false
  end, 5)
end
local function has_message(part)
  return table.concat(messages, "\n"):find(part, 1, true) ~= nil
end
local function cleanup()
  for _, f in ipairs(fixtures) do
    if f.e then
      f.e.phase = "ready"
      if not f.e:close() then
        f.e.base = nil
        f.e:close()
      end
    end
  end
  fixtures = {}
  wait()
end
local function test(name, fn)
  messages = {}
  local previous = vim.v.errmsg
  fn()
  wait()
  assert(vim.v.errmsg == previous, vim.v.errmsg)
  cleanup()
  count = count + 1
  print("PASS: " .. name)
end

local function fixture(opts)
  serial = serial + 1
  local f = { key = "TEST-" .. (9000 + serial), calls = {}, dialogs = {}, refreshed = 0 }
  f.server = {
    key = f.key,
    fields = {
      summary = "Original title",
      description = 'h2. Details\n\n{code:perl}\n    print "original";\n{code}\n',
      status = { name = "To review" },
      assignee = { displayName = "Example reviewer" },
    },
  }
  f.opts = vim.tbl_extend("force", {
    draft_dir = root .. "/draft " .. serial,
    preview_opts = { glow = false },
    run = function(cmd, options, done)
      local call = { cmd = cmd, opts = options, done = done }
      f.calls[#f.calls + 1] = call
      return {
        kill = function()
          call.killed = true
        end,
      }
    end,
    select = function(items, options, done)
      f.dialogs[#f.dialogs + 1] = { items = items, opts = options, done = done }
    end,
    on_success = function(key)
      assert(key == f.key)
      f.refreshed = f.refreshed + 1
    end,
  }, opts or {})
  function f.open()
    f.e = edit.open({ ticket = f.key }, f.opts)
    return f.e
  end
  function f.respond(index, body, code, stderr)
    f.calls[index].done({
      code = code or 0,
      stdout = type(body) == "string" and body or vim.json.encode(body),
      stderr = stderr,
    })
    wait()
  end
  function f.get(index)
    f.respond(index or #f.calls, f.server)
  end
  function f.ready()
    f.get()
    assert(f.e.phase == "ready", f.e.phase)
  end
  function f.set(title, body)
    local lines = { title, "" }
    vim.list_extend(lines, vim.split(body == nil and f.server.fields.description or body, "\n", { plain = true }))
    vim.api.nvim_buf_set_lines(f.e.buf, 0, -1, false, lines)
  end
  function f.value()
    return assert(edit.parse(vim.api.nvim_buf_get_lines(f.e.buf, 0, -1, false)))
  end
  function f.choose(index)
    local d = f.dialogs[#f.dialogs]
    assert(d, "Missing confirmation")
    d.done(index and d.items[index] or nil)
    wait()
  end
  function f.preflight()
    assert(f.e:publish())
    assert(f.e.phase == "confirming")
    f.choose(2)
    assert(f.e.phase == "checking")
    f.get()
  end
  function f.finish(title, body, code)
    if title then
      f.server.fields.summary = title
    end
    if body then
      f.server.fields.description = body
    end
    f.respond(#f.calls, "CLI finished", code or 0)
    assert(f.e.phase == "verifying")
    f.get()
  end
  function f.edits()
    local n = 0
    for _, call in ipairs(f.calls) do
      if call.cmd[3] == "edit" then
        n = n + 1
      end
    end
    return n
  end
  function f.saved()
    return vim.json.decode(table.concat(vim.fn.readfile(f.e.path), "\n"))
  end
  fixtures[#fixtures + 1] = f
  f.open()
  return f
end

local ok, err = xpcall(function()
  test("loads exact original wiki text into a titled editable draft", function()
    local f = fixture()
    f.ready()
    assert(f.value().summary == f.server.fields.summary)
    assert(f.value().description == f.server.fields.description)
    assert(vim.bo[f.e.buf].buftype == "acwrite" and vim.bo[f.e.buf].filetype == "jira")
    assert(vim.bo[f.e.buf].modifiable)
    assert(f.edits() == 0 and #f.calls == 1)
    assert(vim.fn.filereadable(f.e.path) == 0)
    assert(vim.deep_equal(f.calls[1].cmd, { "jira", "issue", "view", f.key, "--raw" }))
  end)

  test("draft format validates title, separator, Unicode length and NUL", function()
    assert(not edit.parse({ "", "", "body" }))
    assert(not edit.parse({ "title", "not blank", "body" }))
    assert(not edit.parse({ string.rep("長", 256), "", "body" }))
    assert(edit.parse({ string.rep("長", 255), "", "body" }))
    assert(not edit.parse({ "title", "", "body\0invalid" }))
    assert(edit.parse({ "title", "" }).description == "")
  end)

  test(":w saves a private local draft, never publishes, even with shell-looking text", function()
    local f = fixture()
    f.ready()
    local body = 'h2. Keep raw\n{code:perl}\nprint "$(touch /tmp/not-executed)";\n{code}\n'
    f.set('Title "quotes"; $(nothing)', body)
    vim.api.nvim_buf_call(f.e.buf, function()
      vim.cmd("write")
    end)
    assert(f.edits() == 0 and #f.calls == 1)
    local saved = f.saved()
    assert(saved.lines[1] == 'Title "quotes"; $(nothing)')
    assert(edit.parse(saved.lines).description == body)
    assert(saved.base.description == f.server.fields.description)
    assert(vim.uv.fs_stat(f.e.path).mode % 512 == 384)
    assert(vim.uv.fs_stat(f.e.dir).mode % 512 == 448)
    assert(has_message("not published"))
  end)

  test("closing and reopening offers resume without overwriting local work", function()
    local f = fixture()
    f.ready()
    f.set("Local title")
    local path = f.e.path
    assert(f.e:close())
    assert(vim.fn.filereadable(path) == 1)
    f.open()
    f.get()
    assert(f.e.phase == "resuming")
    f.choose(1)
    assert(f.value().summary == "Local title" and f.e.base.summary == "Original title")
    assert(f.edits() == 0)
  end)

  test("discarding a saved draft requires an explicit selection", function()
    local f = fixture()
    f.ready()
    f.set("Local title")
    f.e:close()
    f.server.fields.summary = "Latest Jira title"
    f.open()
    f.get()
    f.choose(2)
    assert(f.value().summary == "Latest Jira title")
    assert(vim.fn.filereadable(f.e.path) == 0 and f.edits() == 0)
  end)

  test("cancelled resume keeps the saved draft; cancelled load ignores late results", function()
    local f = fixture()
    f.ready()
    f.set("Local title")
    f.e:close()
    f.open()
    f.get()
    local path = f.e.path
    f.choose(nil)
    assert(not f.e:valid() and vim.fn.filereadable(path) == 1)
    local other = fixture()
    assert(other.e:close() and other.calls[1].killed)
    other.get(1)
    assert(not other.e:valid() and other.edits() == 0)
  end)

  test("draft Glow preview has no Jira/GL API requests and q returns to editor", function()
    local f = fixture()
    f.ready()
    f.set("Draft title", '{code:perl}\n    print "draft";\n{code}')
    f.e:preview()
    assert(f.e.popup and f.e.popup:is_open())
    local text = table.concat(vim.api.nvim_buf_get_lines(f.e.popup.buf, 0, -1, false), "\n")
    assert(text:find("NOT PUBLISHED", 1, true) and text:find("```perl", 1, true))
    assert(text:find("Draft title", 1, true))
    assert(#f.calls == 1 and f.edits() == 0)
    vim.fn.maparg("q", "n", false, true).callback()
    assert(not f.e.popup:is_open() and f.e:valid())
    assert(vim.api.nvim_get_current_win() == f.e.win)
    assert(f.value().summary == "Draft title")
  end)

  test("unchanged drafts never create updates or stale saved drafts", function()
    local f = fixture()
    f.ready()
    assert(not f.e:publish())
    assert(f.e:save(true))
    assert(#f.dialogs == 0 and #f.calls == 1 and vim.fn.filereadable(f.e.path) == 0)
  end)

  test("title-only publish confirms, preflights, sends only summary, verifies and refreshes", function()
    local f = fixture()
    f.ready()
    f.set("Updated title")
    assert(f.e:publish())
    assert(#f.calls == 1 and f.dialogs[1].items[1] == "Cancel")
    f.choose(2)
    f.get()
    local call = f.calls[#f.calls]
    assert(vim.deep_equal(call.cmd, { "jira", "issue", "edit", f.key, "--no-input", "--summary", "Updated title" }))
    assert(call.opts.stdin == nil)
    assert(not f.e:publish() and f.edits() == 1)
    f.finish("Updated title")
    assert(f.refreshed == 1 and f.e.base.summary == "Updated title")
    assert(f.value().description == f.server.fields.description)
    local path = f.e.path
    assert(vim.fn.filereadable(path) == 0)
    f.e:close()
    assert(vim.fn.filereadable(path) == 0, "Closing a published draft must not recreate it")
  end)

  test("description-only publish sends exact wiki through stdin, never through a shell", function()
    local f = fixture()
    f.ready()
    local body = 'h2. Revised\n{code:perl}\nprint "quotes: \\"; $(nothing)";\n{code}\n'
    f.set("Original title", body)
    f.preflight()
    local call = f.calls[#f.calls]
    assert(vim.deep_equal(call.cmd, { "jira", "issue", "edit", f.key, "--no-input" }))
    assert(call.opts.stdin == body and call.opts.timeout == 30000)
    f.finish(nil, body)
    assert(f.refreshed == 1 and f.value().description == body)
  end)

  test("changing title and description sends only that confirmed snapshot", function()
    local f = fixture()
    f.ready()
    f.set("New title", "h2. New description")
    f.preflight()
    assert(f.calls[#f.calls].cmd[#f.calls[#f.calls].cmd] == "New title")
    assert(f.calls[#f.calls].opts.stdin == "h2. New description")
    f.finish("New title", "h2. New description")
    assert(f.refreshed == 1)
  end)

  test("cancelled confirmation never issues a preflight or update", function()
    local f = fixture()
    f.ready()
    f.set("Local title")
    assert(f.e:publish())
    f.choose(1)
    assert(f.e.phase == "ready" and #f.calls == 1 and f.edits() == 0)
    assert(vim.fn.filereadable(f.e.path) == 1)
    assert(f.e:publish())
    f.choose(nil)
    assert(#f.calls == 1)
  end)

  test("a concurrent Jira edit blocks the changed field rather than overwriting it", function()
    local f = fixture()
    f.ready()
    f.set("Local title")
    f.server.fields.summary = "Changed in browser"
    f.preflight()
    assert(f.e.phase == "ready" and f.edits() == 0 and f.refreshed == 0)
    assert(has_message("Conflict: summary"))
    assert(f.value().summary == "Local title" and vim.fn.filereadable(f.e.path) == 1)
  end)

  test("remote changes to untouched fields are preserved", function()
    local f = fixture()
    f.ready()
    f.set("Local title")
    f.server.fields.description = "h2. Updated in browser"
    f.preflight()
    assert(f.calls[#f.calls].opts.stdin == nil)
    f.finish("Local title")
    assert(f.value().description == "h2. Updated in browser")
    assert(f.refreshed == 1)
  end)

  test("remote already matches the draft: reconcile without a duplicate mutation", function()
    local f = fixture()
    f.ready()
    f.set("Already sent title")
    f.server.fields.summary = "Already sent title"
    f.preflight()
    assert(f.e.phase == "ready" and f.edits() == 0 and f.refreshed == 1)
    assert(has_message("already up to date"))
  end)

  test("edits after confirmation or during preflight abort before mutation", function()
    local f = fixture()
    f.ready()
    f.set("Confirmed title")
    assert(f.e:publish())
    f.set("Newer local title")
    f.choose(2)
    assert(#f.calls == 1 and f.edits() == 0)
    assert(has_message("Draft changed after confirmation"))
    assert(f.e:publish())
    f.choose(2)
    f.set("Even newer title")
    f.get()
    assert(f.edits() == 0 and f.value().summary == "Even newer title")
    assert(has_message("Draft changed or closed"))
  end)

  test("edits typed during publication remain an unpublished local draft", function()
    local f = fixture()
    f.ready()
    f.set("Published snapshot")
    f.preflight()
    f.set("New local edits")
    assert(not f.e:close(), "Do not pretend an already sent publication can be cancelled")
    f.finish("Published snapshot")
    assert(f.refreshed == 1 and f.e.base.summary == "Published snapshot")
    assert(f.value().summary == "New local edits")
    assert(f.saved().base.summary == "Published snapshot")
    assert(f.saved().lines[1] == "New local edits")
  end)

  test("timed-out update is verified, not retried automatically", function()
    local f = fixture()
    f.ready()
    f.set("Server accepted title")
    f.preflight()
    f.finish("Server accepted title", nil, 124)
    assert(f.refreshed == 1 and f.edits() == 1)
  end)

  test("failed update preserves local data and hides raw CLI credentials", function()
    local f = fixture()
    f.ready()
    f.set("Keep this title")
    f.preflight()
    f.respond(#f.calls, "private-secret", 1, "HTTP 401 private-secret")
    f.get()
    assert(f.refreshed == 0 and f.edits() == 1)
    assert(has_message("HTTP 401") and not has_message("private-secret"))
    assert(vim.fn.filereadable(f.e.path) == 1 and f.value().summary == "Keep this title")
  end)

  test("unverified success is not claimed or retried and keeps the draft", function()
    local f = fixture()
    f.ready()
    f.set("Requested title")
    f.preflight()
    f.respond(#f.calls, "OK", 0)
    f.respond(#f.calls, "", 1, "HTTP 401")
    assert(f.refreshed == 0 and f.edits() == 1 and f.e.phase == "ready")
    assert(has_message("Update sent, but read-back did not confirm"))
    assert(vim.fn.filereadable(f.e.path) == 1)
  end)

  test("preflight authentication failure cannot issue any update", function()
    local f = fixture()
    f.ready()
    f.set("Local title")
    assert(f.e:publish())
    f.choose(2)
    f.respond(#f.calls, "", 1, "HTTP 403 Forbidden")
    assert(f.edits() == 0 and f.refreshed == 0)
    assert(has_message("HTTP 403"))
  end)

  test("accidental empty-description replacement is blocked", function()
    local f = fixture()
    f.ready()
    f.set("Original title", "")
    assert(not f.e:publish())
    assert(#f.dialogs == 0 and #f.calls == 1)
    assert(has_message("Empty descriptions are not published"))
  end)

  test("ADF is not flattened on load; malformed or unauthorized responses stay read-only", function()
    for _, value in ipairs({ { type = "doc", content = {} }, false }) do
      local f = fixture()
      f.server.fields.description = value
      f.get()
      assert(f.e.phase == "error" and not vim.bo[f.e.buf].modifiable)
      assert(not f.e:publish() and f.edits() == 0)
      f.e:close()
    end
    local f = fixture()
    f.respond(1, "", 1, "HTTP 401 secret")
    assert(f.e.phase == "error" and not has_message("secret"))
  end)

  test("null Jira description is a valid initially empty draft", function()
    local f = fixture()
    f.server.fields.description = vim.NIL
    f.get()
    assert(f.e.phase == "ready" and f.value().description == "")
  end)

  test("failed local save stops publication without losing the buffer", function()
    local file = root .. "/not-a-directory"
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "file" }, file)
    local f = fixture({ draft_dir = file })
    f.ready()
    f.set("Keep local title")
    assert(not f.e:publish())
    assert(#f.dialogs == 0 and f.edits() == 0 and f.e:valid())
    assert(has_message("Could not save private draft"))
    f.e.base = nil -- Test cleanup must not try to write to the intentionally bad path.
  end)

  test("reopening E reuses the dirty buffer; invalid keys never spawn requests", function()
    local f = fixture()
    f.ready()
    f.set("Unsaved work")
    assert(edit.open({ ticket = f.key }, f.opts) == f.e)
    assert(f.value().summary == "Unsaved work" and #f.calls == 1)
    assert(edit.open({ ticket = "TEST-1; touch nope" }, f.opts) == nil)
    assert(edit.open(nil, f.opts) == nil)
  end)

  test("wiping a publishing buffer still verifies the sent snapshot", function()
    local f = fixture()
    f.ready()
    f.set("Sent title")
    f.preflight()
    local path = f.e.path
    vim.api.nvim_buf_delete(f.e.buf, { force = true })
    wait()
    assert(not f.e:valid())
    f.finish("Sent title")
    assert(f.refreshed == 1 and f.edits() == 1)
    assert(vim.fn.filereadable(path) == 0)
  end)
end, debug.traceback)
cleanup()
vim.fn.delete(root, "rf")
assert(ok, err)
print(("All %d Jira draft tests passed (no live ticket writes)"):format(count))

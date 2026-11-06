dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/sprint-sync.lua
-- Disposable files and mocked commands only: never runs the real sync script.
vim.opt.rtp:prepend(vim.fn.getcwd())
local sync = require("deskboard.sync")
local root, count, serial = vim.fn.tempname() .. " sync tests", 0, 0
vim.fn.mkdir(root, "p")
vim.notify = function() end
local events = 0
vim.api.nvim_create_autocmd("User", {
  pattern = "SprintBoardRefreshPost",
  callback = function()
    events = events + 1
  end,
})

local function test(name, fn)
  fn()
  count = count + 1
  print("PASS: " .. name)
end

local function fixture()
  serial = serial + 1
  local dir = root .. "/" .. serial
  vim.fn.mkdir(dir, "p")
  local script, reminder, state = dir .. "/sync script", dir .. "/reminder.md", dir .. "/state.json"
  vim.fn.writefile({ "#!/bin/sh", "exit 0" }, script)
  vim.uv.fs_chmod(script, 493)
  vim.fn.writefile({ "Personal notes", "- [ ] TEST-1|To Do" }, reminder)
  vim.uv.fs_utime(reminder, 100, 100)
  local calls, clock, changes = {}, 1000, 0
  local options = {
    script = script,
    reminder = reminder,
    state_file = state,
    now = function()
      return clock
    end,
    changed = function()
      changes = changes + 1
    end,
    run = function(cmd, opts, done)
      assert(vim.deep_equal(cmd, { script }))
      assert(opts.timeout == 180000)
      calls[#calls + 1] = done
      return { kill = function() end }
    end,
  }
  local instance = sync.new(options)
  return {
    instance = instance,
    options = options,
    reminder = reminder,
    state = state,
    calls = calls,
    set_clock = function(value)
      clock = value
    end,
    changes = function()
      return changes
    end,
    write = function()
      vim.fn.writefile({ "Personal notes", "- [x] TEST-1|Done" }, reminder)
      vim.uv.fs_utime(reminder, 200, 200)
    end,
    finish = function(code, report)
      calls[#calls]({ code = code, stdout = report and vim.json.encode(report) or "" })
      assert(vim.wait(1000, function()
        return not instance.running
      end))
    end,
  }
end

local ok, err = xpcall(function()
  test("legacy reminders show approximate elapsed age; no history is labelled never", function()
    local f = fixture()
    assert(f.instance:status().text == "Last refresh: ~15m ago · R refresh")
    assert(f.instance:status().estimated)
    vim.fn.delete(f.reminder)
    assert(sync.new(f.options):status().text == "Last refresh: never · R refresh")
  end)

  test("manual refresh is asynchronous, guarded, and persists verified success", function()
    local f, before = fixture(), events
    assert(f.instance:refresh({ silent = true }))
    assert(f.instance:status().running)
    assert(not f.instance:refresh({ silent = true }))
    assert(#f.calls == 1 and f.changes() == 1)
    f.write()
    f.finish(0)
    assert(f.instance.last_success == 1000)
    assert(f.changes() == 2 and events == before + 1)
    assert(f.instance:status().text:find("Last refresh: just now", 1, true))
    assert(not f.instance:status().estimated)
    assert(sync.new(f.options).last_success == 1000)
    f.set_clock(1180)
    assert(f.instance:status().text:find("Last refresh: 3m ago", 1, true))
    f.set_clock(1900)
    assert(f.instance:status().stale)
  end)

  test("failed/no-op refresh keeps elapsed age, without an offline/unverified banner", function()
    local f, before = fixture(), events
    local content = vim.fn.readfile(f.reminder)
    f.instance:refresh({ silent = true })
    f.finish(0)
    assert(f.instance.last_success == nil)
    assert(f.instance:status().error)
    assert(f.instance:status().text == "Last refresh: ~15m ago · R refresh")
    assert(not f.instance:status().text:find("offline", 1, true))
    assert(not f.instance:status().text:find("unverified", 1, true))
    assert(vim.deep_equal(content, vim.fn.readfile(f.reminder)))
    assert(events == before)
  end)

  test("failed refresh retains last successful timestamp and supports retry", function()
    local f = fixture()
    f.instance:refresh({ silent = true })
    f.write()
    f.finish(0)
    f.set_clock(1180)
    f.instance:refresh({ silent = true })
    f.finish(1)
    assert(f.instance.last_success == 1000 and f.instance.last_error)
    assert(f.instance:status().text == "Last refresh: 3m ago · R refresh")
    assert(f.instance:refresh({ silent = true }))
    assert(#f.calls == 3)
    vim.uv.fs_utime(f.reminder, 300, 300)
    f.finish(0)
    assert(f.instance.last_success == 1180 and not f.instance.last_error)
  end)

  test("timeout, missing executable, spawn failure, corrupt state are handled", function()
    local f = fixture()
    f.instance:refresh({ silent = true })
    f.finish(124)
    assert(f.instance.last_error == "Refresh timed out")
    vim.fn.delete(f.options.script)
    assert(not f.instance:refresh({ silent = true }))
    assert(f.instance.last_error:find("missing", 1, true))
    vim.fn.writefile({ "not json" }, f.state)
    assert(sync.new(f.options).last_success == nil)
    f.options.script = "/bin/true"
    f.options.run = function()
      error("spawn failure")
    end
    local broken = sync.new(f.options)
    assert(not broken:refresh({ silent = true }))
    assert(not broken.running and broken.last_error)
  end)

  test("editing notes does not erase last-refresh history; state write failure is nonfatal", function()
    local f = fixture()
    f.instance:refresh({ silent = true })
    f.write()
    f.finish(0)
    vim.uv.fs_utime(f.reminder, 300, 300)
    assert(sync.new(f.options).last_success == 1000)
    f.set_clock(1180)
    assert(sync.new(f.options):status().text == "Last refresh: 3m ago · R refresh")
    vim.fn.delete(f.state)
    vim.fn.mkdir(f.state)
    f.instance:refresh({ silent = true })
    vim.uv.fs_utime(f.reminder, 400, 400)
    f.finish(0)
    assert(f.instance.last_success and not f.instance.last_error)
  end)

  test("age labels handle hours, days and future timestamps", function()
    local f = fixture()
    f.instance.last_success = 1000
    f.set_clock(4600)
    assert(f.instance:status().text:find("1h ago", 1, true))
    f.set_clock(9100)
    assert(f.instance:status().text:find("2h 15m ago", 1, true))
    f.set_clock(87400)
    assert(f.instance:status().text:find("1d ago", 1, true))
    f.set_clock(181000)
    assert(f.instance:status().text:find("2d 2h ago", 1, true))
    f.set_clock(900)
    assert(f.instance:status().text:find("just now", 1, true))
  end)

  test("structured partial refresh advances age and preserves source freshness across restarts", function()
    local f = fixture()
    f.instance:refresh({ silent = true })
    f.write()
    f.finish(0, {
      version = 1,
      ok = true,
      sources = { jira = false, gitlab = true },
      warnings = { "Jira authentication failed (HTTP 401)" },
    })
    assert(f.instance.last_success == 1000 and not f.instance.last_error)
    assert(f.instance:status().text == "Last refresh: just now · Jira stale · R refresh")
    assert(sync.new(f.options):status().sources.jira == false)
    assert(f.instance.warnings[1]:find("401", 1, true))
  end)

  test("backend failure report explains authentication problems without resetting age", function()
    local f = fixture()
    f.instance:refresh({ silent = true })
    f.finish(1, { version = 1, ok = false, warnings = { "Jira authentication failed (HTTP 401)" } })
    assert(f.instance.last_error == "Jira authentication failed (HTTP 401)")
    assert(not f.instance.last_success)
    assert(f.instance:status().text == "Last refresh: ~15m ago · R refresh")
  end)

  test("startup setup and command are idempotent without running real sync", function()
    local original, calls = sync.refresh, 0
    sync.refresh = function()
      calls = calls + 1
    end
    sync.setup()
    sync.setup()
    assert(vim.fn.exists(":SprintBoardRefresh") == 2)
    vim.cmd("SprintBoardRefresh")
    assert(calls == 1)
    assert(#vim.api.nvim_get_autocmds({ group = "deskboard_sync", event = "VimLeavePre" }) == 1)
    vim.wait(350, function()
      return false
    end, 10)
    -- Explicit cleanup before restoring the real function; no deferred startup
    -- callback in this -l test is permitted to reach the actual script.
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    vim.api.nvim_del_augroup_by_name("deskboard_sync")
    sync.refresh = original
  end)
end, debug.traceback)
vim.fn.delete(root, "rf")
assert(ok, err)
print(("All %d sprint sync tests passed"):format(count))

dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/dashboard-clock.lua
-- Pure clock fixtures and mocked dashboard integration; no real CLI/network.
vim.opt.rtp:prepend(vim.fn.getcwd())
local clock = require("workbench.clock")
local locale = os.setlocale(nil, "time")
os.setlocale("C", "time")
local count = 0
local function test(name, fn)
  fn()
  count = count + 1
  print("PASS: " .. name)
end
local function timestamp(hour, minute, day)
  return os.time({ year = 2026, month = 11, day = day or 5, hour = hour or 18, min = minute or 4, sec = 0 })
end
local function text(item)
  local parts = {}
  for _, part in ipairs(item.text) do parts[#parts + 1] = part[1] end
  return table.concat(parts)
end
local function all_text(items)
  local lines = {}
  for _, item in ipairs(items) do lines[#lines + 1] = text(item) end
  return table.concat(lines, "\n")
end
local function contains(value, wanted)
  assert(value:find(wanted, 1, true), "Missing " .. wanted .. " in " .. value)
end

test("the header shows only local 24-hour time, timezone, and readable date", function()
  local now = timestamp()
  local items = clock.render({ now = now })
  assert(#items == 2)
  local value = all_text(items)
  contains(value, "18:04")
  contains(value, "Thursday · 5 November 2026")
  contains(value, os.date("%Z", now))
  assert(not value:find("November 05", 1, true))
  for _, item in ipairs(items) do
    assert(item.align == "center")
    assert(vim.api.nvim_strwidth(text(item)) <= 44)
  end
end)

test("borders, icons, and greetings are absent at every time of day", function()
  for hour = 0, 23 do
    local value = all_text(clock.render({ now = timestamp(hour) }))
    assert(not value:find("Good ", 1, true))
    for _, decoration in ipairs({ "╭", "╮", "╰", "╯", "│", "─", "󰥔" }) do
      assert(not value:find(decoration, 1, true))
    end
  end
end)

test("midnight updates the day and date instead of keeping a startup snapshot", function()
  local before = all_text(clock.render({ now = timestamp(23, 59, 5) }))
  local after = all_text(clock.render({ now = timestamp(0, 0, 6) }))
  contains(before, "23:59")
  contains(before, "Thursday · 5 November 2026")
  contains(after, "00:00")
  contains(after, "Friday · 6 November 2026")
end)

test("every window width gets complete UTF-8 lines within its available cells", function()
  for limit = 1, 100 do
    local items = clock.render({ width = limit, now = timestamp(12) })
    assert(#items == 2)
    for _, item in ipairs(items) do
      local value = text(item)
      assert(vim.api.nvim_strwidth(value) <= math.min(limit, 44), "Overflow at width " .. limit)
      assert(vim.str_utfindex(value) ~= nil)
    end
  end
  contains(all_text(clock.render({ width = 24, now = timestamp() })), "Thu · 5 Nov 2026")
  contains(all_text(clock.render({ width = 12, now = timestamp() })), "05/11/2026")
  contains(all_text(clock.render({ width = 12, now = timestamp() })), "18:04")
end)

test("inline title-bar clock is compact, right-alignable and uses local date/time", function()
  local now = timestamp()
  for limit = 5, 80 do
    local value = text({ text = clock.inline({ now = now, width = limit }) })
    contains(value, "18:04")
    assert(vim.api.nvim_strwidth(value) <= limit)
    assert(not value:find("\n", 1, true))
  end
  contains(text({ text = clock.inline({ now = now, width = 80 }) }), "Thu 05 Nov 2026")
end)

test("the date and time use the dashboard palette and create no timer or process", function()
  local new_timer, system = vim.uv.new_timer, vim.system
  vim.uv.new_timer = function() error("Clock rendering must not start a timer") end
  vim.system = function() error("Clock rendering must not launch a process") end
  local ok, result = pcall(clock.render, { now = timestamp() })
  vim.uv.new_timer, vim.system = new_timer, system
  assert(ok, result)
  local highlighted_time = false
  for _, item in ipairs(result) do
    for _, part in ipairs(item.text) do
      assert(part.hl:match("^Workbench"))
      if part[1] == "18:04" then highlighted_time = part.hl == "WorkbenchAccent" end
    end
  end
  assert(highlighted_time)
end)

test("the existing refresh timer is minute-aligned, idempotent, and redraw-only", function()
  local core = require("workbench")
  local adapter = require("workbench.adapter")
  local old_redraw = adapter.redraw
  local cfg = require("workbench.config").get()
  local sync = require("workbench.sync")
  local new_timer, defer, date, refresh, snacks = vim.uv.new_timer, vim.defer_fn, os.date, sync.refresh, _G.Snacks
  local timers, redraws = {}, 0
  vim.uv.new_timer = function()
    local timer = {
      start = function(self, delay, interval, callback)
        self.delay, self.interval, self.callback = delay, interval, callback
      end,
      stop = function(self) self.stopped = true end,
      close = function(self) self.closed = true end,
      is_closing = function(self) return self.closed or false end,
    }
    timers[#timers + 1] = timer
    return timer
  end
  vim.defer_fn = function() end -- do not schedule the real startup sync
  os.date = function(format, now)
    if format == "*t" and not now then return { sec = 17 } end
    return date(format, now)
  end
  sync.refresh = function() error("A clock redraw must not fetch Jira") end
  adapter.redraw = function() redraws = redraws + 1 end
  local ok, err = xpcall(function()
    core.setup(cfg)
    assert(timers[1].delay == 43000 and timers[1].interval == 60000)
    timers[1].callback()
    assert(vim.wait(100, function() return redraws == 1 end))
    core.setup(cfg)
    assert(#timers == 2 and timers[1].stopped and timers[1].closed)
    assert(#vim.api.nvim_get_autocmds({ group = "workbench_lifecycle", event = "VimLeavePre" }) == 1)
    vim.api.nvim_exec_autocmds("VimLeavePre", { group = "workbench_lifecycle" })
    assert(timers[2].stopped and timers[2].closed)
    pcall(vim.api.nvim_del_augroup_by_name, "workbench_lifecycle")
  end, debug.traceback)
  adapter.redraw = old_redraw
  vim.uv.new_timer, vim.defer_fn, os.date, sync.refresh, _G.Snacks = new_timer, defer, date, refresh, snacks
  assert(ok, err)
end)

test("the dashboard has tabs but no standalone clock or ASCII logo", function()
  local names = { "workbench.board", "workbench.preview", "workbench.sync", "lazyvim.config" }
  local saved = {}
  for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  package.loaded["workbench.board"] = { width = 124, setup_highlights = function() end,
    frame = function() return {} end, render = function() return {} end }
  package.loaded["workbench.preview"] = { attach = function() return {} end }
  package.loaded["workbench.sync"] = { status = function() return {} end }
  package.loaded["lazyvim.config"] = { icons = { kinds = {} } }
  local open, systemlist = io.open, vim.fn.systemlist
  io.open = function(path, mode)
    if path == require("workbench.config").get().reminders.path then return nil end
    return open(path, mode)
  end
  vim.fn.systemlist = function() return {} end
  local ok, err = xpcall(function()
    local sections = require("workbench.adapter").sections
    assert(sections)
    local items = sections({ buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(), opts = {} })
    contains(text(items[1]), "My tickets")
    assert(items[2].section == "startup")
    assert(not text(items[1]):find(os.date("%H:%M"), 1, true))
    for _, item in ipairs(items) do
      assert(item.hl ~= "SnacksDashboardHeader", "The ASCII logo must not be rendered")
    end
  end, debug.traceback)
  io.open, vim.fn.systemlist = open, systemlist
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  assert(ok, err)
end)

os.setlocale(locale, "time")
print(string.format("%d dashboard clock tests passed", count))

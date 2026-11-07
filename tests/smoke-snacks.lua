-- Optional real UI smoke. Set DESKBOARD_SNACKS to an installed snacks.nvim dir.
vim.opt.rtp:prepend(vim.fn.getcwd())
local path = vim.env.DESKBOARD_SNACKS
if not path or path == "" then print("SKIP: real Snacks smoke (set DESKBOARD_SNACKS)"); return end
vim.opt.rtp = { vim.fn.getcwd(), path, vim.env.VIMRUNTIME }
vim.opt.packpath = { vim.env.VIMRUNTIME }
local snacks = require("snacks")
_G.Snacks = snacks
snacks.setup({ dashboard = { enabled = false }, notifier = { enabled = false } })
local core = require("deskboard")
local system, jobstart = vim.system, vim.fn.jobstart
local reminder = vim.fn.tempname() .. " reminder.md"
vim.system = function() error("Demo must not run a process") end
vim.fn.jobstart = function() error("Demo must not start a job") end
local ok, err = xpcall(function()
  core.setup({ demo = true })
  core.open()
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[buf].filetype == "snacks_dashboard")
  local state = require("deskboard.views").get({ buf = buf })
  for _, expected in ipairs({ "reviews", "notes", "reminders", "mine" }) do
    vim.fn.maparg("<Tab>", "n", false, true).callback()
    assert(state.active == expected)
  end
  vim.wait(30, function() return false end)
  assert(not vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]:find("ERROR", 1, true))
  core.dispose()
  vim.api.nvim_buf_delete(buf, { force = true })

  -- Real dashboard key handling must retain reminder metadata through layout.
  vim.fn.writefile({ "- [ ] Local capture", "- [X] Completed capture" }, reminder)
  core.setup({ reminders = { path = reminder }, notes = { enabled = true, allow_writes = true } })
  core.open()
  buf = vim.api.nvim_get_current_buf()
  state = require("deskboard.views").get({ buf = buf })
  state:switch("reminders")
  vim.wait(30, function() return false end)
  local toggle = vim.fn.maparg("x", "n", false, true).callback
  assert(type(toggle) == "function")
  toggle()
  assert(vim.fn.readfile(reminder)[1] == "- [x] Local capture")
  assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("0 open · 2 done", 1, true))
  vim.wait(30, function() return false end)
  toggle()
  assert(vim.fn.readfile(reminder)[1] == "- [ ] Local capture")
  core.dispose()
  vim.api.nvim_buf_delete(buf, { force = true })
end, debug.traceback)
vim.system, vim.fn.jobstart = system, jobstart
core.dispose()
vim.fn.delete(reminder)
assert(ok, err)
print("PASS: real Snacks four-panel demo and local reminder checkbox toggles")

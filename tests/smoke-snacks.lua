-- Optional real UI smoke. Set WORKBENCH_SNACKS to an installed snacks.nvim dir.
vim.opt.rtp:prepend(vim.fn.getcwd())
local path = vim.env.WORKBENCH_SNACKS
if not path or path == "" then print("SKIP: real Snacks smoke (set WORKBENCH_SNACKS)"); return end
vim.opt.rtp = { vim.fn.getcwd(), path, vim.env.VIMRUNTIME }
vim.opt.packpath = { vim.env.VIMRUNTIME }
local snacks = require("snacks")
_G.Snacks = snacks
snacks.setup({ dashboard = { enabled = false }, notifier = { enabled = false } })
local core = require("workbench")
local system, jobstart = vim.system, vim.fn.jobstart
vim.system = function() error("Demo must not run a process") end
vim.fn.jobstart = function() error("Demo must not start a job") end
local ok, err = xpcall(function()
  core.setup({ demo = true })
  core.open()
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[buf].filetype == "snacks_dashboard")
  local state = require("workbench.views").get({ buf = buf })
  for _, expected in ipairs({ "reviews", "notes", "reminders", "mine" }) do
    vim.fn.maparg("<Tab>", "n", false, true).callback()
    assert(state.active == expected)
  end
  vim.wait(30, function() return false end)
  assert(not vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]:find("ERROR", 1, true))
  core.dispose()
  vim.api.nvim_buf_delete(buf, { force = true })
end, debug.traceback)
vim.system, vim.fn.jobstart = system, jobstart
core.dispose()
assert(ok, err)
print("PASS: real Snacks open/render/four-panel switch/close, offline demo")

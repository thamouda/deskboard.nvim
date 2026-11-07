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
local cwd, sandbox = vim.fn.getcwd(), vim.fn.tempname() .. " local-only smoke"
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
  vim.fn.mkdir(sandbox .. "/.git", "p")
  vim.cmd.cd(vim.fn.fnameescape(sandbox))
  core.setup({ repo_config = { enabled = true } })
  core.open()
  buf = vim.api.nvim_get_current_buf()
  state = require("deskboard.views").get({ buf = buf })
  assert(state.active == "notes" and state.local_only)
  for _, expected in ipairs({ "reminders", "notes", "reminders", "notes" }) do
    vim.fn.maparg("<Tab>", "n", false, true).callback()
    assert(state.active == expected)
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(not text:find("My tickets", 1, true) and not text:find("Reviews for me", 1, true) and not text:find("ERROR", 1, true))
  core.dispose()
  vim.api.nvim_buf_delete(buf, { force = true })
end, debug.traceback)
vim.system, vim.fn.jobstart = system, jobstart
core.dispose()
vim.cmd.cd(vim.fn.fnameescape(cwd))
vim.fn.delete(sandbox, "rf")
assert(ok, err)
print("PASS: real Snacks four-panel demo and two-panel unconfigured workspace, without provider calls")

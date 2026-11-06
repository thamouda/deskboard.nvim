-- Optional real lazy.nvim dependency-order smoke. Uses temporary XDG state.
local plugin = vim.fn.getcwd()
local lazy, snacks = vim.env.WORKBENCH_LAZY, vim.env.WORKBENCH_SNACKS
if not lazy or not snacks then print("SKIP: lazy smoke (set WORKBENCH_LAZY/WORKBENCH_SNACKS)"); return end
local root = vim.fn.tempname() .. " lazy smoke"
vim.fn.mkdir(root, "p")
for _, key in ipairs({ "CACHE", "STATE", "DATA" }) do vim.env["XDG_" .. key .. "_HOME"] = root .. "/" .. key:lower() end
vim.opt.rtp = { vim.env.VIMRUNTIME, lazy }
vim.opt.packpath = { vim.env.VIMRUNTIME }
vim.o.loadplugins = true -- -u NONE disables normal plugin loading
require("lazy").setup({
  { dir = plugin, name = "workbench.nvim", main = "workbench", opts = { demo = true } },
  { dir = snacks, name = "snacks.nvim", lazy = false, dependencies = { "workbench.nvim" },
    opts = { dashboard = { enabled = false }, notifier = { enabled = false } } },
}, {
  root = root .. "/plugins", lockfile = root .. "/lock.json", state = root .. "/lazy-state.json",
  local_spec = false, install = { missing = false }, checker = { enabled = false },
  change_detection = { enabled = false }, readme = { enabled = false }, rocks = { enabled = false },
  performance = { rtp = { reset = false } },
})
assert(require("workbench.config").get().demo, "Lazy must apply Workbench opts before Snacks")
require("workbench").open()
assert(vim.bo.filetype == "snacks_dashboard")
vim.fn.maparg("<Tab>", "n", false, true).callback()
require("workbench").dispose()
vim.fn.delete(root, "rf")
print("PASS: real lazy.nvim local installation/dependency/setup/open cycle")

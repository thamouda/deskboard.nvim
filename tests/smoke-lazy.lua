-- Optional real lazy.nvim dependency-order smoke. Uses temporary XDG state.
local plugin = vim.fn.getcwd()
local lazy, snacks = vim.env.DESKBOARD_LAZY, vim.env.DESKBOARD_SNACKS
if not lazy or not snacks then print("SKIP: lazy smoke (set DESKBOARD_LAZY/DESKBOARD_SNACKS)"); return end
local root = vim.fn.tempname() .. " lazy smoke"
vim.fn.mkdir(root, "p")
for _, key in ipairs({ "CACHE", "STATE", "DATA" }) do vim.env["XDG_" .. key .. "_HOME"] = root .. "/" .. key:lower() end
vim.opt.rtp = { vim.env.VIMRUNTIME, lazy }
vim.opt.packpath = { vim.env.VIMRUNTIME }
vim.o.loadplugins = true -- -u NONE disables normal plugin loading
require("lazy").setup({
  { dir = plugin, name = "deskboard.nvim", main = "deskboard", opts = { demo = true } },
  { dir = snacks, name = "snacks.nvim", lazy = false, dependencies = { "deskboard.nvim" },
    opts = { dashboard = { enabled = false }, notifier = { enabled = false } } },
}, {
  root = root .. "/plugins", lockfile = root .. "/lock.json", state = root .. "/lazy-state.json",
  local_spec = false, install = { missing = false }, checker = { enabled = false },
  change_detection = { enabled = false }, readme = { enabled = false }, rocks = { enabled = false },
  performance = { rtp = { reset = false } },
})
assert(require("deskboard.config").get().demo, "Lazy must apply Deskboard opts before Snacks")
require("deskboard").open()
assert(vim.bo.filetype == "snacks_dashboard")
vim.fn.maparg("<Tab>", "n", false, true).callback()
require("deskboard").dispose()
vim.fn.delete(root, "rf")
print("PASS: real lazy.nvim local installation/dependency/setup/open cycle")

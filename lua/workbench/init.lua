local M = {}
local timer
local commands = { "Workbench", "WorkbenchRefresh" }

function M.redraw() require("workbench.adapter").redraw() end
function M.sections(owner) return require("workbench.adapter").sections(owner) end
function M.open()
  local ok, snacks = pcall(require, "snacks")
  if not ok then vim.notify("Workbench requires snacks.nvim", vim.log.levels.ERROR); return end
  snacks.dashboard.open({ width = require("workbench.config").get().width, sections = M.sections })
end
function M.refresh() require("workbench.adapter").refresh() end
function M.dispose()
  if timer then timer:stop(); timer:close(); timer = nil end
  require("workbench.adapter").dispose()
  require("workbench.views").dispose()
  require("workbench.preview").dispose()
  require("workbench.sync").dispose()
  require("workbench.note_actions").dispose()
  pcall(vim.api.nvim_del_augroup_by_name, "workbench_lifecycle")
end
function M.setup(opts)
  assert(vim.fn.has("nvim-0.11") == 1, "Workbench requires Neovim 0.11+")
  M.dispose()
  local cfg = require("workbench.config").set(opts)
  require("workbench.note_actions").setup()
  vim.api.nvim_create_user_command("Workbench", M.open, { force = true, desc = "Open Workbench dashboard" })
  vim.api.nvim_create_user_command("WorkbenchRefresh", M.refresh, { force = true, desc = "Refresh active Workbench panel" })
  local group = vim.api.nvim_create_augroup("workbench_lifecycle", { clear = true })
  timer = vim.uv.new_timer()
  local interval = math.max(1000, cfg.refresh_interval)
  local delay = interval == 60000 and (60 - os.date("*t").sec) * 1000 or interval
  timer:start(delay, interval, vim.schedule_wrap(M.redraw))
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.dispose })
  if cfg.providers.jira.enabled then require("workbench.sync").setup() end
  return M
end
return M

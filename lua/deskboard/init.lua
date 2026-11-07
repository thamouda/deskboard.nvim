local M = {}
local timer

function M.redraw() require("deskboard.adapter").redraw() end
function M.sections(owner) return require("deskboard.adapter").sections(owner) end
function M.open()
  local ok, snacks = pcall(require, "snacks")
  if not ok then vim.notify("Deskboard requires snacks.nvim", vim.log.levels.ERROR); return end
  snacks.dashboard.open({ width = require("deskboard.config").get().width, sections = M.sections })
end
function M.refresh() require("deskboard.adapter").refresh() end
function M.dispose()
  if timer then timer:stop(); timer:close(); timer = nil end
  require("deskboard.adapter").dispose()
  require("deskboard.views").dispose()
  require("deskboard.preview").dispose()
  require("deskboard.sync").dispose()
  require("deskboard.note_actions").dispose()
  pcall(vim.api.nvim_del_augroup_by_name, "deskboard_lifecycle")
end
function M.setup(opts)
  assert(vim.fn.has("nvim-0.11") == 1, "Deskboard requires Neovim 0.11+")
  M.dispose()
  local cfg = require("deskboard.config").set(opts)
  require("deskboard.note_actions").setup()
  vim.api.nvim_create_user_command("Deskboard", M.open, { force = true, desc = "Open Deskboard dashboard" })
  vim.api.nvim_create_user_command("DeskboardRefresh", M.refresh, { force = true, desc = "Refresh active Deskboard panel" })
  local group = vim.api.nvim_create_augroup("deskboard_lifecycle", { clear = true })
  timer = vim.uv.new_timer()
  local interval = math.max(1000, cfg.refresh_interval)
  local delay = interval == 60000 and (60 - os.date("*t").sec) * 1000 or interval
  timer:start(delay, interval, vim.schedule_wrap(M.redraw))
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.dispose })
  if cfg.providers.jira.enabled then require("deskboard.sync").setup() end
  return M
end
return M

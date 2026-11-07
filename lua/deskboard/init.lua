local M = {}
local timer, base_options

function M.redraw() require("deskboard.adapter").redraw() end
function M.sections(owner) return require("deskboard.adapter").sections(owner) end
function M.open()
  local ok, snacks = pcall(require, "snacks")
  if not ok then vim.notify("Deskboard requires snacks.nvim", vim.log.levels.ERROR); return end
  snacks.dashboard.open({ width = require("deskboard.config").get().width, sections = M.sections })
end
function M.refresh() require("deskboard.adapter").refresh() end
function M.reload_repo_config(force)
  if not base_options or not base_options.repo_config.enabled then return end
  local cfg = require("deskboard.config")
  local next_options = require("deskboard.repo_config").resolve(base_options, vim.fn.getcwd())
  if not force and cfg.get().repo_identity == next_options.repo_identity then return end
  cfg.set(next_options)
  local owners = require("deskboard.adapter").reset()
  require("deskboard.views").dispose()
  require("deskboard.preview").dispose()
  require("deskboard.sync").dispose()
  if next_options.repo_error then vim.notify(next_options.repo_error, vim.log.levels.WARN, { title = "Deskboard" }) end
  if cfg.get().providers.jira.enabled then require("deskboard.sync").setup() end
  for _, owner in ipairs(owners) do
    if owner.win and vim.api.nvim_win_is_valid(owner.win) and vim.api.nvim_win_get_buf(owner.win) == owner.buf
      and type(owner.update) == "function" then owner:update() end
  end
end
function M.dispose()
  base_options = nil
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
  base_options = vim.deepcopy(cfg)
  if cfg.repo_config.enabled then
    cfg = require("deskboard.config").set(require("deskboard.repo_config").resolve(base_options, vim.fn.getcwd()))
    if cfg.repo_error then vim.notify(cfg.repo_error, vim.log.levels.WARN, { title = "Deskboard" }) end
  end
  require("deskboard.note_actions").setup()
  vim.api.nvim_create_user_command("Deskboard", M.open, { force = true, desc = "Open Deskboard dashboard" })
  vim.api.nvim_create_user_command("DeskboardRefresh", M.refresh, { force = true, desc = "Refresh active Deskboard panel" })
  local group = vim.api.nvim_create_augroup("deskboard_lifecycle", { clear = true })
  vim.api.nvim_create_user_command("DeskboardReloadConfig", function() M.reload_repo_config(true) end,
    { force = true, desc = "Reload trusted repository .deskboard.json" })
  if cfg.repo_config.enabled then
    vim.api.nvim_create_autocmd("DirChanged", { group = group, callback = function() M.reload_repo_config() end })
  end
  timer = vim.uv.new_timer()
  local interval = math.max(1000, cfg.refresh_interval)
  local delay = interval == 60000 and (60 - os.date("*t").sec) * 1000 or interval
  timer:start(delay, interval, vim.schedule_wrap(M.redraw))
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.dispose })
  if cfg.providers.jira.enabled then require("deskboard.sync").setup() end
  return M
end
return M
